// intorrent_stream_server.dart
//
// A single local HTTP server (127.0.0.1, lazily started) that serves
// torrent files to your video player as they download. Every byte
// range is checked against the native side's intorrent_is_range_available
// before being read from disk - libtorrent preallocates files at full
// size immediately, so file size alone is never a safe signal that
// bytes are actually downloaded.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'intorrent_bindings.dart';

// Local, diagnostic-only mirror of IntorrentState from intorrent.h -
// just for building readable stall messages here. The real enum
// mapping app code should use lives in intorrent.dart's TorrentState.
String _stateName(int value) {
  const names = [
    'queued',
    'checking',
    'downloading_metadata',
    'downloading',
    'finished',
    'seeding',
  ];
  return (value >= 0 && value < names.length) ? names[value] : 'unknown';
}

// Was previously hardcoded to video/mp4 for every response regardless of
// the actual file - harmless for players like mpv that sniff the real
// container by content, but still objectively wrong (breaks any client
// that trusts the header, e.g. "Open in External Player" handing this
// off to another app by MIME type) and cheap to get right.
ContentType _contentTypeFor(String filePath) {
  final ext = filePath.contains('.')
      ? filePath.substring(filePath.lastIndexOf('.') + 1).toLowerCase()
      : '';
  switch (ext) {
    case 'mkv':
      return ContentType('video', 'x-matroska');
    case 'mp4':
    case 'm4v':
      return ContentType('video', 'mp4');
    case 'avi':
      return ContentType('video', 'x-msvideo');
    case 'webm':
      return ContentType('video', 'webm');
    case 'mov':
      return ContentType('video', 'quicktime');
    default:
      return ContentType('application', 'octet-stream');
  }
}

class _StreamEntry {
  _StreamEntry({
    required this.filePath,
    required this.fileIndex,
    required this.totalSize,
  });

  final String filePath;
  final int fileIndex;
  final int totalSize;
}

class IntorrentStreamServer {
  IntorrentStreamServer._();
  static final IntorrentStreamServer instance = IntorrentStreamServer._();

  /// How long to wait for a requested byte range to become available
  /// before giving up. Generous, because a fresh torrent can genuinely
  /// take a while to find its first peers - but bounded, so a dead
  /// torrent fails loudly instead of hanging your player forever.
  static const Duration rangeWaitTimeout = Duration(seconds: 30);

  /// Called whenever a range request times out. Lets app code (or you,
  /// during testing) see *why* a stream stalled - not just that it did.
  void Function(int id, String reason)? onStreamStalled;

  HttpServer? _server;
  final Map<int, _StreamEntry> _entries = {};

  /// Registers torrent [id]'s stream info and ensures the server is
  /// running. Returns the URL your player should use.
  Future<Uri> registerAndGetUrl({
    required int id,
    required String filePath,
    required int fileIndex,
    required int totalSize,
  }) async {
    _entries[id] = _StreamEntry(
      filePath: filePath,
      fileIndex: fileIndex,
      totalSize: totalSize,
    );

    final server = await _ensureStarted();
    return Uri.parse('http://127.0.0.1:${server.port}/stream/$id');
  }

  Future<HttpServer> _ensureStarted() async {
    final existing = _server;
    if (existing != null) return existing;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handleRequest, onError: (e, st) {
      // Was previously swallowed silently - a server-level error here
      // (vs. a per-request one, already handled inside _handleRequest)
      // would have been invisible in every log we've pulled so far.
      // ignore: avoid_print
      print('[IntorrentStreamServer] server error: $e');
    });
    return server;
  }

  /// Pulls a live status snapshot to explain WHY a range timed out -
  /// e.g. "0 peers" tells a completely different story than "80% done,
  /// 12 peers" (the latter suggests a piece-picking bug, not a dead
  /// swarm). This is exactly the kind of detail raw logs made us dig
  /// for by hand before - now it's built into the failure itself.
  String _diagnoseStall(IntorrentBindings bindings, int id) {
    final statusPtr = calloc<IntorrentStatusNative>();
    try {
      final result = bindings.getStatus(id, statusPtr);
      if (result != 0) {
        return 'torrent $id no longer exists.';
      }
      final s = statusPtr.ref;
      return 'torrent state=${_stateName(s.state)}, peers=${s.numPeers}, '
          'seeds=${s.numSeeds}, progress=${(s.progress * 100).toStringAsFixed(1)}%.';
    } finally {
      calloc.free(statusPtr);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      await _handleRequestInner(request);
    } catch (e, st) {
      // Last-resort safety net: nothing below here should ever reach an
      // unhandled exception again (that's what killed the request outright
      // the last two times), but if something new does, log it and close
      // the response instead of taking the whole isolate down with it.
      // ignore: avoid_print
      print('[IntorrentStreamServer] unhandled error in _handleRequest: $e\n$st');
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleRequestInner(HttpRequest request) async {
    final segments = request.uri.pathSegments;

    // ignore: avoid_print
    print('[IntorrentStreamServer] ${request.method} ${request.uri.path} '
        'range=${request.headers.value(HttpHeaders.rangeHeader)}');

    if (segments.length != 2 || segments[0] != 'stream') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final id = int.tryParse(segments[1]);
    final entry = id == null ? null : _entries[id];
    if (entry == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    var start = 0;
    var end = entry.totalSize - 1; // inclusive
    var isPartial = false;

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      final parsedStart = int.tryParse(parts[0]);
      final parsedEnd =
          (parts.length > 1 && parts[1].isNotEmpty) ? int.tryParse(parts[1]) : null;
      if (parsedStart != null) {
        start = parsedStart;
        end = parsedEnd ?? end;
        isPartial = true;
      }
    }

    final length = end - start + 1;

    // HEAD - real media players (mpv/libmpv, VLC) commonly send this
    // FIRST to discover Content-Length/Accept-Ranges/Content-Type
    // before deciding how to request the actual body. Answer
    // immediately with just the headers a GET for this same range
    // would return - no waiting on range availability (a HEAD isn't
    // asking for any bytes yet) and no body written. Skipping this
    // case entirely (as this used to) meant a HEAD either hung for up
    // to rangeWaitTimeout waiting on the WHOLE file to be "available",
    // or got a body it never asked for - either one is a protocol
    // violation strict HTTP clients reasonably abort on, which matches
    // "Failed to open" happening near-instantly rather than after any
    // real wait.
    if (request.method == 'HEAD') {
      request.response.statusCode =
          isPartial ? HttpStatus.partialContent : HttpStatus.ok;
      request.response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentLengthHeader, length)
        ..contentType = _contentTypeFor(entry.filePath);
      if (isPartial) {
        request.response.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/${entry.totalSize}');
      }
      await request.response.close();
      return;
    }

    // Headers can be sent immediately - the total size (and therefore
    // Content-Length/Content-Range) comes from the torrent's metadata,
    // which is already known, not from how much has actually
    // downloaded. Waiting here at all (as this used to, for the WHOLE
    // requested range) was the real bug: a player asking to start
    // playback sends an open-ended range like "bytes=0-" (meaning
    // "from the start, stream as it comes"), which this code was
    // parsing as start=0/length=<entire file> and then blocking until
    // that ENTIRE range was fully downloaded before sending anything
    // at all - not "give me what you have," but "give me everything or
    // nothing." On anything but a tiny, already-finished torrent, that
    // means no bytes go out until the torrent hits 100%, which is
    // exactly what made this look fine in earlier testing (a small,
    // well-seeded test file that finished in ~5s) and fail against any
    // real, slower one - the player's own connection timeout gives up
    // long before a multi-GB torrent finishes downloading.
    request.response.statusCode =
        isPartial ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentLengthHeader, length)
      ..contentType = _contentTypeFor(entry.filePath);
    if (isPartial) {
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${entry.totalSize}');
    }

    // Dart's HttpResponse doesn't actually put anything on the wire
    // until the first .add() call (or close()) - setting statusCode/
    // headers above only sets local state. Without this flush, a
    // client gets total silence for however long the file-exists and
    // per-chunk waits below take - indistinguishable, from the
    // client's side, from "server never responded at all". That's
    // exactly what tripped mpv's own open/read timeout at a fixed
    // ~5s in testing (confirmed via mpv debug log: zero bytes, not
    // even headers, received in that window) even though the swarm
    // itself was healthy and downloading - the first requested piece
    // legitimately just hadn't landed yet, which can easily take a
    // few seconds with a freshly-connecting swarm. Flushing headers
    // now means the client sees the connection succeeded immediately
    // and treats what follows as normal slow buffering instead of a
    // dead connection.
    await request.response.flush();

    final bindings = IntorrentBindings();
    final file = File(entry.filePath);

    // libtorrent doesn't create the file on disk until the first piece
    // actually lands - it's not there the instant the torrent enters
    // "downloading". A player firing its opening request right as
    // streaming starts (the normal case) can easily beat that first
    // write, so opening unconditionally here throws PathNotFoundException
    // before the per-chunk availability wait below ever gets a chance to
    // run. Wait for the file itself first, bounded by the same timeout.
    final openDeadline = DateTime.now().add(rangeWaitTimeout);
    while (!file.existsSync()) {
      if (!_entries.containsKey(id)) {
        await request.response.close();
        return;
      }
      if (DateTime.now().isAfter(openDeadline)) {
        final reason = _diagnoseStall(bindings, id!);
        onStreamStalled?.call(id, reason);
        // ignore: avoid_print
        print('[IntorrentStreamServer] stream/$id file never appeared after '
            '${rangeWaitTimeout.inSeconds}s: $reason');
        await request.response.close();
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    late final RandomAccessFile raf;
    try {
      raf = file.openSync();
    } catch (e) {
      // ignore: avoid_print
      print('[IntorrentStreamServer] stream/$id failed to open file: $e');
      await request.response.close();
      return;
    }
    try {
      raf.setPositionSync(start);
      const chunkSize = 64 * 1024;
      var position = start;
      var remaining = length;

      while (remaining > 0) {
        final readSize = remaining < chunkSize ? remaining : chunkSize;

        // Wait for just THIS chunk, not the whole remaining range - a
        // sequential-download torrent fills in roughly in playback
        // order, so the next small chunk is usually available (or
        // close to it) well before the rest of the file is. Bounded by
        // the same rangeWaitTimeout as before, just scoped per-chunk
        // now instead of to the entire request.
        final deadline = DateTime.now().add(rangeWaitTimeout);
        while (bindings.isRangeAvailable(id!, entry.fileIndex, position, readSize) != 1) {
          if (!_entries.containsKey(id)) {
            // Torrent removed mid-stream (e.g. user backed out) -
            // headers are already sent, so just stop writing rather
            // than trying to send a fresh status code.
            await request.response.close();
            return;
          }
          if (DateTime.now().isAfter(deadline)) {
            final reason = _diagnoseStall(bindings, id);
            onStreamStalled?.call(id, reason);
            // ignore: avoid_print
            print('[IntorrentStreamServer] stream/$id stalled at byte '
                '$position after ${rangeWaitTimeout.inSeconds}s: $reason');
            // Headers already went out with a promised Content-Length -
            // the best we can do now is stop, leaving the player with
            // a truncated body it can surface as a read/decode error,
            // rather than hang past what already looked like a
            // successful open.
            await request.response.close();
            return;
          }
          await Future.delayed(const Duration(milliseconds: 200));
        }

        final chunk = raf.readSync(readSize);
        if (chunk.isEmpty) break;
        request.response.add(chunk);
        position += chunk.length;
        remaining -= chunk.length;
      }
    } finally {
      raf.closeSync();
      await request.response.close();
    }
  }

  /// Stops serving torrent [id] (call this when the user leaves the
  /// player, alongside `remove(id)`).
  void unregister(int id) {
    _entries.remove(id);
  }
}
