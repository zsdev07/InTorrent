# Getting Started

## What is InTorrent?

InTorrent is a Flutter plugin that connects Dart to the native **libtorrent** BitTorrent engine through **Dart FFI**.

The intended workflow is:

1. Add a magnet URI.
2. Wait for torrent metadata.
3. Inspect the files in the torrent.
4. Select a file.
5. Create a local streaming URL.
6. Monitor availability and playback.
7. Pause/resume or prefetch when required.
8. Remove the torrent when the stream is finished.

## Import

Use the public API:

```dart
import 'package:intorrent/intorrent.dart';
```

Do not import `lib/src/intorrent_bindings.dart` from application code. That file is the low-level FFI layer and mirrors the native C++ ABI.

## Add a Magnet

```dart
final torrentId = await addMagnet(
  'magnet:?xt=urn:btih:YOUR_INFO_HASH',
);
```

The returned integer is the torrent ID used by the rest of the API.

## Wait for Metadata

Magnet links initially identify a torrent without necessarily containing its complete file list. Poll the status until the state is no longer `TorrentState.downloadingMetadata`.

```dart
while (true) {
  final status = await getStatus(torrentId);

  if (status.state != TorrentState.downloadingMetadata) {
    break;
  }

  await Future<void>.delayed(
    const Duration(milliseconds: 500),
  );
}
```

## List Torrent Files

Once metadata is available:

```dart
final files = await listFiles(torrentId);

for (final file in files) {
  print(
    '#${file.index}: ${file.name} (${file.size} bytes)',
  );
}
```

Do not assume file index 0 is the video. Torrents commonly contain multiple files such as video, subtitles, artwork, samples, or metadata.

## Create a Streaming URL

Select the desired file and call:

```dart
final url = await streamUrl(
  torrentId,
  files.first.index,
);

print(url);
```

The returned URI points to InTorrent's local HTTP streaming server.

## Check Progress

```dart
final status = await getStatus(torrentId);

print(status.progress);
print(status.downloadedBytes);
print(status.totalBytes);
print(status.numPeers);
print(status.numSeeds);
print(status.state);
```

## Clean Up

When the user leaves playback or no longer needs the torrent:

```dart
await remove(torrentId);
```

Removing a torrent stops it and asks the native layer to delete its temporary torrent files.
