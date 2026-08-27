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

/// Native signature: int32_t intorrent_add_magnet(const char* uri);
typedef IntorrentAddMagnetNative = Int32 Function(Pointer<Utf8> uri);
typedef IntorrentAddMagnetDart = int Function(Pointer<Utf8> uri);

class IntorrentBindings {
  IntorrentBindings._(this._lib) {
    addMagnet = _lib
        .lookup<NativeFunction<IntorrentAddMagnetNative>>('intorrent_add_magnet')
        .asFunction<IntorrentAddMagnetDart>();
  }

  final DynamicLibrary _lib;
  late final IntorrentAddMagnetDart addMagnet;

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
