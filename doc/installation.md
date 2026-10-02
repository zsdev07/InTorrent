# Installation

## Package

The package name is:

```yaml
intorrent
```

The current repository version is `0.0.1` and the package requires:

- Dart SDK `>=3.0.0 <4.0.0`
- Flutter `>=3.10.0`

The package depends on:

- `flutter`
- `ffi: ^2.1.0`

## From Git

During active development, add the GitHub repository as a dependency if needed:

```yaml
dependencies:
  intorrent:
    git:
      url: https://github.com/zsdev07/InTorrent.git
```

Then run:

```bash
flutter pub get
```

When using a published package version, use the version available on pub.dev instead.

## Android

Android is the currently implemented Flutter plugin platform.

The Android plugin uses Flutter's FFI plugin integration:

```yaml
flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
```

The native Android build uses CMake and builds the native InTorrent library from source.

Configured Android ABIs:

```text
arm64-v8a
armeabi-v7a
x86_64
```

The Android module currently uses:

- compile SDK 34
- minimum SDK 21
- Java 17
- CMake 3.22.1

## Native libtorrent Version

The native CMake configuration pins libtorrent to:

```text
v2.1.1
```

The dependency is fetched by CMake using an exact Git tag rather than a moving branch.

## Building From Source

Clone the repository:

```bash
git clone https://github.com/zsdev07/InTorrent.git
cd InTorrent
```

Install Flutter dependencies:

```bash
flutter pub get
```

Build an Android application that depends on the plugin using the normal Flutter Android build process.

The native build is driven by:

```text
android/build.gradle
        ↓
native/CMakeLists.txt
        ↓
libtorrent v2.1.1
        ↓
libintorrent.so
```

## Platform Status

Currently implemented:

- Android

Planned:

- iOS
- Windows
- macOS
- Linux

Do not assume the planned platforms are currently supported by the package.
