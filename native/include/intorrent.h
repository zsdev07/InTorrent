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

// Tells the (not-yet-created) global session which local address to
// bind its listen socket to (e.g. "192.168.1.42:6881") and which
// directory to save downloaded pieces into. Optional - call this
// once, before the first intorrent_add_magnet(), if you have both
// values available.
//
// listen_interfaces: a concrete IP avoids Android's SELinux netlink
// restriction for interface auto-detection. Kept as a minor belt-
// and-braces improvement - the actual session-killing bug on Android
// turned out to be libtorrent's separate enable_ip_notifier feature
// (its own, unrelated netlink call for network-change detection),
// fixed directly in get_session() below, not by this parameter.
//
// save_path: a real, writable directory for downloaded piece data.
// WHY THIS EXISTS: addMagnet() used to fall back to save_path "."
// (an unfinished placeholder), which on Android resolves to the
// process's working directory - the filesystem root, which regular
// apps cannot write into at all. Every downloaded piece silently had
// nowhere legal to go. Pass a real directory (Dart-side, e.g.
// Directory.systemTemp.path - matches InTorrent's streaming-only,
// no-persistent-download design) to fix that.
//
// If this is never called, intorrent_add_magnet() falls back to "."
// for save_path (broken on Android, matches old behavior) and the
// wildcard form for listen_interfaces (see intorrent_init's old doc
// comment - same Android limitation as before).
void intorrent_init(const char* listen_interfaces, const char* save_path);

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

// Torrent state, defined by InTorrent (NOT libtorrent's own state_t) -
// so a libtorrent upgrade can never silently renumber these on us.
typedef enum {
    INTORRENT_STATE_QUEUED = 0,
    INTORRENT_STATE_CHECKING = 1,
    INTORRENT_STATE_DOWNLOADING_METADATA = 2,
    INTORRENT_STATE_DOWNLOADING = 3,
    INTORRENT_STATE_FINISHED = 4,
    INTORRENT_STATE_SEEDING = 5,
    INTORRENT_STATE_UNKNOWN = 99,
} IntorrentState;

// Plain, fixed-width fields only - explicitly ordered largest-to-smallest
// to avoid any implicit compiler padding ambiguity. This layout must
// match lib/src/intorrent_bindings.dart's IntorrentStatus struct EXACTLY,
// field for field, in the same order.
typedef struct {
    int64_t total_bytes;       // total size of the selected download, in bytes
    int64_t downloaded_bytes;  // bytes downloaded so far
    float progress;            // 0.0 - 1.0
    int32_t state;             // one of IntorrentState
    int32_t num_peers;
    int32_t num_seeds;
    int32_t is_paused;         // 0 = false, 1 = true (avoid native `bool` ABI differences)
} IntorrentStatus;

// Fills out_status with the current status of torrent `id`.
// Returns 0 on success, -1 if `id` does not correspond to a known torrent.
int32_t intorrent_get_status(int32_t id, IntorrentStatus* out_status);

// Prepares torrent `id` for streaming file `file_index` inside it:
// sets sequential (playback-order) piece downloading and deprioritizes
// every other file in the torrent.
//
// out_path: caller-allocated buffer that will receive the absolute
//           file path on disk (null-terminated). Note: libtorrent
//           preallocates this file at its FULL final size immediately -
//           its existence/size does NOT mean the bytes are downloaded.
//           Always check intorrent_is_range_available() before reading.
// path_buf_len: size of out_path, in bytes.
// out_size: receives the file's total size in bytes.
//
// Returns 0 on success, -1 on failure (bad id, bad file_index, or
// out_path too small).
int32_t intorrent_prepare_stream(int32_t id, int32_t file_index,
                                  char* out_path, int32_t path_buf_len,
                                  int64_t* out_size);

// Checks whether the byte range [start, start + length) of file
// `file_index` for torrent `id` has actually been downloaded yet.
// Call this before reading any byte range from the file on disk -
// the file's on-disk size is not a reliable signal (see above).
//
// Returns 1 if the whole range is available, 0 if any part of it is
// still missing, -1 on error (bad id or file_index).
int32_t intorrent_is_range_available(int32_t id, int32_t file_index,
                                      int64_t start, int64_t length);

// Pauses torrent `id`. Returns 0 on success, -1 if `id` is unknown.
int32_t intorrent_pause(int32_t id);

// Resumes a paused torrent `id`. Returns 0 on success, -1 if `id` is unknown.
int32_t intorrent_resume(int32_t id);

// Stops torrent `id`, removes it from the session, and deletes its
// temporary downloaded files. This ALSO erases `id` from InTorrent's
// internal id->handle map - after this call, `id` is no longer valid
// for any other InTorrent function.
//
// Always call this when the user leaves a stream. Skipping it is
// exactly the class of bug that motivated building InTorrent in the
// first place - leftover handles that never get cleaned up.
//
// Returns 0 on success, -1 if `id` is unknown.
int32_t intorrent_remove(int32_t id);

#ifdef __cplusplus
}
#endif

#endif // INTORRENT_H
