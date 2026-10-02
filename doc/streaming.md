# Streaming

InTorrent provides local HTTP streaming for a selected file inside a torrent.

## Basic Streaming

After metadata is available:

```dart
final files = await listFiles(torrentId);

final video = files.reduce(
  (a, b) => a.size >= b.size ? a : b,
);

final url = await streamUrl(
  torrentId,
  video.index,
);
```

The returned value is a `Uri`:

```dart
final Uri url = await streamUrl(torrentId, video.index);
```

The URI can be passed to a media player that supports HTTP URLs.

## How It Works

The native layer prepares the selected torrent file for sequential downloading.

The Dart layer registers the file with a local HTTP server bound to the loopback interface.

The high-level flow is:

```text
streamUrl()
    |
    v
Native libtorrent
    |
    +-- select requested file
    +-- enable sequential download
    +-- prioritize initial window
    |
    v
Local HTTP server
    |
    v
Media player
```

The stream server checks whether requested byte ranges are available before reading them from disk.

This matters because libtorrent can preallocate a file to its final size before all pieces have arrived. File size alone is therefore not a safe indication that a byte range can be read.

## availableBytes()

Use:

```dart
final ready = await availableBytes(
  torrentId,
  fileIndex,
  0,
  16 << 20,
);
```

The method returns how many bytes starting at `start` are already available **contiguously**, up to `maxLength`.

A return value of `0` means the first requested piece at that position is not currently available.

This is useful for application-level buffering or pre-buffer indicators.

## streamReadCursor()

```dart
final cursor = streamReadCursor(torrentId);
```

This returns the byte offset up to which the main HTTP stream request has been served, or `null` when nothing has been served yet.

It is intended as a better starting point for prefetch decisions than a time-based playback estimate.

## Prefetch

InTorrent supports a controlled prefetch window:

```dart
await startPrefetch(
  torrentId,
  fileIndex,
  startByte: startByte,
  lengthBytes: lengthBytes,
);
```

Prefetch requests the specified byte window in strict order and focuses bandwidth on that window.

When finished or when playback resumes:

```dart
await cancelPrefetch(torrentId);
```

Downloaded data is retained. Cancelling prefetch returns the streamed file to normal in-order downloading.

## Playback Pattern

A player integration can follow this general sequence:

```text
streamUrl()
    |
    v
player starts HTTP playback
    |
    v
streamReadCursor()
    |
    v
startPrefetch() when the player is paused
    |
    v
cancelPrefetch() when playback resumes
```

The exact playback integration depends on the media player used by the Flutter application.

## Cleanup

When playback is finished:

```dart
await remove(torrentId);
```

This is important because InTorrent's intended design is ephemeral streaming using temporary torrent data rather than a permanent download manager.
