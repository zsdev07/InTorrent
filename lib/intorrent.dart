// intorrent.dart
//
// Public API. This is the only file InFlex (or any app using
// InTorrent) should ever import from.

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'src/intorrent_bindings.dart';
import 'src/intorrent_stream_server.dart';

/// Mirrors IntorrentState in native/include/intorrent.h. If a status
/// comes back as `unknown`, it means the native side saw a libtorrent
/// state it doesn't yet translate - not a bug in Dart, check
/// translate_state() in intorrent.cpp.
enum TorrentState {
  queued,
  checking,
  downloadingMetadata,
  downloading,
  finished,
  seeding,
  unknown,
}

TorrentState _stateFromNative(int value) {
  switch (value) {
    case 0:
      return TorrentState.queued;
    case 1:
      return TorrentState.checking;
    case 2:
      return TorrentState.downloadingMetadata;
    case 3:
      return TorrentState.downloading;
    case 4:
      return TorrentState.finished;
    case 5:
      return TorrentState.seeding;
    default:
      return TorrentState.unknown;
  }
}

/// A snapshot of a torrent's status at the moment [getStatus] was called.
/// This is a plain value, not live - call [getStatus] again to refresh it.
class TorrentStatus {
  TorrentStatus({
    required this.totalBytes,
    required this.downloadedBytes,
    required this.progress,
    required this.state,
    required this.numPeers,
    required this.numSeeds,
    required this.isPaused,
  });

  final int totalBytes;
  final int downloadedBytes;
  final double progress;
  final TorrentState state;
  final int numPeers;
  final int numSeeds;
  final bool isPaused;

  @override
  String toString() =>
      'TorrentStatus(state: $state, progress: ${(progress * 100).toStringAsFixed(1)}%, '
      'peers: $numPeers, seeds: $numSeeds, paused: $isPaused)';
}

/// Adds a magnet link and begins metadata/peer resolution.
///
/// Returns a torrent id you'll use for every other InTorrent call
/// (getStatus, pause, resume, remove).
///
/// Throws a [FormatException] if the magnet URI could not be parsed.
Future<int> addMagnet(String uri) async {
  final bindings = IntorrentBindings();
  final uriPtr = uri.toNativeUtf8();

  try {
    final id = bindings.addMagnet(uriPtr);
    if (id < 0) {
      throw FormatException('InTorrent: could not add magnet URI', uri);
    }
    return id;
  } finally {
    calloc.free(uriPtr);
  }
}

/// Returns the current status of torrent [id].
///
/// Throws a [StateError] if [id] does not correspond to a torrent that
/// was previously returned by [addMagnet] (e.g. it was already removed).
Future<TorrentStatus> getStatus(int id) async {
  final bindings = IntorrentBindings();
  final statusPtr = calloc<IntorrentStatusNative>();

  try {
    final result = bindings.getStatus(id, statusPtr);
    if (result != 0) {
      throw StateError('InTorrent: no torrent found for id $id');
    }

    final native = statusPtr.ref;
    return TorrentStatus(
      totalBytes: native.totalBytes,
      downloadedBytes: native.downloadedBytes,
      progress: native.progress,
      state: _stateFromNative(native.state),
      numPeers: native.numPeers,
      numSeeds: native.numSeeds,
      isPaused: native.isPaused != 0,
    );
  } finally {
    calloc.free(statusPtr);
  }
}

/// Begins sequential (playback-order) downloading of file [fileIndex]
/// inside torrent [id], and returns a local URL your video player can
/// stream directly from.
///
/// Throws a [StateError] if [id] is invalid, [fileIndex] is out of
/// range, or the torrent's metadata hasn't arrived yet (check
/// [getStatus] - wait until state is no longer [TorrentState.downloadingMetadata]
/// before calling this).
Future<Uri> streamUrl(int id, int fileIndex) async {
  final bindings = IntorrentBindings();

  const pathBufferSize = 4096;
  final pathPtr = calloc<Uint8>(pathBufferSize).cast<Utf8>();
  final sizePtr = calloc<Int64>();

  try {
    final result = bindings.prepareStream(
      id,
      fileIndex,
      pathPtr,
      pathBufferSize,
      sizePtr,
    );
    if (result != 0) {
      throw StateError(
          'InTorrent: could not prepare stream for id $id, file $fileIndex '
          '(bad id/fileIndex, or metadata not yet available)');
    }

    final filePath = pathPtr.toDartString();
    final totalSize = sizePtr.value;

    return IntorrentStreamServer.instance.registerAndGetUrl(
      id: id,
      filePath: filePath,
      fileIndex: fileIndex,
      totalSize: totalSize,
    );
  } finally {
    calloc.free(pathPtr);
    calloc.free(sizePtr);
  }
}

/// Pauses torrent [id].
///
/// Throws a [StateError] if [id] is unknown.
Future<void> pause(int id) async {
  final result = IntorrentBindings().pause(id);
  if (result != 0) {
    throw StateError('InTorrent: no torrent found for id $id');
  }
}

/// Resumes a paused torrent [id].
///
/// Throws a [StateError] if [id] is unknown.
Future<void> resume(int id) async {
  final result = IntorrentBindings().resume(id);
  if (result != 0) {
    throw StateError('InTorrent: no torrent found for id $id');
  }
}

/// Stops torrent [id], removes it from the session, and deletes its
/// temporary files. Call this whenever the user leaves a stream -
/// this is what makes playback ephemeral (nothing lingers after
/// they're done watching).
///
/// After this call, [id] is no longer valid for any InTorrent function.
///
/// Throws a [StateError] if [id] is unknown.
Future<void> remove(int id) async {
  final result = IntorrentBindings().remove(id);
  if (result != 0) {
    throw StateError('InTorrent: no torrent found for id $id');
  }
  // Stop serving this id even if a request is still mid-wait for it -
  // the stream server's own check on _entries.containsKey() handles
  // that gracefully (see intorrent_stream_server.dart).
  IntorrentStreamServer.instance.unregister(id);
}
