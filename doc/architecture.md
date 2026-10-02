# Architecture

InTorrent is intentionally split into a small Dart public API, a Dart FFI layer, a native C++ layer, and libtorrent.

## Components

```text
Flutter Application
        |
        v
lib/intorrent.dart
Public Dart API
        |
        v
lib/src/intorrent_bindings.dart
Dart FFI bindings
        |
        v
native/include/intorrent.h
Native ABI contract
        |
        v
native/src/intorrent.cpp
Native implementation
        |
        v
libtorrent v2.1.1
BitTorrent engine
```

## Public Dart Layer

`lib/intorrent.dart` is the public API.

It converts low-level native results into Dart concepts such as:

- `TorrentState`
- `TorrentStatus`
- `TorrentFile`
- `Uri`
- `Future`
- `StateError`
- `FormatException`

## FFI Layer

`lib/src/intorrent_bindings.dart` contains the low-level Dart FFI declarations.

Its signatures must match `native/include/intorrent.h`.

The project deliberately keeps this boundary explicit so changes to the C++ ABI and Dart bindings can be reviewed together.

## Native Layer

`native/src/intorrent.cpp` owns the native libtorrent session and the mapping between integer torrent IDs and libtorrent torrent handles.

The native layer is responsible for:

- creating the libtorrent session
- adding magnet URIs
- querying torrent status
- exposing torrent file metadata
- configuring sequential streaming
- prioritizing byte ranges
- managing prefetch windows
- pausing and resuming torrents
- removing torrents and temporary files

## Local Streaming Server

The Dart side includes `IntorrentStreamServer`.

It provides a local HTTP endpoint on loopback and serves ranges from torrent files while consulting the native layer to determine whether requested data is available.

This allows a normal HTTP-capable media player to consume the torrent as a local stream.

## Temporary Storage

InTorrent initializes a temporary download directory under Dart's `Directory.systemTemp`.

The current implementation uses an `intorrent_dl` directory and creates per-torrent data below it.

The directory is intended for ephemeral streaming data rather than permanent torrent storage.

## libtorrent Pinning

The native CMake build pins libtorrent to:

```text
v2.1.1
```

The build uses CMake `FetchContent` with an exact Git tag.

This is intentional: changing the libtorrent version should be a deliberate source change rather than an accidental moving dependency.

## Android Native Build

The Android plugin uses Gradle's external native build integration:

```text
android/build.gradle
       |
       v
native/CMakeLists.txt
       |
       v
C++ shared library
       |
       v
libintorrent.so
```

The configured ABIs are:

- arm64-v8a
- armeabi-v7a
- x86_64

## Why the API Is Small

InTorrent does not attempt to expose the complete libtorrent API.

The project focuses on the operations required by its intended Flutter streaming workflow. Keeping the FFI boundary small reduces the amount of native ABI surface that must remain synchronized with Dart.
