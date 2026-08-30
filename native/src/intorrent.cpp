// intorrent.cpp
//
// Owns the ONE global libtorrent session for the app's lifetime,
// and the ONE id -> torrent_handle map that every other InTorrent
// function will look up into. See intorrent.h for the public
// (Dart-facing) contract.

#include "intorrent.h"

#include <libtorrent/session.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_flags.hpp>

#include <memory>
#include <mutex>
#include <unordered_map>
#include <atomic>
#include <cstring>

namespace {

// ---- The session singleton -------------------------------------------
//
// Lazy init: created the first time it's needed (first addMagnet call),
// lives for the rest of the process. Guarded by a mutex so two threads
// racing to create it can't accidentally create two sessions.

std::mutex g_session_mutex;
std::unique_ptr<lt::session> g_session;

lt::session& get_session() {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    if (!g_session) {
        lt::settings_pack settings;
        settings.set_int(lt::settings_pack::alert_mask,
                          lt::alert_category::status |
                          lt::alert_category::error);

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
        // all interfaces (both v4 and v6) ourselves, so libtorrent never
        // needs to touch netlink to figure that out.
        settings.set_str(lt::settings_pack::listen_interfaces,
                          "0.0.0.0:6881,[::]:6881");

        g_session = std::make_unique<lt::session>(settings);
    }
    return *g_session;
}

// ---- The id -> handle map ----------------------------------------------
//
// This map is the ONLY source of truth for "what torrents exist right
// now, from InTorrent's point of view." Every function that takes an
// id (getStatus, pause, resume, remove) looks up into this same map.
// addMagnet is the only place that inserts into it; remove() will be
// the only place that erases from it.

std::mutex g_handles_mutex;
std::unordered_map<int32_t, lt::torrent_handle> g_handles;
std::atomic<int32_t> g_next_id{1};

} // namespace

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

    // Sequential-order piece priority is set later, in streamUrl() -
    // addMagnet's only job is to register the torrent and hand back
    // a stable id.
    params.save_path = "."; // overridden properly once storage/download
                             // path handling is designed - placeholder
                             // for now so add_torrent() has a valid path.

    lt::torrent_handle handle = get_session().add_torrent(std::move(params), ec);
    if (ec || !handle.is_valid()) {
        return -1;
    }

    int32_t id = g_next_id.fetch_add(1);

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

} // namespace

// Small shared helper - every id-based function looks up into the same
// map the same way, so this stays in one place.
namespace {
bool find_handle(int32_t id, lt::torrent_handle& out_handle) {
    std::lock_guard<std::mutex> lock(g_handles_mutex);
    auto it = g_handles.find(id);
    if (it == g_handles.end()) {
        return false;
    }
    out_handle = it->second;
    return true;
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

    std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
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

    // Deprioritize every file, then set only the requested one to
    // top priority - we only want to spend bandwidth on what's
    // actually being streamed.
    std::vector<lt::download_priority_t> priorities(
        files.num_files(), lt::download_priority_t{0});
    priorities[file_index] = lt::download_priority_t{7};
    handle.prioritize_files(priorities);

    // Sequential (playback-order) piece downloading instead of
    // libtorrent's default rarest-first - essential for streaming.
    handle.set_flags(lt::torrent_flags::sequential_download,
                      lt::torrent_flags::sequential_download);

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
    lt::torrent_handle handle;
    if (!find_handle(id, handle) || !handle.is_valid()) {
        return -1;
    }

    std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
    if (!info) {
        return -1;
    }

    const lt::file_storage& files = info->layout();
    if (file_index < 0 || file_index >= files.num_files()) {
        return -1;
    }
    const lt::file_index_t fidx{file_index};

    lt::torrent_status status = handle.status(lt::torrent_handle::query_pieces);

    // Convert the file-relative byte range into torrent-relative piece
    // indices, then check every piece in that range is marked downloaded.
    const std::int64_t file_offset = files.file_offset(fidx);
    const std::int64_t piece_size = info->piece_length();

    const std::int64_t range_start = file_offset + start;
    const std::int64_t range_end = file_offset + start + length; // exclusive

    const int first_piece = static_cast<int>(range_start / piece_size);
    const int last_piece = static_cast<int>((range_end - 1) / piece_size);

    for (int piece = first_piece; piece <= last_piece; ++piece) {
        const lt::piece_index_t pidx{piece};
        if (piece < 0 || piece >= status.pieces.size() || !status.pieces[pidx]) {
            return 0; // at least one needed piece isn't downloaded yet
        }
    }

    return 1;
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

    if (handle.is_valid()) {
        get_session().remove_torrent(handle, lt::session_handle::delete_files);
    }

    return 0;
}
