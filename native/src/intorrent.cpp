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

#include <memory>
#include <mutex>
#include <unordered_map>
#include <atomic>

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
