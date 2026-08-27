// intorrent.dart
//
// Public API. This is the only file InFlex (or any app using
// InTorrent) should ever import from.

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'src/intorrent_bindings.dart';

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
