# InTorrent Documentation

InTorrent is a Flutter BitTorrent plugin powered by **libtorrent**, **C++**, and **Dart FFI**.

This documentation describes the public Dart API and the native architecture as implemented in the repository.

## Documentation

- [Getting Started](getting-started.md)
- [Installation](installation.md)
- [Magnet Links](magnet-links.md)
- [Torrent Management](torrent-management.md)
- [Streaming](streaming.md)
- [API Reference](api-reference.md)
- [Architecture](architecture.md)
- [Troubleshooting](troubleshooting.md)

## Public API

The public API is exposed from:

`lib/intorrent.dart`

Applications should import that file rather than the internal FFI bindings.

## Current Platform

The repository currently wires InTorrent into Flutter as an **Android FFI plugin**.

Android ABIs configured by the plugin:

- `arm64-v8a`
- `armeabi-v7a`
- `x86_64`

Other platforms are planned but are not currently wired into `pubspec.yaml`.

## Design Goal

InTorrent intentionally exposes a small API instead of mirroring the complete libtorrent API. The native C++ layer owns the libtorrent session and the Dart layer provides a focused Flutter-facing interface for magnet links, torrent status, file selection, streaming, prefetching, and torrent lifecycle management.
