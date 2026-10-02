# InTorrent

[![pub package](https://img.shields.io/pub/v/intorrent.svg)](https://pub.dev/packages/intorrent)
[![pub points](https://img.shields.io/pub/points/intorrent)](https://pub.dev/packages/intorrent/score)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

InTorrent is an Android Flutter plugin that wraps the libtorrent C++ BitTorrent engine through Dart FFI.

It provides a small API for magnet links, torrent status, file selection, local HTTP streaming, byte availability checks, sequential prefetching, pause/resume, and cleanup.

## Platform support

| Platform | Status |
| --- | --- |
| Android | Supported |
| iOS | Planned |
| Windows | Planned |
| macOS | Planned |
| Linux | Planned |
| Web | Not supported |

Android builds currently include arm64-v8a, armeabi-v7a, and x86_64.

## Installation

Add this dependency:

    dependencies:
      intorrent: ^0.0.1

Then run:

    flutter pub get

## Quick start

The recommended flow is addMagnet, wait for metadata, listFiles, choose a file, then call streamUrl.

    import 'package:intorrent/intorrent.dart';

    Future<void> start(String magnetUri) async {
      final id = await addMagnet(magnetUri);

      TorrentStatus status;
      do {
        await Future<void>.delayed(const Duration(seconds: 1));
        status = await getStatus(id);
      } while (status.state == TorrentState.downloadingMetadata);

      final files = await listFiles(id);
      final file = files.first;

      final url = await streamUrl(id, file.index);
      print(url);

      // Pass url.toString() to your media player.
      // Call remove(id) when playback is finished.
    }

Important: metadata must be available before listFiles or streamUrl is called.

## API

- addMagnet(uri): add a magnet URI and return a torrent ID.
- getStatus(id): return the current torrent status snapshot.
- listFiles(id): list torrent files after metadata is available.
- streamUrl(id, fileIndex): prepare sequential downloading and return a local HTTP URL.
- availableBytes(id, fileIndex, start, maxLength): check contiguous downloaded bytes.
- streamReadCursor(id): get the current main stream read position.
- startPrefetch(...): prefetch a byte range in strict order.
- cancelPrefetch(id): cancel the active prefetch window.
- pause(id): pause a torrent.
- resume(id): resume a paused torrent.
- remove(id): stop and remove a torrent and its temporary files.

See docs/api-reference.md for the complete API reference.

## Streaming

streamUrl returns a local HTTP URL from InTorrent's built-in stream server. The server supports HTTP range requests so media players can seek and buffer while libtorrent downloads pieces in playback order.

Torrents can contain subtitles, samples, artwork, and metadata files, so applications should choose the desired file rather than assuming index 0 is the main video.

See docs/streaming.md for buffering and prefetch details.

## Architecture

    Flutter app
        |
        v
    lib/intorrent.dart
        |
        v
    Dart FFI
        |
        v
    C++ bridge
        |
        v
    libtorrent 2.1.1

The native engine is built through the Android plugin's CMake configuration.

## Documentation

- docs/getting-started.md
- docs/installation.md
- docs/magnet-links.md
- docs/torrent-management.md
- docs/streaming.md
- docs/api-reference.md
- docs/architecture.md
- docs/troubleshooting.md

## Development

    flutter pub get
    flutter analyze
    flutter test
    dart pub publish --dry-run

For a local pub.dev quality report:

    dart pub global activate pana
    dart pub global run pana .

## Example

The example app demonstrates adding a magnet, reading status, listing files, generating a stream URL, and removing the torrent.

## Native engine

The Android build pins libtorrent v2.1.1. InTorrent deliberately exposes a small Dart API instead of mirroring the complete libtorrent API.

## Contributing

Issues and pull requests are welcome. When changing the FFI boundary, update the native header, C++ implementation, Dart bindings, public API documentation, and examples together.

## License

InTorrent is released under the MIT License with an attribution requirement. See LICENSE.

## Credits

Built on top of libtorrent by Arvid Norberg and contributors.

Maintained by ZSDev07.
