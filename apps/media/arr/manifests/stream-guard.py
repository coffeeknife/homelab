#!/usr/bin/env python3
"""stream-guard — stop qBittorrent torrents while Jellyfin is streaming.

qbittorrent writes downloads into the same NFS export Jellyfin reads from
(/mnt/birdpool/jellyfin/media). birdpool's 7.3T member is SMR and ~86% full,
so torrent writes (scattered, piece-order) stall the pool badly enough that
Jellyfin's sequential reads queue behind them and direct play freezes every
few seconds. Diagnosed 2026-08-12: qbit at 3.3MB/s of downloads overlapped
exactly with the stutter, and playback smoothed out when it drained.

State lives in a qBittorrent TAG, not in a local file. An emptyDir state file
would die with the pod and leave torrents stopped forever; the tag survives
restarts, reboots and redeploys, and is visible/clearable in the WebUI.

Only torrents this guard stopped are ever restarted — torrents you stopped
yourself are never touched.
"""
import http.cookiejar
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "http://jellyfin.jellyfin.svc.cluster.local:8096")
JELLYFIN_TOKEN = os.environ["JELLYFIN_TOKEN"]
QBIT_URL = os.environ.get("QBIT_URL", "http://qbittorrent-vpn.arr-stack.svc.cluster.local:8080")
QBIT_USER = os.environ["QBITTORRENT_USER"]
QBIT_PASS = os.environ["QBITTORRENT_PASS"]

TAG = os.environ.get("GUARD_TAG", "stream-paused")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "30"))
GRACE_CYCLES = int(os.environ.get("GRACE_CYCLES", "2"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"

# qBittorrent 5.x renamed paused* -> stopped*; accept both so a version bump
# doesn't silently make every torrent look active.
STOPPED_PREFIXES = ("stopped", "paused")

_opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
)


def log(msg):
    print(f"[stream-guard] {msg}", flush=True)


def _request(url, data=None, headers=None, timeout=15):
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers or {})
    with _opener.open(req, timeout=timeout) as resp:
        return resp.read().decode()


def qbit_login():
    out = _request(
        f"{QBIT_URL}/api/v2/auth/login",
        data={"username": QBIT_USER, "password": QBIT_PASS},
        headers={"Referer": QBIT_URL},
    )
    if out.strip() != "Ok.":
        raise RuntimeError(f"qbittorrent login rejected: {out.strip()!r}")


def qbit_post(path, data):
    """POST, transparently re-logging in if the session cookie expired."""
    try:
        return _request(f"{QBIT_URL}{path}", data=data)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            log("qbittorrent session expired, re-authenticating")
            qbit_login()
            return _request(f"{QBIT_URL}{path}", data=data)
        raise


def qbit_torrents():
    return json.loads(qbit_post("/api/v2/torrents/info", None) or "[]")


def is_stopped(torrent):
    return torrent.get("state", "").startswith(STOPPED_PREFIXES)


def has_tag(torrent):
    return TAG in [t.strip() for t in torrent.get("tags", "").split(",") if t.strip()]


def jellyfin_active_streams():
    """Sessions currently holding a media item.

    A paused-but-loaded session still counts: it holds a buffer and will almost
    certainly resume, and flapping torrents on every pause press would be worse
    than staying stopped.
    """
    req = urllib.request.Request(
        f"{JELLYFIN_URL}/Sessions", headers={"X-Emby-Token": JELLYFIN_TOKEN}
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        sessions = json.load(resp)
    return [
        f"{s.get('UserName', '?')} on {s.get('Client', '?')} "
        f"playing {s.get('NowPlayingItem', {}).get('Name', '?')}"
        for s in sessions
        if s.get("NowPlayingItem")
    ]


def stop_active(torrents):
    targets = [t for t in torrents if not is_stopped(t)]
    if not targets:
        return
    hashes = "|".join(t["hash"] for t in targets)
    names = ", ".join(t.get("name", "?")[:60] for t in targets)
    if DRY_RUN:
        log(f"DRY_RUN would tag+stop {len(targets)} torrent(s): {names}")
        return
    # Tag first: if the stop call fails we still know what we touched, whereas
    # stopping first and failing to tag would strand them untracked.
    qbit_post("/api/v2/torrents/addTags", {"hashes": hashes, "tags": TAG})
    qbit_post("/api/v2/torrents/stop", {"hashes": hashes})
    log(f"stopped {len(targets)} torrent(s): {names}")


def resume_tagged(torrents):
    targets = [t for t in torrents if has_tag(t)]
    if not targets:
        return
    hashes = "|".join(t["hash"] for t in targets)
    names = ", ".join(t.get("name", "?")[:60] for t in targets)
    if DRY_RUN:
        log(f"DRY_RUN would start+untag {len(targets)} torrent(s): {names}")
        return
    qbit_post("/api/v2/torrents/start", {"hashes": hashes})
    qbit_post("/api/v2/torrents/removeTags", {"hashes": hashes, "tags": TAG})
    log(f"resumed {len(targets)} torrent(s): {names}")


def shutdown(signum, _frame):
    """Resume on the way out so a rollout can never strand torrents stopped.

    If a stream is still playing the replacement pod re-stops them within one
    interval; a few seconds of torrent traffic beats leaving them stopped
    indefinitely because a deploy happened to land mid-stream.
    """
    log(f"caught signal {signum}, resuming tagged torrents before exit")
    try:
        qbit_login()
        resume_tagged(qbit_torrents())
    except Exception as e:
        log(f"ERROR during shutdown resume: {e} (tag '{TAG}' still marks them in the WebUI)")
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    log(
        f"starting: jellyfin={JELLYFIN_URL} qbit={QBIT_URL} tag={TAG} "
        f"interval={INTERVAL}s grace={GRACE_CYCLES} dry_run={DRY_RUN}"
    )
    qbit_login()

    idle_cycles = 0
    was_streaming = None

    while True:
        try:
            streams = jellyfin_active_streams()
            torrents = qbit_torrents()

            if streams:
                idle_cycles = 0
                if was_streaming is not True:
                    log(f"stream active ({len(streams)}): {'; '.join(streams)}")
                stop_active(torrents)
                was_streaming = True
            else:
                idle_cycles += 1
                if was_streaming is not False:
                    log(f"no active streams (grace {idle_cycles}/{GRACE_CYCLES})")
                if idle_cycles >= GRACE_CYCLES:
                    resume_tagged(torrents)
                    was_streaming = False
        except Exception as e:
            # Never die on a transient API hiccup: a dead guard is what leaves
            # torrents stopped. Log and retry on the next cycle.
            log(f"ERROR: {type(e).__name__}: {e}")

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
