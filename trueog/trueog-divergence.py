#!/usr/bin/env python3
"""Live ahead/behind counts for the fork banner on git.trueog.net.

A small HTTP service on 127.0.0.1:3992, run by OpenRC as the gitea user (/etc/init.d/trueog-divergence);
Nginx routes /-/trueog-divergence to it. The fork banner (custom templates/repo/code/
upstream_diverging_info.tmpl) asks:

    GET /-/trueog-divergence?fork=<owner>/<repo>&branch=<branch>&base=<owner>/<repo>&base_branch=<branch>

and gets {"ahead": N, "behind": M}, or {"unrelated": true} when the branches share no history; 404 when the
visitor cannot read both repositories' code or a branch does not exist. Every fork works, public or
private: for each repository Gitea itself is asked for its branch list (`/<owner>/<repo>/branches/list`,
which Gitea serves only to someone allowed to read that repository's code) with the visitor's own session
cookie, sent only to Gitea on 127.0.0.1. Branch tips are read from the repositories on disk and counted with
`git rev-list --left-right --count` through a scratch repository whose alternates point at both object
stores (nothing is copied). Counts are cached per commit pair, and identical requests in flight share one
count. At most 16 requests are handled at once (more get 503 at once) and at most four counts run at once;
every Gitea request and git call has a time limit. Nginx allows each visitor one request at a time and
rate-limits the route. Every answer from this service (including "busy") carries X-TrueOG-Divergence-Version,
the first 16 hex digits of the
SHA-256 of this file as the running process loaded it, so the installer and upgrade checks can tell a
stale process from the installed code.
"""

from __future__ import annotations

import collections
import hashlib
import http.client
import json
import os
import pathlib
import re
import subprocess
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GITEA_HOST = os.environ.get("TRUEOG_GITEA_HOST", "127.0.0.1")
GITEA_PORT = int(os.environ.get("TRUEOG_GITEA_PORT", "3000"))
REPO_ROOT = pathlib.Path(os.environ.get("TRUEOG_REPO_ROOT", "/opt/gitea/data/gitea-repositories"))
PORT = int(os.environ.get("TRUEOG_DIVERGENCE_PORT", "3992"))
ROUTE = "/-/trueog-divergence"
SAFE_FULL_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SHA = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")
CACHE_SIZE = 4096
VERSION = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()[:16]
MAX_ACTIVE = int(os.environ.get("TRUEOG_DIVERGENCE_MAX_ACTIVE", "16"))

cache: collections.OrderedDict = collections.OrderedDict()
cache_lock = threading.Lock()
slots = threading.BoundedSemaphore(4)
active = threading.BoundedSemaphore(MAX_ACTIVE)
inflight: dict = {}
inflight_lock = threading.Lock()


class NotFound(Exception):
    pass


class Busy(Exception):
    pass


def safe_full_name(full_name: str) -> bool:
    return bool(SAFE_FULL_NAME.fullmatch(full_name)) and not any(p in (".", "..") for p in full_name.split("/"))


def safe_branch(branch: str) -> bool:
    """A valid branch name by git's own rules (git check-ref-format), so `refs/heads/<branch>` can only
    name a branch: no reflog (`@{`), revision (`~ ^ :`) or glob syntax, no `..`, no empty, dot-leading or
    `.lock` components, no leading `-`."""
    if not 0 < len(branch) <= 255 or branch == "@" or branch.startswith("-"):
        return False
    if any(ord(c) < 33 or ord(c) == 127 or c in "~^:?*[\\" for c in branch):
        return False
    if ".." in branch or "@{" in branch or branch.endswith("."):
        return False
    return all(part and not part.startswith(".") and not part.endswith(".lock") for part in branch.split("/"))


def gitea_status(path: str, cookie: str | None = None) -> tuple[int, bytes]:
    connection = http.client.HTTPConnection(GITEA_HOST, GITEA_PORT, timeout=15)
    headers = {"Accept": "application/json, text/html"}
    if cookie:
        headers["Cookie"] = cookie
    try:
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        return response.status, response.read(65536)
    finally:
        connection.close()


def readable(full_name: str, cookie: str | None) -> bool:
    # Gitea serves a repository's branch list only to someone who may read its code: it answers 404 for a
    # private repository, a private or limited owner, or a disabled Code unit, and redirects a renamed one.
    owner, name = (urllib.parse.quote(p, safe="") for p in full_name.split("/", 1))
    return gitea_status(f"/{owner}/{name}/branches/list", cookie)[0] == 200


def repo_dir(full_name: str) -> pathlib.Path:
    owner, name = full_name.split("/", 1)
    path = REPO_ROOT / owner.lower() / f"{name.lower()}.git"
    if not (path / "objects").is_dir():
        raise NotFound(full_name)
    return path


def tip(full_name: str, branch: str) -> str:
    result = subprocess.run(["git", f"--git-dir={repo_dir(full_name)}", "rev-parse", "--verify", "--quiet",
                             f"refs/heads/{branch}^{{commit}}"], capture_output=True, text=True, timeout=20)
    sha = result.stdout.strip()
    if result.returncode != 0 or not SHA.fullmatch(sha):
        raise NotFound(f"{full_name}:{branch}")
    return sha


def cached(key: tuple) -> dict | None:
    with cache_lock:
        if key in cache:
            cache.move_to_end(key)
            return cache[key]
    return None


def count(fork: str, base: str, base_sha: str, sha: str) -> dict:
    key = (base_sha, sha)
    result = cached(key)
    if result is not None:
        return result
    with inflight_lock:  # identical requests wait for the first one instead of counting again
        lock = inflight.setdefault(key, threading.Lock())
    if not lock.acquire(timeout=45):
        raise Busy()
    try:
        result = cached(key)
        if result is not None:
            return result
        if not slots.acquire(timeout=30):
            raise Busy()
        try:
            return _count(fork, base, base_sha, sha, key)
        finally:
            slots.release()
    finally:
        lock.release()
        with inflight_lock:
            if inflight.get(key) is lock and not lock.locked():
                del inflight[key]


def _count(fork: str, base: str, base_sha: str, sha: str, key: tuple) -> dict:
    if len(base_sha) != len(sha):
        return remember(key, {"unrelated": True})  # SHA-1 and SHA-256 repositories share no history
    object_format = "sha256" if len(sha) == 64 else "sha1"
    with tempfile.TemporaryDirectory(prefix="trueog-divergence.") as tmp:
        scratch = pathlib.Path(tmp) / "scratch.git"
        subprocess.run(["git", "init", "-q", "--bare", f"--object-format={object_format}", str(scratch)],
                       check=True, timeout=20)
        (scratch / "objects" / "info" / "alternates").write_text(
            f"{repo_dir(fork)}/objects\n{repo_dir(base)}/objects\n")

        def git(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(["git", f"--git-dir={scratch}", *args], capture_output=True, text=True, timeout=20)

        merge_base = git("merge-base", base_sha, sha)
        if merge_base.returncode == 1 and not merge_base.stdout.strip() and not merge_base.stderr.strip():
            result = {"unrelated": True}  # git merge-base exits 1, silently, when there is no common ancestor
        elif merge_base.returncode != 0:
            raise RuntimeError(f"merge-base: {merge_base.stderr.strip()[:200]}")
        else:
            counts = git("rev-list", "--left-right", "--count", f"{base_sha}...{sha}")
            if counts.returncode != 0:
                raise RuntimeError(counts.stderr.strip()[:200])
            behind, ahead = (int(x) for x in counts.stdout.split())
            result = {"ahead": ahead, "behind": behind}
    return remember(key, result)


def remember(key: tuple, result: dict) -> dict:
    with cache_lock:
        cache[key] = result
        while len(cache) > CACHE_SIZE:
            cache.popitem(last=False)
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = "trueog-divergence"
    timeout = 15  # drop clients that send their request too slowly

    def reply(self, status: int, body: dict) -> None:
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "private, no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-TrueOG-Divergence-Version", VERSION)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        url = urllib.parse.urlsplit(self.path)
        if url.path != ROUTE:
            return self.reply(404, {"error": "not found"})
        query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        fork, branch = query.get("fork", ""), query.get("branch", "")
        base, base_branch = query.get("base", ""), query.get("base_branch", "")
        if not (safe_full_name(fork) and safe_full_name(base) and safe_branch(branch) and safe_branch(base_branch)):
            return self.reply(400, {"error": "bad request"})
        cookie = self.headers.get("Cookie")
        try:
            if not (readable(fork, cookie) and readable(base, cookie)):
                raise NotFound(fork)
            return self.reply(200, count(fork, base, tip(base, base_branch), tip(fork, branch)))
        except NotFound:
            return self.reply(404, {"error": "not found"})
        except Busy:
            return self.reply(503, {"error": "busy"})
        except Exception as error:  # report a failure without taking the service down
            self.log_error("%s %s: %s", fork, branch, str(error)[:200])
            return self.reply(502, {"error": "unavailable"})

    def send_error(self, code, message=None, explain=None) -> None:  # e.g. unsupported methods
        self.reply(code if code >= 400 else 500, {"error": (message or "error").lower()})

    def log_message(self, fmt, *args) -> None:
        pass

    def log_error(self, fmt, *args) -> None:
        super().log_message(fmt, *args)


BUSY_RESPONSE = (b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 17\r\n"
                 b"Cache-Control: private, no-store\r\nRetry-After: 5\r\nConnection: close\r\n"
                 b"X-TrueOG-Divergence-Version: " + VERSION.encode() + b"\r\n\r\n"
                 b'{"error":"busy"}\n')


class Server(ThreadingHTTPServer):
    """One thread per request, but never more than MAX_ACTIVE: the rest are answered 503 at once."""
    daemon_threads = True

    def process_request(self, request, client_address) -> None:
        if not active.acquire(blocking=False):
            try:
                request.settimeout(2)
                request.sendall(BUSY_RESPONSE)
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            active.release()
            raise

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            active.release()


if __name__ == "__main__":
    Server(("127.0.0.1", PORT), Handler).serve_forever()
