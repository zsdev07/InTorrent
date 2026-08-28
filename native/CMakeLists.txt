# CMakeLists.txt - InTorrent native library
#
# PLACEMENT: this file lives at native/CMakeLists.txt (same folder as
# include/ and src/). It is NOT the top-level Android Gradle build file -
# Gradle will point at this file via externalNativeBuild { cmake { path } }
# once we set up android/build.gradle.
#
# THE ONE RULE THAT MATTERS MOST HERE: libtorrent is pinned to an exact
# GIT_TAG below, never a branch. This is the single change that fixes
# the root cause we spent a whole day diagnosing in libtorrent_flutter -
# that plugin's CMake used find_package()/a moving branch reference, so
# its own version number never actually controlled which libtorrent
# engine got built. Whatever GIT_TAG is set below IS what gets built,
# on every platform, every time - no exceptions, no silent fallback.

cmake_minimum_required(VERSION 3.19)
project(intorrent LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# --- libtorrent, pinned -----------------------------------------------
#
# Update LIBTORRENT_TAG deliberately, in its own commit, when you
# actually want to move to a newer libtorrent - never let this drift
# to a branch name like "RC_2_1" or "master". That ambiguity is
# exactly what we're avoiding by building InTorrent in the first place.
set(LIBTORRENT_TAG "v2.1.1" CACHE STRING "Exact libtorrent release tag to build against")

FetchContent_Declare(
    libtorrent
    GIT_REPOSITORY https://github.com/arvidn/libtorrent.git
    GIT_TAG        ${LIBTORRENT_TAG}
    GIT_SHALLOW    TRUE
)

# Keep libtorrent's own build minimal - we only need the library itself,
# not its examples, tests, or Python bindings.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(build_tests OFF CACHE BOOL "" FORCE)
set(build_examples OFF CACHE BOOL "" FORCE)
set(python-bindings OFF CACHE BOOL "" FORCE)

# NOTE: libtorrent 2.x can build without OpenSSL (no torrent encryption
# support in that case). The old plugin's native SSL wiring was a real
# source of Android-specific pain (see its "android ssl" commit). We're
# starting WITHOUT encryption support to keep the first working build
# simple - this is a deliberate, revisitable trade-off, not an oversight.
set(TORRENT_USE_LIBCRYPTO OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(libtorrent)

# --- InTorrent itself ---------------------------------------------------

add_library(intorrent SHARED
    src/intorrent.cpp
)

target_include_directories(intorrent PRIVATE
    include
)

target_link_libraries(intorrent PRIVATE
    torrent-rasterbar
)

# Ensures the output is named libintorrent.so on Android/Linux,
# intorrent.dll on Windows - matching what intorrent_bindings.dart
# expects in DynamicLibrary.open().
set_target_properties(intorrent PROPERTIES
    OUTPUT_NAME "intorrent"
)
