// intorrent.dart
//
// Public API. This is the only file InFlex (or any app using
// InTorrent) should ever import from.

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'src/intorrent_bindings.dart';

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
