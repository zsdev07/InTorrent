.. image:: docs/img/logo.png

![Status](https://img.shields.io/badge/status-early%20development-orange)
![License](https://img.shields.io/badge/license-MIT%20(attribution)-blue)
![Build - Android](https://img.shields.io/badge/build-android-lightgrey)
![Build - Windows](https://img.shields.io/badge/build-windows-lightgrey)
![Build - Linux](https://img.shields.io/badge/build-linux-lightgrey)
![Build - macOS](https://img.shields.io/badge/build-macos-lightgrey)

# InTorrent

InTorrent is an open-source Flutter plugin that wraps the [libtorrent](https://libtorrent.org) C++ engine via a small, focused Dart FFI API. It's built to do one thing well: let a Flutter app add a magnet link, track its status, and stream a file from it â€” with a minimal, predictable surface that stays easy to maintain.

> **Status: Early development.** InTorrent is under active design and is not yet ready for production use. The core API is being built out â€” check back for updates, or follow along in the commit history.

## Why InTorrent?

Most existing Flutter libtorrent wrappers try to expose the entire libtorrent API surface, which makes them heavy, hard to keep in sync with the native engine, and prone to breaking when native struct layouts drift out of sync with their Dart bindings. InTorrent takes a different approach: a small, deliberately scoped API, with the native and Dart sides built and versioned together in the same repository â€” so they can't silently drift apart.

## Planned API

InTorrent's API surface is intentionally small:

| Function | Description |
|---|---|
| `addMagnet(uri)` | Adds a magnet link and begins metadata/peer resolution. Returns a torrent handle/id. |
| `getStatus(id)` | Returns live status for a torrent â€” progress, peer count, download state. |
| `streamUrl(id, fileIndex)` | Begins sequential (playback-order) downloading of a file inside the torrent and returns a local URL to stream it from. |
| `pause(id)` | Pauses a torrent. |
| `resume(id)` | Resumes a paused torrent. |
| `remove(id)` | Stops a torrent and removes its handle and temporary files. |

This list may evolve as development continues, but the goal is to keep it minimal rather than exhaustive.

## Platform Support (planned)

- [ ] Android (arm64-v8a, armeabi-v7a, x86_64)
- [ ] iOS
- [ ] Windows
- [ ] macOS
- [ ] Linux

Android is the initial build target; other platforms will follow.

## Building

Build instructions will be added once the initial native build pipeline (GitHub Actions, cross-compiled per ABI) is in place.

## Design Principles

- **Small surface, fewer breakages.** Fewer exposed functions means less that can drift or go stale.
- **Pinned native source.** The native libtorrent version InTorrent builds against is pinned to an exact commit or tag â€” never a moving branch â€” so the version you depend on is the version you actually get.
- **Native and Dart bindings live together.** Both halves of the FFI boundary are maintained in the same repository, in the same commits, to avoid the struct-mismatch class of bugs common in wrapper plugins.

## License

InTorrent is released under a custom MIT-based license with an attribution requirement. Commercial use and forking are both permitted. See [LICENSE](LICENSE) for the full text.

## Credits

Built on top of [libtorrent](https://github.com/arvidn/libtorrent) by Arvid Norberg and contributors.

InTorrent is developed and maintained by [MR.ZSDEV](https://github.com/zsdev07)
