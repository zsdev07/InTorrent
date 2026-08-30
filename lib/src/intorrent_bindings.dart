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

/// Native signature: void intorrent_init(const char* listen_interfaces, const char* save_path);
typedef IntorrentInitNative = Void Function(
    Pointer<Utf8> listenInterfaces, Pointer<Utf8> savePath);
typedef IntorrentInitDart = void Function(
    Pointer<Utf8> listenInterfaces, Pointer<Utf8> savePath);

/// Native signature: int32_t intorrent_add_magnet(const char* uri);
typedef IntorrentAddMagnetNative = Int32 Function(Pointer<Utf8> uri);
typedef IntorrentAddMagnetDart = int Function(Pointer<Utf8> uri);

/// Native signature:
/// int32_t intorrent_get_status(int32_t id, IntorrentStatus* out_status);
typedef IntorrentGetStatusNative = Int32 Function(
    Int32 id, Pointer<IntorrentStatusNative> outStatus);
typedef IntorrentGetStatusDart = int Function(
    int id, Pointer<IntorrentStatusNative> outStatus);

/// Native signature:
/// int32_t intorrent_prepare_stream(int32_t id, int32_t file_index,
///                                   char* out_path, int32_t path_buf_len,
///                                   int64_t* out_size);
typedef IntorrentPrepareStreamNative = Int32 Function(
    Int32 id,
    Int32 fileIndex,
    Pointer<Utf8> outPath,
    Int32 pathBufLen,
    Pointer<Int64> outSize);
typedef IntorrentPrepareStreamDart = int Function(
    int id,
    int fileIndex,
    Pointer<Utf8> outPath,
    int pathBufLen,
    Pointer<Int64> outSize);

/// Native signature:
/// int32_t intorrent_is_range_available(int32_t id, int32_t file_index,
///                                       int64_t start, int64_t length);
typedef IntorrentIsRangeAvailableNative = Int32 Function(
    Int32 id, Int32 fileIndex, Int64 start, Int64 length);
typedef IntorrentIsRangeAvailableDart = int Function(
    int id, int fileIndex, int start, int length);

/// Native signature: int32_t intorrent_pause(int32_t id);
typedef IntorrentPauseNative = Int32 Function(Int32 id);
typedef IntorrentPauseDart = int Function(int id);

/// Native signature: int32_t intorrent_resume(int32_t id);
typedef IntorrentResumeNative = Int32 Function(Int32 id);
typedef IntorrentResumeDart = int Function(int id);

/// Native signature: int32_t intorrent_remove(int32_t id);
typedef IntorrentRemoveNative = Int32 Function(Int32 id);
typedef IntorrentRemoveDart = int Function(int id);

class IntorrentBindings {
  IntorrentBindings._(this._lib) {
    init = _lib
        .lookup<NativeFunction<IntorrentInitNative>>('intorrent_init')
        .asFunction<IntorrentInitDart>();
    addMagnet = _lib
        .lookup<NativeFunction<IntorrentAddMagnetNative>>('intorrent_add_magnet')
        .asFunction<IntorrentAddMagnetDart>();
    getStatus = _lib
        .lookup<NativeFunction<IntorrentGetStatusNative>>('intorrent_get_status')
        .asFunction<IntorrentGetStatusDart>();
    prepareStream = _lib
        .lookup<NativeFunction<IntorrentPrepareStreamNative>>('intorrent_prepare_stream')
        .asFunction<IntorrentPrepareStreamDart>();
    isRangeAvailable = _lib
        .lookup<NativeFunction<IntorrentIsRangeAvailableNative>>('intorrent_is_range_available')
        .asFunction<IntorrentIsRangeAvailableDart>();
    pause = _lib
        .lookup<NativeFunction<IntorrentPauseNative>>('intorrent_pause')
        .asFunction<IntorrentPauseDart>();
    resume = _lib
        .lookup<NativeFunction<IntorrentResumeNative>>('intorrent_resume')
        .asFunction<IntorrentResumeDart>();
    remove = _lib
        .lookup<NativeFunction<IntorrentRemoveNative>>('intorrent_remove')
        .asFunction<IntorrentRemoveDart>();
  }

  final DynamicLibrary _lib;
  late final IntorrentInitDart init;
  late final IntorrentAddMagnetDart addMagnet;
  late final IntorrentGetStatusDart getStatus;
  late final IntorrentPrepareStreamDart prepareStream;
  late final IntorrentIsRangeAvailableDart isRangeAvailable;
  late final IntorrentPauseDart pause;
  late final IntorrentResumeDart resume;
  late final IntorrentRemoveDart remove;

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
