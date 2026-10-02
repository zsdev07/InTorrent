# API Reference

This page documents the public API in `lib/intorrent.dart`.

## addMagnet

```dart
Future<int> addMagnet(String uri)
```

Adds a magnet URI and starts torrent metadata/peer resolution.

Returns:

- `int`: torrent ID

Throws:

- `FormatException`: the magnet URI could not be added.

Example:

```dart
final id = await addMagnet(magnetUri);
```

## getStatus

```dart
Future<TorrentStatus> getStatus(int id)
```

Returns a point-in-time status snapshot.

Throws:

- `StateError`: unknown torrent ID.

Example:

```dart
final status = await getStatus(id);

print(status.progress);
print(status.state);
```

## listFiles

```dart
Future<List<TorrentFile>> listFiles(int id)
```

Returns all files in the torrent after metadata is available.

Throws:

- `StateError`: invalid ID or metadata is not available.

### TorrentFile

```dart
class TorrentFile {
  final int index;
  final String name;
  final int size;
}
```

The `index` is passed to `streamUrl()`.

## streamUrl

```dart
Future<Uri> streamUrl(int id, int fileIndex)
```

Starts sequential downloading for the selected file and returns a local HTTP streaming URI.

Throws:

- `StateError`: invalid ID, invalid file index, or missing metadata.

## availableBytes

```dart
Future<int> availableBytes(
  int id,
  int fileIndex,
  int start,
  int maxLength,
)
```

Returns the contiguous number of bytes available from `start`, limited by `maxLength`.

Throws:

- `StateError`: invalid torrent, file, range, or unavailable metadata.

## streamReadCursor

```dart
int? streamReadCursor(int id)
```

Returns the main stream's served byte cursor, or `null` if nothing has been served.

## startPrefetch

```dart
Future<void> startPrefetch(
  int id,
  int fileIndex, {
  required int startByte,
  required int lengthBytes,
})
```

Starts a strict ordered prefetch window for a file.

Throws:

- `StateError`: invalid torrent, file, range, or unavailable metadata.

## cancelPrefetch

```dart
Future<void> cancelPrefetch(int id)
```

Stops an active prefetch window and returns the selected file to normal streaming behavior.

Calling it when no prefetch is active is safe.

Throws:

- `StateError`: unknown torrent ID.

## pause

```dart
Future<void> pause(int id)
```

Pauses the torrent.

Throws:

- `StateError`: unknown torrent ID.

## resume

```dart
Future<void> resume(int id)
```

Resumes a paused torrent.

Throws:

- `StateError`: unknown torrent ID.

## remove

```dart
Future<void> remove(int id)
```

Stops and removes the torrent and deletes its temporary files.

Throws:

- `StateError`: unknown torrent ID.

## TorrentStatus

```dart
class TorrentStatus {
  final int totalBytes;
  final int downloadedBytes;
  final double progress;
  final TorrentState state;
  final int numPeers;
  final int numSeeds;
  final bool isPaused;
}
```

## TorrentState

```dart
enum TorrentState {
  queued,
  checking,
  downloadingMetadata,
  downloading,
  finished,
  seeding,
  unknown,
}
```

## Public API Rule

Application code should import:

```dart
import 'package:intorrent/intorrent.dart';
```

Do not depend on the internal FFI binding implementation.
