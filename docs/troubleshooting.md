# Troubleshooting

## "No torrent found for id"

This usually means the integer ID is no longer valid.

Common causes:

- `remove(id)` was already called.
- The wrong ID was stored by the application.
- The application restarted and is trying to reuse an old ID.

Create a new torrent with `addMagnet()`.

## "metadata not yet available"

Methods such as `listFiles()` and `streamUrl()` require torrent metadata.

Check:

```dart
final status = await getStatus(id);
print(status.state);
```

Wait while:

```dart
status.state == TorrentState.downloadingMetadata
```

Then retry.

## Streaming URL does not play

Check these items:

1. Confirm `streamUrl()` completed without throwing.
2. Confirm the selected file is actually playable by your media player.
3. Make sure the media player supports HTTP URLs.
4. Verify that the torrent has peers/seeds and that progress is advancing.
5. Use `availableBytes()` to inspect whether the beginning of the requested range is available.
6. Keep the torrent alive until playback finishes.
7. Do not call `remove()` while the player still needs the stream.

## File List Is Empty or Unavailable

A magnet URI does not necessarily provide complete metadata immediately.

Call `listFiles()` only after metadata has arrived.

## Progress Is Not Moving

Inspect:

```dart
final status = await getStatus(id);

print(status.state);
print(status.numPeers);
print(status.numSeeds);
print(status.downloadedBytes);
```

A torrent can remain unable to download when there are no usable peers or seeds.

## Android Build Problems

Confirm that:

- Android SDK/NDK tooling is installed.
- The project can run a normal Flutter Android build.
- CMake is available.
- The configured Android ABI is supported by the device/emulator.
- The native dependency can be fetched during the CMake build.

InTorrent's native build currently uses CMake 3.22.1 and libtorrent v2.1.1.

## Native Build Is Taking a Long Time

The native CMake project builds libtorrent from source.

The first build can therefore be substantially slower than a Dart-only Flutter package.

Subsequent builds can reuse build-system caches depending on the Flutter/Gradle/CMake environment.

## Unknown Torrent State

If `TorrentStatus.state` is `TorrentState.unknown`, the native layer returned a state that the current Dart translation does not map to a known enum value.

This is not a Dart exception. Check the native state translation in `native/src/intorrent.cpp` when developing the plugin.

## When Reporting a Bug

Include:

- InTorrent version or commit
- Flutter version
- Dart version
- Android version
- device/emulator model
- CPU ABI
- exact API call that failed
- exception text
- relevant native/Android logs
- whether the problem occurs with a different torrent
