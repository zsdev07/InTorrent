// intorrent.cpp
//
// Owns the ONE global libtorrent session for the app's lifetime,
// and the ONE id -> torrent_handle map that every other InTorrent
// function will look up into. See intorrent.h for the public
// (Dart-facing) contract.
//
// CHANGELOG (streaming / buffering overhaul)
//   * The streamed file is now priority 4 (default), NOT 7. 7 is
//     libtorrent's top_priority, and in sequential mode the picker walks
//     every top-priority piece in availability/random order BEFORE the
//     real in-order loop runs - so marking the whole file 7 silently
//     turned "sequential download" into "random download". Priority 7 is
//     now only ever applied (by set_piece_deadline) to the few pieces the
//     player needs right now.
//   * alert_mask narrowed from all_categories to error|status. The old
//     mask made libtorrent format ~8,000 log alerts per second on its
//     network thread (peer_log/picker_log/dht_log...) and we wrote each
//     one to logcat.
//   * Session tuned for streaming (tracker announces, request timeouts,
//     upload cap, extra DHT bootstrap nodes, no seed-dropping).
//   * Each torrent gets its own save directory, so a leftover file from
//     an earlier run can never trigger a multi-second re-hash on start.
//   * Piece availability + torrent_info are cached per torrent, so the
//     Dart side no longer makes two blocking calls into libtorrent's
//     network thread for every 64 KB it serves.
//   * New: intorrent_available_bytes, intorrent_release_range,
//     intorrent_prefetch_start, intorrent_prefetch_cancel.

#include "intorrent.h"

#include <libtorrent/session.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/bitfield.hpp>

#include <memory>
#include <mutex>
#include <unordered_map>
#include <atomic>
#include <cstring>
#include <chrono>
#include <ctime>
#include <thread>
#include <string>
#include <vector>
#include <algorithm>

#include <android/log.h>
#define INTORRENT_ALERT_TAG "InTorrentAlert"

namespace {

// ---- Tunables -----------------------------------------------------------

// Priority given to the streamed file. MUST stay below 7 (top_priority),
// see the changelog above.
constexpr int kStreamPriority = 4;

// A deadline window covers at most this many pieces...
constexpr int kMaxWindowPieces = 16;

// ...and pieces inside a window get deadlines this far apart (ms). Only
// the ORDER matters to libtorrent (earliest deadline is requested from the
// fastest peers first); libtorrent itself ignores deadlines that are too
// far in the future.
constexpr int kDeadlineStepMs = 400;

// How stale (ms) the cached piece bitfield may be before we refresh it.
// The bitfield is monotonic (pieces are never un-had), so a stale copy can
// only ever under-report availability - never over-report it.
constexpr int kHaveMaxAgeMs = 100;

// ---- The session singleton -------------------------------------------
//
// Lazy init: created the first time it's needed (first addMagnet call),
// lives for the rest of the process. Guarded by a mutex so two threads
// racing to create it can't accidentally create two sessions.

std::mutex g_session_mutex;
std::unique_ptr<lt::session> g_session;

// Set via intorrent_init() before the session exists. Falls back to
// the wildcard form (see intorrent_init's doc comment in intorrent.h
// for why that's Android-problematic) if never called.
std::string g_listen_interfaces = "0.0.0.0:6881,[::]:6881";

// Set via intorrent_init() before the first addMagnet(). Falls back
// to the broken "." placeholder (resolves to an unwritable directory
// on Android - see intorrent_init's doc comment) if never called.
std::string g_save_path = ".";

// ---- Alert pump ---------------------------------------------------------
//
// Drains the alerts we ask for and logs each one's own message() to
// logcat (`logcat -s InTorrentAlert`). With the narrowed alert_mask below
// this is quiet: only errors and torrent-state changes. Build with
// -DINTORRENT_VERBOSE_ALERTS to get the old firehose back when debugging
// peer/DHT problems.
void alert_pump_loop(lt::session* session) {
    for (;;) {
        session->wait_for_alert(std::chrono::seconds(30));
        std::vector<lt::alert*> alerts;
        session->pop_alerts(&alerts);
        for (lt::alert* a : alerts) {
            __android_log_print(ANDROID_LOG_DEBUG, INTORRENT_ALERT_TAG,
                                 "%s", a->message().c_str());
        }
    }
}

lt::session& get_session() {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    if (!g_session) {
        lt::settings_pack settings;

#ifdef INTORRENT_VERBOSE_ALERTS
        settings.set_int(lt::settings_pack::alert_mask,
                          lt::alert::all_categories);
#else
        settings.set_int(lt::settings_pack::alert_mask,
                          lt::alert::error_notification
                              | lt::alert::status_notification);
#endif

        // Android's SELinux policy denies untrusted apps direct netlink
        // route-socket access (bind() -> EACCES), which is exactly what
        // libtorrent's default interface auto-detection relies on to
        // decide what to listen on. Left alone, that auto-detection
        // silently fails and the session never opens a working
        // listen/DHT socket at all - no outbound UDP ever leaves the
        // device, so peers/trackers/DHT all stay at 0 forever, even
        // though the torrent and network are both fine.
        //
        // Fix: bypass auto-detection entirely and explicitly listen on
        // the interface Dart gave us (or all interfaces as a fallback)
        // so libtorrent never needs to touch netlink to figure that out.
        settings.set_str(lt::settings_pack::listen_interfaces,
                          g_listen_interfaces);

        // libtorrent's optional network-change auto-detection
        // (enable_ip_notifier, ON by default) opens its own netlink
        // socket purely to notice WiFi/mobile handovers - completely
        // separate from the actual torrent listen socket above. That
        // netlink call is the SAME kind Android's SELinux denies to
        // regular apps, and libtorrent's generic exception wrapper
        // (session_impl::wrap()) treats ANY exception from it as fatal
        // and calls pause() - aborting every tracker announce and
        // pausing every torrent in the whole session. We don't need auto
        // re-listen-on-network-change for this use case, so turn it off.
        settings.set_bool(lt::settings_pack::enable_ip_notifier, false);

        // ---- Streaming tuning ------------------------------------------

        // Keep seed connections open even when every *wanted* piece is
        // done. Required by the pause-prefetch feature: once the
        // prefetch window completes, libtorrent considers the torrent
        // "finished" and (with the default of true) disconnects every
        // seed - which would make resuming playback stall while peers are
        // re-found.
        settings.set_bool(lt::settings_pack::close_redundant_connections, false);

        // Magnets from Torrentio carry several trackers. Announce to all
        // of them (instead of stopping at the first tier that answers) -
        // faster peer discovery on a cold start.
        settings.set_bool(lt::settings_pack::announce_to_all_trackers, true);
        settings.set_bool(lt::settings_pack::announce_to_all_tiers, true);

        // A block requested from a peer that has never delivered anything
        // used to be held for the full 60 s before another peer could
        // take it over (piece_timeout 20 s). One dead peer holding the
        // block a player is waiting on = a 20-60 s buffering stall.
        settings.set_int(lt::settings_pack::request_timeout, 10);
        settings.set_int(lt::settings_pack::piece_timeout, 10);

        // Upload is useless to a streaming-only app but a totally
        // unlimited uplink can saturate the connection and delay the ACKs
        // for the download. Capped (bytes/s), not zeroed: peers still
        // unchoke us more readily when we reciprocate a little.
        settings.set_int(lt::settings_pack::upload_rate_limit, 256 * 1024);

        // The default is a single bootstrap host. More routers = the DHT
        // comes up faster and survives one of them being unreachable.
        settings.set_str(lt::settings_pack::dht_bootstrap_nodes,
                          "dht.libtorrent.org:25401,"
                          "router.bittorrent.com:6881,"
                          "router.utorrent.com:6881,"
                          "dht.transmissionbt.com:6881");

        g_session = std::make_unique<lt::session>(settings);

        // Detached on purpose - it's meant to run for the whole process
        // lifetime, same as g_session itself.
        std::thread(alert_pump_loop, g_session.get()).detach();
    }
    return *g_session;
}

// ---- The id -> handle map ----------------------------------------------
//
// This map is the ONLY source of truth for "what torrents exist right
// now, from InTorrent's point of view." Every function that takes an
// id (getStatus, pause, resume, remove) looks up into this same map.
// addMagnet is the only place that inserts into it; remove() is the
// only place that erases from it.

std::mutex g_handles_mutex;
std::unordered_map<int32_t, lt::torrent_handle> g_handles;
std::atomic<int32_t> g_next_id{1};

// ---- Per-torrent streaming context -------------------------------------
//
// Everything here is a CACHE or bookkeeping, never a source of truth:
//   * info / have: avoid blocking round-trips into libtorrent's network
//     thread (torrent_file() and status(query_pieces) are both
//     synchronous calls) on every 64 KB the HTTP server hands out.
//   * file_index / prefetch_*: remember what prepare_stream and
//     prefetch_start decided, so release/cancel can undo it.

struct StreamCtx {
    std::shared_ptr<const lt::torrent_info> info;
    int file_index = -1;

    lt::typed_bitfield<lt::piece_index_t> have;
    std::chrono::steady_clock::time_point have_at{};
    bool have_valid = false;

    bool prefetch_active = false;
    int pf_first = 0;   // torrent-relative piece range of the prefetch
    int pf_last = -1;   // window, inclusive
};

std::mutex g_ctx_mutex;
std::unordered_map<int32_t, StreamCtx> g_ctx;

// Unique per process, so a save directory can never collide with one left
// behind by an earlier run of the app.
std::string make_run_token() {
    return std::to_string(static_cast<long long>(std::time(nullptr)));
}
const std::string g_run_token = make_run_token();

} // namespace

extern "C" void intorrent_init(const char* listen_interfaces, const char* save_path) {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    if (g_session) {
        // Session already exists (e.g. addMagnet was called first) -
        // too late for this to take effect, same as if it were never
        // called at all. Not treated as an error since callers aren't
        // required to call this before every possible entry point.
        return;
    }
    if (listen_interfaces != nullptr) {
        g_listen_interfaces = listen_interfaces;
    }
    if (save_path != nullptr) {
        g_save_path = save_path;
    }
}

extern "C" int32_t intorrent_add_magnet(const char* uri) {
    if (uri == nullptr) {
        return -1;
    }

    lt::add_torrent_params params;
    lt::error_code ec;

    lt::parse_magnet_uri(uri, params, ec);
    if (ec) {
        // Malformed magnet URI - nothing added, nothing to clean up.
        return -1;
    }

    // Sequential download is set HERE, before add_torrent() ever runs, so
    // no peer connection (and therefore no piece request) can happen
    // before sequential mode is on. File priorities can't be set here -
    // which file is being streamed isn't known until metadata arrives -
    // so that part stays in intorrent_prepare_stream().
    params.flags |= lt::torrent_flags::sequential_download;

    // Allocate the id first: it names this torrent's private save
    // directory. g_save_path/<run-token>_<id> can't contain leftovers
    // from a previous session, so libtorrent never has to spend seconds
    // hashing a stale multi-GB file (seen in the wild: ~20 s in
    // "checking" before the first piece was even requested).
    const int32_t id = g_next_id.fetch_add(1);
    params.save_path = g_save_path + "/" + g_run_token + "_" + std::to_string(id);

    lt::torrent_handle handle = get_session().add_torrent(std::move(params), ec);
    if (ec || !handle.is_valid()) {
        return -1;
    }

    {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        g_ctx[id] = StreamCtx{};
    }
    {
        std::lock_guard<std::mutex> lock(g_handles_mutex);
        g_handles[id] = handle;
    }

    return id;
}

namespace {

// Translates libtorrent's own state_t into InTorrent's own stable
// enum, so a libtorrent upgrade can never silently change what our
// Dart side sees.
int32_t translate_state(lt::torrent_status::state_t lt_state) {
    switch (lt_state) {
        case lt::torrent_status::checking_files:
            return INTORRENT_STATE_CHECKING;
        case lt::torrent_status::downloading_metadata:
            return INTORRENT_STATE_DOWNLOADING_METADATA;
        case lt::torrent_status::downloading:
            return INTORRENT_STATE_DOWNLOADING;
        case lt::torrent_status::finished:
            return INTORRENT_STATE_FINISHED;
        case lt::torrent_status::seeding:
            return INTORRENT_STATE_SEEDING;
        default:
            return INTORRENT_STATE_UNKNOWN;
    }
}

// Small shared helper - every id-based function looks up into the same
// map the same way, so this stays in one place.
bool find_handle(int32_t id, lt::torrent_handle& out_handle) {
    std::lock_guard<std::mutex> lock(g_handles_mutex);
    auto it = g_handles.find(id);
    if (it == g_handles.end()) {
        return false;
    }
    out_handle = it->second;
    return true;
}

// torrent_info, cached per torrent. handle.torrent_file() is a blocking
// call into libtorrent's network thread; the info is immutable once
// metadata has arrived, so it is fetched at most once per torrent.
std::shared_ptr<const lt::torrent_info> get_info(int32_t id,
                                                 const lt::torrent_handle& handle) {
    {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        auto it = g_ctx.find(id);
        if (it != g_ctx.end() && it->second.info) {
            return it->second.info;
        }
    }
    std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
    if (info) {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        auto it = g_ctx.find(id);
        if (it != g_ctx.end()) {
            it->second.info = info;
        }
    }
    return info;
}

// Piece bitfield, cached for max_age_ms. Returns false if the torrent is
// unknown (removed meanwhile).
bool get_have(int32_t id, const lt::torrent_handle& handle, int max_age_ms,
              lt::typed_bitfield<lt::piece_index_t>& out) {
    {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        auto it = g_ctx.find(id);
        if (it == g_ctx.end()) {
            return false;
        }
        const StreamCtx& c = it->second;
        if (c.have_valid &&
            std::chrono::steady_clock::now() - c.have_at <
                std::chrono::milliseconds(max_age_ms)) {
            out = c.have;
            return true;
        }
    }

    // Outside the lock: this is a blocking call into libtorrent.
    lt::torrent_status st = handle.status(lt::torrent_handle::query_pieces);

    {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        auto it = g_ctx.find(id);
        if (it == g_ctx.end()) {
            return false;
        }
        it->second.have = st.pieces;
        it->second.have_at = std::chrono::steady_clock::now();
        it->second.have_valid = true;
    }
    out = st.pieces;
    return true;
}

// Number of contiguous downloaded bytes of file `fidx` starting at
// `start`, looking at most `max_len` bytes ahead.
std::int64_t contiguous_bytes(const lt::typed_bitfield<lt::piece_index_t>& have,
                              const lt::torrent_info& info,
                              lt::file_index_t fidx,
                              std::int64_t start,
                              std::int64_t max_len) {
    const lt::file_storage& files = info.layout();
    const std::int64_t file_size = files.file_size(fidx);
    if (start < 0 || max_len <= 0 || start >= file_size) {
        return 0;
    }
    const std::int64_t file_off = files.file_offset(fidx);
    const std::int64_t piece_size = info.piece_length();
    const std::int64_t limit = std::min<std::int64_t>(file_size, start + max_len);

    std::int64_t pos = start;
    while (pos < limit) {
        const std::int64_t piece = (file_off + pos) / piece_size;
        if (piece >= static_cast<std::int64_t>(have.size()) ||
            !have[lt::piece_index_t{static_cast<int>(piece)}]) {
            break;
        }
        // File-relative, exclusive end of this piece.
        const std::int64_t piece_end = (piece + 1) * piece_size - file_off;
        pos = std::min<std::int64_t>(piece_end, limit);
    }
    return pos - start;
}

// Torrent-relative piece span [first, last] covering bytes
// [start, start + length) of file `fidx`, clamped to the file. Returns
// false if the range is empty or outside the file.
bool piece_span(const lt::torrent_info& info, lt::file_index_t fidx,
                std::int64_t start, std::int64_t length,
                int& first, int& last) {
    const lt::file_storage& files = info.layout();
    const std::int64_t file_size = files.file_size(fidx);
    if (start < 0 || length <= 0 || start >= file_size) {
        return false;
    }
    const std::int64_t safe_len = std::min<std::int64_t>(length, file_size - start);
    const std::int64_t piece_size = info.piece_length();
    const std::int64_t first_byte = files.file_offset(fidx) + start;
    first = static_cast<int>(first_byte / piece_size);
    last = static_cast<int>((first_byte + safe_len - 1) / piece_size);
    return true;
}

// Priority a piece should have when it is NOT being held at top priority
// by a deadline: inside an active prefetch window it's the normal stream
// priority, outside it's 0 (not wanted); with no prefetch active it's the
// normal stream priority.
lt::download_priority_t baseline_priority(int32_t id, int piece) {
    std::lock_guard<std::mutex> lock(g_ctx_mutex);
    auto it = g_ctx.find(id);
    if (it != g_ctx.end() && it->second.prefetch_active) {
        const bool inside = piece >= it->second.pf_first && piece <= it->second.pf_last;
        return lt::download_priority_t{static_cast<std::uint8_t>(inside ? kStreamPriority : 0)};
    }
    return lt::download_priority_t{static_cast<std::uint8_t>(kStreamPriority)};
}

// Sets piece priorities for the whole torrent in one call: pieces in
// [lo, hi] get the stream priority, everything else 0.
void apply_piece_mask(const lt::torrent_handle& handle,
                      const lt::torrent_info& info, int lo, int hi) {
    std::vector<lt::download_priority_t> prios(
        static_cast<std::size_t>(info.num_pieces()), lt::download_priority_t{0});
    for (int p = std::max(lo, 0); p <= hi && p < info.num_pieces(); ++p) {
        prios[static_cast<std::size_t>(p)] =
            lt::download_priority_t{static_cast<std::uint8_t>(kStreamPriority)};
    }
    handle.prioritize_pieces(prios);
}

// Gives the first kMaxWindowPieces MISSING pieces of the byte range
// increasing deadlines, so libtorrent requests them in order, from its
// fastest peers, and re-requests from other peers when one is slow.
// set_piece_deadline itself lifts each such piece to top priority.
void apply_deadline_window(int32_t id, lt::torrent_handle& handle,
                           const lt::torrent_info& info, lt::file_index_t fidx,
                           std::int64_t start, std::int64_t length) {
    int first = 0;
    int last = 0;
    if (!piece_span(info, fidx, start, length, first, last)) {
        return;
    }
    last = std::min(last, first + kMaxWindowPieces - 1);

    lt::typed_bitfield<lt::piece_index_t> have;
    const bool have_ok = get_have(id, handle, kHaveMaxAgeMs, have);

    int slot = 0;
    for (int piece = first; piece <= last; ++piece) {
        if (have_ok && piece < have.size() &&
            have[lt::piece_index_t{piece}]) {
            continue;
        }
        handle.set_piece_deadline(lt::piece_index_t{piece}, slot * kDeadlineStepMs);
        ++slot;
    }
}

} // namespace

extern "C" int32_t intorrent_get_status(int32_t id, IntorrentStatus* out_status) {
    if (out_status == nullptr) {
        return -1;
    }

    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    lt::torrent_status status = handle.status();

    out_status->total_bytes = status.total_wanted;
    out_status->downloaded_bytes = status.total_wanted_done;
    out_status->progress = status.progress;
    out_status->state = translate_state(status.state);
    out_status->num_peers = status.num_peers;
    out_status->num_seeds = status.num_seeds;
    out_status->is_paused = (status.flags & lt::torrent_flags::paused) ? 1 : 0;

    return 0;
}

extern "C" int32_t intorrent_get_file_count(int32_t id) {
    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }
    std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info) {
        // Metadata hasn't arrived yet - same "not ready" contract as
        // intorrent_prepare_stream.
        return -1;
    }
    return info->layout().num_files();
}

extern "C" int32_t intorrent_get_file_info(int32_t id, int32_t file_index,
                                            char* out_name, int32_t name_buf_len,
                                            int64_t* out_size) {
    if (out_name == nullptr || out_size == nullptr) {
        return -1;
    }
    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }
    std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info) {
        return -1;
    }
    const lt::file_storage& files = info->layout();
    if (file_index < 0 || file_index >= files.num_files()) {
        return -1;
    }
    const lt::file_index_t fidx{file_index};

    // file_name() returns just the leaf filename (no directory
    // components) - exactly what a caller picking "which file is the
    // video" wants, as opposed to file_path() (used by
    // intorrent_prepare_stream) which includes the on-disk save path.
    std::string name = std::string(files.file_name(fidx));

    if (static_cast<int32_t>(name.size()) >= name_buf_len) {
        return -1; // caller's buffer too small
    }

    std::strncpy(out_name, name.c_str(), name_buf_len);
    *out_size = files.file_size(fidx);

    return 0;
}

extern "C" int32_t intorrent_prepare_stream(int32_t id, int32_t file_index,
                                             char* out_path, int32_t path_buf_len,
                                             int64_t* out_size) {
    if (out_path == nullptr || out_size == nullptr) {
        return -1;
    }

    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info) {
        // Metadata hasn't arrived yet - caller should wait and retry
        // (check status.state == INTORRENT_STATE_DOWNLOADING_METADATA).
        return -1;
    }

    const lt::file_storage& files = info->layout();
    if (file_index < 0 || file_index >= files.num_files()) {
        return -1;
    }
    const lt::file_index_t fidx{file_index};

    // Deprioritize every file, then enable only the requested one - we
    // only want to spend bandwidth on what's actually being streamed.
    //
    // IMPORTANT: kStreamPriority (4), NOT 7. Priority 7 is libtorrent's
    // top_priority; in sequential mode the picker first walks ALL
    // top-priority pieces in availability (i.e. effectively random)
    // order and only then runs the strict in-order loop over the
    // remaining pieces - which skips top-priority ones. Marking the
    // whole file 7 therefore disables in-order downloading entirely.
    std::vector<lt::download_priority_t> priorities(
        files.num_files(), lt::download_priority_t{0});
    priorities[file_index] =
        lt::download_priority_t{static_cast<std::uint8_t>(kStreamPriority)};
    handle.prioritize_files(priorities);

    // Sequential mode is actually enabled back in intorrent_add_magnet()
    // now; this is just a no-op safety net.
    handle.set_flags(lt::torrent_flags::sequential_download,
                      lt::torrent_flags::sequential_download);

    {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        auto it = g_ctx.find(id);
        if (it != g_ctx.end()) {
            it->second.file_index = file_index;
        }
    }

    // NOTE: the old "bump the last 4 MiB to priority 7" block is gone on
    // purpose. Players (mpv/ffmpeg on MKV) do request the tail of the
    // file for the Cues index, but that request already arrives through
    // the HTTP server, which asks for exactly those pieces via
    // intorrent_prioritize_range() at the moment they're needed. A
    // permanent top-priority tail only competed with the head of the file
    // at startup.

    // Kick off the first pieces straight away (deadline window over the
    // head of the file) instead of waiting for the player's first request.
    apply_deadline_window(id, handle, *info, fidx, 0,
                          static_cast<std::int64_t>(kMaxWindowPieces) * info->piece_length());

    std::string save_path = handle.status().save_path;
    std::string file_path = files.file_path(fidx, save_path);

    if (static_cast<int32_t>(file_path.size()) >= path_buf_len) {
        return -1; // caller's buffer too small
    }

    std::strncpy(out_path, file_path.c_str(), path_buf_len);
    *out_size = files.file_size(fidx);

    return 0;
}

extern "C" int32_t intorrent_is_range_available(int32_t id, int32_t file_index,
                                                 int64_t start, int64_t length) {
    if (start < 0 || length <= 0) {
        return -1;
    }
    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info) {
        return -1;
    }
    if (file_index < 0 || file_index >= info->layout().num_files()) {
        return -1;
    }

    lt::typed_bitfield<lt::piece_index_t> have;
    if (!get_have(id, handle, kHaveMaxAgeMs, have)) {
        return -1;
    }

    const std::int64_t avail =
        contiguous_bytes(have, *info, lt::file_index_t{file_index}, start, length);
    return avail >= length ? 1 : 0;
}

extern "C" int64_t intorrent_available_bytes(int32_t id, int32_t file_index,
                                              int64_t start, int64_t max_len) {
    if (start < 0 || max_len <= 0) {
        return -1;
    }
    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info) {
        return -1;
    }
    if (file_index < 0 || file_index >= info->layout().num_files()) {
        return -1;
    }

    lt::typed_bitfield<lt::piece_index_t> have;
    if (!get_have(id, handle, kHaveMaxAgeMs, have)) {
        return -1;
    }

    return contiguous_bytes(have, *info, lt::file_index_t{file_index}, start, max_len);
}

extern "C" int32_t intorrent_prioritize_range(
    int32_t id,
    int32_t file_index,
    int64_t start,
    int64_t length) {
    if (start < 0 || length <= 0) {
        return -1;
    }

    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    const std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info) {
        return -1;
    }

    const lt::file_storage& files = info->layout();
    if (file_index < 0 || file_index >= files.num_files()) {
        return -1;
    }
    if (start >= files.file_size(lt::file_index_t{file_index})) {
        return -1;
    }

    // A deadline WINDOW (a handful of pieces with increasing deadlines),
    // not a single deadline-0 piece: libtorrent then always knows what is
    // needed next, requests it in order from its fastest peers, and
    // re-requests from other peers if the first one is slow.
    apply_deadline_window(id, handle, *info, lt::file_index_t{file_index},
                          start, length);
    return 0;
}

extern "C" int32_t intorrent_release_range(
    int32_t id,
    int32_t file_index,
    int64_t start,
    int64_t length) {
    if (start < 0 || length <= 0) {
        return -1;
    }

    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    const std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info) {
        return -1;
    }
    if (file_index < 0 || file_index >= info->layout().num_files()) {
        return -1;
    }

    int first = 0;
    int last = 0;
    if (!piece_span(*info, lt::file_index_t{file_index}, start, length, first, last)) {
        return 0; // nothing to release
    }
    last = std::min(last, first + kMaxWindowPieces - 1);

    lt::typed_bitfield<lt::piece_index_t> have;
    const bool have_ok = get_have(id, handle, kHaveMaxAgeMs, have);

    for (int piece = first; piece <= last; ++piece) {
        if (have_ok && piece < have.size() &&
            have[lt::piece_index_t{piece}]) {
            continue;
        }
        const lt::piece_index_t pidx{piece};
        handle.reset_piece_deadline(pidx);
        handle.piece_priority(pidx, baseline_priority(id, piece));
    }
    return 0;
}

extern "C" int32_t intorrent_prefetch_start(int32_t id, int32_t file_index,
                                             int64_t start, int64_t length) {
    if (start < 0 || length <= 0) {
        return -1;
    }

    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    const std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info) {
        return -1;
    }
    if (file_index < 0 || file_index >= info->layout().num_files()) {
        return -1;
    }

    int first = 0;
    int last = 0;
    if (!piece_span(*info, lt::file_index_t{file_index}, start, length, first, last)) {
        return -1;
    }

    // Order of operations matters:
    //  1. record the window first, so a concurrent release_range()
    //     restores priorities consistently with the mask;
    //  2. drop every deadline: libtorrent's whole-piece/contiguous
    //     picking (the fast path) is disabled while any time-critical
    //     piece exists;
    //  3. apply the mask.
    //
    // Mask = window pieces at stream priority, EVERYTHING else at 0. With
    // no other piece wanted, the sequential picker walks the window
    // strictly in order, at full speed, and stops at the end of it - the
    // "up to N minutes ahead, in order, never random" behaviour.
    {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        auto it = g_ctx.find(id);
        if (it == g_ctx.end()) {
            return -1;
        }
        it->second.prefetch_active = true;
        it->second.pf_first = first;
        it->second.pf_last = last;
    }

    handle.clear_piece_deadlines();
    apply_piece_mask(handle, *info, first, last);
    return 0;
}

extern "C" int32_t intorrent_prefetch_cancel(int32_t id) {
    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    int file_index = -1;
    {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        auto it = g_ctx.find(id);
        if (it == g_ctx.end()) {
            return -1;
        }
        if (!it->second.prefetch_active) {
            return 0; // idempotent: nothing to cancel
        }
        it->second.prefetch_active = false;
        file_index = it->second.file_index;
    }

    const std::shared_ptr<const lt::torrent_info> info = get_info(id, handle);
    if (!info || file_index < 0 || file_index >= info->layout().num_files()) {
        return -1;
    }

    // Everything downloaded so far stays exactly where it is (it's the
    // same torrent, the same file). Just re-open the whole streamed file
    // to normal in-order downloading.
    int first = 0;
    int last = 0;
    const lt::file_storage& files = info->layout();
    const lt::file_index_t fidx{file_index};
    if (!piece_span(*info, fidx, 0, files.file_size(fidx), first, last)) {
        return -1;
    }
    apply_piece_mask(handle, *info, first, last);
    return 0;
}

extern "C" int32_t intorrent_pause(int32_t id) {
    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }
    handle.pause();
    return 0;
}

extern "C" int32_t intorrent_resume(int32_t id) {
    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }
    handle.resume();
    return 0;
}

extern "C" int32_t intorrent_remove(int32_t id) {
    lt::torrent_handle handle;

    // Both steps happen under the same lock scope as the erase, so
    // there's no window where another call could look up an id that's
    // mid-removal.
    {
        std::lock_guard<std::mutex> lock(g_handles_mutex);
        auto it = g_handles.find(id);
        if (it == g_handles.end()) {
            return -1;
        }
        handle = it->second;
        g_handles.erase(it); // erase FIRST - id is invalid from this
                              // point on, even if remove_torrent below
                              // is still in progress.
    }
    {
        std::lock_guard<std::mutex> lock(g_ctx_mutex);
        g_ctx.erase(id);
    }

    if (handle.is_valid()) {
        get_session().remove_torrent(handle, lt::session_handle::delete_files);
    }

    return 0;
}
