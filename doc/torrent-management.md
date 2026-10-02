# Torrent Management

InTorrent exposes a small lifecycle API for each torrent.

## Status

Use:

```dart
final status = await getStatus(torrentId);
```

The returned `TorrentStatus` is a snapshot. It is not live and must be requested again to refresh.

### TorrentStatus

Properties:

| Property | Type | Meaning |
|---|---|---|
| `totalBytes` | `int` | Total bytes represented by the torrent |
| `downloadedBytes` | `int` | Bytes downloaded according to the native torrent status |
| `progress` | `double` | Progress value returned by the native layer |
| `state` | `TorrentState` | Current translated torrent state |
| `numPeers` | `int` | Current peer count |
| `numSeeds` | `int` | Current seed count |
| `isPaused` | `bool` | Whether the torrent is paused |

## TorrentState

The public enum contains:

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

The `unknown` state means the native layer returned a state that the Dart translation does not currently map to one of the known values.

## Pause

```dart
await pause(torrentId);
```

Pausing asks the native libtorrent torrent handle to pause.

## Resume

```dart
await resume(torrentId);
```

Resuming asks the native torrent handle to resume.

## Remove

```dart
await remove(torrentId);
```

Removal:

1. Invalidates the torrent ID.
2. Removes the torrent from the native session.
3. Deletes the torrent's temporary files.
4. Unregisters the torrent from the local HTTP streaming server.

After `remove()`, the old ID must not be used with other InTorrent methods.

## Errors

Most lifecycle methods throw `StateError` when the torrent ID is unknown.

Example:

```dart
try {
  await pause(torrentId);
} on StateError catch (error) {
  print(error);
}
```
