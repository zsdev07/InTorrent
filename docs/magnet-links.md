# Magnet Links

InTorrent's primary entry point is `addMagnet()`.

## Add a Magnet URI

```dart
final torrentId = await addMagnet(
  'magnet:?xt=urn:btih:YOUR_INFO_HASH',
);
```

The method:

```dart
Future<int> addMagnet(String uri)
```

returns an integer torrent ID.

## Invalid Magnet URI

If the native layer cannot add the supplied URI, InTorrent throws a `FormatException`.

```dart
try {
  final id = await addMagnet(magnetUri);
  print('Torrent ID: $id');
} on FormatException catch (error) {
  print('Invalid magnet: $error');
}
```

## Metadata Resolution

A magnet URI may require metadata and peer discovery before the complete torrent file list becomes available.

After calling `addMagnet()`, use `getStatus()`:

```dart
final status = await getStatus(torrentId);

if (status.state == TorrentState.downloadingMetadata) {
  // Wait and poll again.
}
```

Once metadata is available, `listFiles()` can be used.

## Recommended Workflow

```text
addMagnet()
    |
    v
torrent ID
    |
    v
getStatus()
    |
    +-- downloadingMetadata --> wait
    |
    v
listFiles()
    |
    v
select file index
    |
    v
streamUrl()
```

## File Selection

Do not blindly select file index 0.

A torrent can contain:

- video files
- subtitle files
- images
- NFO files
- samples
- multiple video files

Use `listFiles()` and select the file appropriate for the application.

For a media application, a common application-level heuristic is to prefer a large file with a known media extension. InTorrent itself does not force that policy.
