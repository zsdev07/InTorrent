// intorrent_stream_server.dart
//
// A single local HTTP server (127.0.0.1, lazily started) that serves
// torrent files to your video player as they download. Every byte
// range is checked against the native side (intorrent_available_bytes)
// before being read from disk - libtorrent preallocates files at full
// size immediately, so file size alone is never a safe signal that
// bytes are actually downloaded.
//
// Streaming behaviour (see the per-request loop in _handleRequestInner):
//   * reads in up to 512 KiB slices, sized by what is ACTUALLY downloaded
//   * awaits a socket flush after every slice (backpressure + keeps the
//     UI isolate responsive)
//   * only asks libtorrent for deadlines when the reader is near the
//     download frontier, and releases them when the request ends
//   * notices when the player hangs up instead of waiting out a timeout

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

// Used for closing a response early *after* real headers with a
// genuine Content-Length promise already went out (client bailed, or
// our own stall timeout gave up), but before the full body was
// written. Dart's HttpResponse validates the actual byte count
// written against the promised Content-Length on close() and throws
// HttpException on a mismatch - expected and harmless here (the
// client just gets a truncated body it can surface as its own
// read/decode error), so it's swallowed rather than bubbling up to
// the outer handler's generic "unhandled error" log line, which
// implies something unexpected happened when this is a known,
// anticipated case.
Future<void> _closeQuietly(HttpResponse response) async {
  try {
    await response.close();
  } catch (_) {}
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

  /// Where the player's main (long) request has been served up to.
  /// See [IntorrentStreamServer.readCursor].
  int? readCursor;
}

/// Biggest slice handed to the socket per loop iteration.
const int _maxChunk = 512 * 1024;

/// While the reader is within this many bytes of the end of the
/// contiguous downloaded data, the next missing pieces get deadlines.
const int _lookaheadBytes = 8 * 1024 * 1024;

/// Size of the deadline window requested at the download frontier.
const int _windowBytes = 8 * 1024 * 1024;

/// A window is re-applied at least this often while the reader waits.
const Duration _windowRefresh = Duration(seconds: 2);

/// Requests asking for more than this are treated as "the" playback
/// stream (as opposed to a short tail/Cues probe) when tracking
/// [IntorrentStreamServer.readCursor].
const int _mainStreamMinBytes = 16 * 1024 * 1024;

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

    // `entry != null` above already guarantees a valid id; make that
    // explicit once so nothing below needs `id!` sprinkled around.
    final torrentId = id!;
    final bindings = IntorrentBindings();
    final file = File(entry.filePath);

    // Notice the player hanging up (seek, close, reconnect). Without this
    // an abandoned request kept waiting - and kept asking libtorrent for
    // the pieces at its OLD position - for up to rangeWaitTimeout.
    var clientGone = false;
    unawaited(request.response.done.then(
      (_) => clientGone = true,
      onError: (_) => clientGone = true,
    ));

    // libtorrent doesn't create the file on disk until the first piece
    // actually lands - it's not there the instant the torrent enters
    // "downloading". A player firing its opening request right as
    // streaming starts (the normal case) can easily beat that first
    // write, so opening unconditionally here throws PathNotFoundException
    // before the availability wait below ever gets a chance to run. Wait
    // for the file itself first, bounded by the same timeout.
    final openDeadline = DateTime.now().add(rangeWaitTimeout);
    while (!file.existsSync()) {
      if (clientGone || !_entries.containsKey(torrentId)) {
        await _closeQuietly(request.response);
        return;
      }
      if (DateTime.now().isAfter(openDeadline)) {
        final reason = _diagnoseStall(bindings, torrentId);
        onStreamStalled?.call(torrentId, reason);
        // ignore: avoid_print
        print('[IntorrentStreamServer] stream/$torrentId file never appeared after '
            '${rangeWaitTimeout.inSeconds}s: $reason');
        await _closeQuietly(request.response);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    late final RandomAccessFile raf;
    try {
      raf = file.openSync();
    } catch (e) {
      // ignore: avoid_print
      print('[IntorrentStreamServer] stream/$torrentId failed to open file: $e');
      await _closeQuietly(request.response);
      return;
    }

    final isMainStream = length > _mainStreamMinBytes;

    // Byte position of the last deadline window this request asked for
    // (-1 = none yet), so it can be released again when the request ends.
    var windowStart = -1;
    var windowAt = DateTime.fromMillisecondsSinceEpoch(0);
    DateTime? stallSince;

    try {
      await raf.setPosition(start);
      var position = start;
      var remaining = length;

      while (remaining > 0 && !clientGone) {
        if (!_entries.containsKey(torrentId)) {
          // Torrent removed mid-stream (e.g. user backed out) - headers
          // are already sent, so just stop writing.
          break;
        }

        // ONE cheap call tells us how many bytes are readable right now
        // (the native side caches the piece bitfield), replacing the old
        // "is this 64 KB available?" poll + per-chunk prioritize call.
        final lookahead = remaining < _lookaheadBytes ? remaining : _lookaheadBytes;
        final ahead =
            bindings.availableBytes(torrentId, entry.fileIndex, position, lookahead);
        if (ahead < 0) {
          // ignore: avoid_print
          print('[IntorrentStreamServer] stream/$torrentId availableBytes failed at '
              'byte $position');
          break;
        }

        // Close to (or at) the download frontier: tell libtorrent which
        // pieces are needed next so it fetches them in order, from its
        // fastest peers. Only done when needed - never while the reader
        // is comfortably far behind the frontier.
        if (ahead < lookahead) {
          final frontier = position + ahead;
          final now = DateTime.now();
          if (frontier != windowStart || now.difference(windowAt) > _windowRefresh) {
            final beyond = remaining - ahead;
            bindings.prioritizeRange(
              torrentId,
              entry.fileIndex,
              frontier,
              beyond < _windowBytes ? beyond : _windowBytes,
            );
            windowStart = frontier;
            windowAt = now;
          }
        }

        if (ahead == 0) {
          // Waiting for the piece at `position`.
          final since = stallSince ??= DateTime.now();
          if (DateTime.now().difference(since) > rangeWaitTimeout) {
            final reason = _diagnoseStall(bindings, torrentId);
            onStreamStalled?.call(torrentId, reason);
            // ignore: avoid_print
            print('[IntorrentStreamServer] stream/$torrentId stalled at byte '
                '$position after ${rangeWaitTimeout.inSeconds}s: $reason');
            // Headers already went out with a promised Content-Length -
            // the best we can do now is stop, leaving the player with a
            // truncated body it can surface as a read error.
            break;
          }
          await Future.delayed(const Duration(milliseconds: 40));
          continue;
        }
        stallSince = null;

        final n = ahead < _maxChunk ? ahead : _maxChunk;
        final chunk = await raf.read(n);
        if (chunk.isEmpty) break;

        try {
          request.response.add(chunk);
          // Backpressure AND a yield to the event loop. Without this the
          // "data is available" path never awaited anything: it read
          // synchronously in a tight loop, buffered whole ranges in RAM
          // and froze the UI isolate the server shares with Flutter.
          await request.response.flush();
        } catch (_) {
          break; // client hung up mid-write
        }

        position += chunk.length;
        remaining -= chunk.length;
        if (isMainStream) entry.readCursor = position;
      }
    } catch (e) {
      // ignore: avoid_print
      print('[IntorrentStreamServer] stream/$torrentId request aborted: $e');
    } finally {
      try {
        raf.closeSync();
      } catch (_) {}

      // Stop asking libtorrent for pieces this request no longer needs.
      if (windowStart >= 0 && _entries.containsKey(torrentId)) {
        try {
          bindings.releaseRange(torrentId, entry.fileIndex, windowStart, _windowBytes);
        } catch (_) {}
      }

      await _closeQuietly(request.response);
    }
  }

  /// Byte offset the player's MAIN stream request of torrent [id] has been
  /// served up to (= where it will read next), or null if nothing has been
  /// served yet. Short probe requests (MKV Cues near EOF etc.) don't count.
  int? readCursor(int id) => _entries[id]?.readCursor;

  /// Stops serving torrent [id] (call this when the user leaves the
  /// player, alongside `remove(id)`).
  void unregister(int id) {
    _entries.remove(id);
  }
}
