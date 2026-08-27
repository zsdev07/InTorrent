// intorrent.h
//
// This is the ONE source of truth for the Dart <-> C++ boundary.
// Every function declared here must have a matching Dart FFI binding
// with the exact same argument/return types. Never edit one side
// without editing the other in the same commit.

#ifndef INTORRENT_H
#define INTORRENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Adds a magnet link to the (lazily-created) global session.
//
// uri: a null-terminated magnet URI string, owned by the caller.
//      InTorrent copies what it needs and does not take ownership
//      of this pointer — the caller may free it right after this
//      call returns.
//
// Returns a positive torrent id on success (>= 1), or -1 on failure
// (e.g. the magnet URI could not be parsed).
int32_t intorrent_add_magnet(const char* uri);

#ifdef __cplusplus
}
#endif

#endif // INTORRENT_H
