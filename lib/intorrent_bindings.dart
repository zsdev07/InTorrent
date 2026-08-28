// intorrent_bindings.dart
//
// Low-level FFI bindings. Every signature here must match
// native/include/intorrent.h EXACTLY - same argument types, same
// return type. This file and that header are the two halves of the
// same contract and must always be edited together.
//
// App code should never import this file directly - use intorrent.dart
// instead, which wraps these in a friendly, Future-based API.

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Mirrors native/include/intorrent.h's IntorrentStatus EXACTLY -
/// same fields, same order, same types. Never edit this without
/// editing that header in the same commit, and vice versa.
final class IntorrentStatusNative extends Struct {
  @Int64()
  external int totalBytes;

  @Int64()
  external int downloadedBytes;

  @Float()
  external double progress;

  @Int32()
  external int state;

  @Int32()
  external int numPeers;

  @Int32()
  external int numSeeds;

  @Int32()
  external int isPaused;
}

/// Native signature: int32_t intorrent_add_magnet(const char* uri);
typedef IntorrentAddMagnetNative = Int32 Function(Pointer<Utf8> uri);
typedef IntorrentAddMagnetDart = int Function(Pointer<Utf8> uri);

/// Native signature:
/// int32_t intorrent_get_status(int32_t id, IntorrentStatus* out_status);
typedef IntorrentGetStatusNative = Int32 Function(
    Int32 id, Pointer<IntorrentStatusNative> outStatus);
typedef IntorrentGetStatusDart = int Function(
    int id, Pointer<IntorrentStatusNative> outStatus);

class IntorrentBindings {
  IntorrentBindings._(this._lib) {
    addMagnet = _lib
        .lookup<NativeFunction<IntorrentAddMagnetNative>>('intorrent_add_magnet')
        .asFunction<IntorrentAddMagnetDart>();
    getStatus = _lib
        .lookup<NativeFunction<IntorrentGetStatusNative>>('intorrent_get_status')
        .asFunction<IntorrentGetStatusDart>();
  }

  final DynamicLibrary _lib;
  late final IntorrentAddMagnetDart addMagnet;
  late final IntorrentGetStatusDart getStatus;

  static IntorrentBindings? _instance;

  factory IntorrentBindings() {
    return _instance ??= IntorrentBindings._(_loadLibrary());
  }

  static DynamicLibrary _loadLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libintorrent.so');
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('libintorrent.so');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('intorrent.dll');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.process();
    }
    throw UnsupportedError('InTorrent: unsupported platform');
  }
}
