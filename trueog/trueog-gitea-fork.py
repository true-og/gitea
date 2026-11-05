#!/usr/bin/env python3
"""Keep the trueog/gitea fork's trueog/ folder in step with the deployed customizations.

https://git.trueog.net/trueog/gitea (main) is Gitea plus TrueOG's commits; its trueog/ folder holds a copy of
the customization files in /home/system/gitea-upgrade, byte-identical to what is deployed (operator,
2026-11-05: future customization changes must also be committed there).

  python3 trueog-gitea-fork.py check            report drift (exit 0 in step, 3 drift, 1 error); changes nothing
  python3 trueog-gitea-fork.py prepare MSGFILE  clone main into trueog-gitea-fork-state/work, copy the drifted
                                                files into trueog/, commit as NotAlexNoyle with MSGFILE's text
                                                (plain message, no trailer); nothing is pushed
  python3 trueog-gitea-fork.py push             push the work clone's HEAD to main as an ordinary fast-forward

Compared: every file in the fork's trueog/ (except its own LICENSE, NOTICE.md and README.md) against the same
path here, plus every file under custom-templates/ and custom-public/ here, which must all be in the fork
except the deliberate exclusions below. New top-level scripts are published only by adding them on purpose
(copy them into work/trueog/ after `prepare` and commit). Fork-only files (README.md, NOTICE.md) are edited in
the work clone the same way; a new override of a Gitea template needs an MIT row in trueog/NOTICE.md.

Between `prepare` and `push`, have Codex review the work clone adversarially (memory
"trueog-gitea-fork-codex-review"). `push` first copies the work clone's HEAD into a fresh temporary bare
repository and checks everything there, with replacement objects disabled: main must still be the commit
`prepare` started from, the new commits must form a linear chain on it (no merges), every one of them may
change only paths under trueog/, must be authored and committed by NotAlexNoyle, and its message must have no
trailers (operator's decision: plain messages). It then pushes from that same repository. Every git command
that talks to a server runs from a fresh temporary bare repository (nothing from the work clone's or any
other configuration file, no repository discovery, hooks disabled, no credential helper, token through
GIT_ASKPASS); it never forces, then waits for the GitHub copy. Do not press "Sync fork" on
trueog/gitea.
"""
from __future__ import annotations

import json
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path("/home/system/gitea-upgrade")
STATE = HERE / "trueog-gitea-fork-state"
WORK = STATE / "work"
BASE_FILE = STATE / "base.json"
FORK = "http://127.0.0.1:3000/trueog/gitea.git"
GITHUB = "https://github.com/true-og/gitea.git"
AUTHOR = ("NotAlexNoyle", "alexnoyle@icloud.com")
FORK_ONLY = {"LICENSE", "NOTICE.md", "README.md"}
EXCLUDED = {
    "custom-public/assets/img/trueog-404.jpg": "third-party picture without a license; not distributed",
}
STERILE = {"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C", "GIT_CEILING_DIRECTORIES": str(HERE),
           "GIT_NO_REPLACE_OBJECTS": "1"}
STERILE_ARGS = ["-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "protocol.allow=never",
                "-c", "protocol.file.allow=always", "-c", "protocol.http.allow=always",
                "-c", "protocol.https.allow=always", "-c", "commit.gpgsign=false"]


def git(*args, cwd, home, extra=None, text=True):
    r = subprocess.run(["git", *STERILE_ARGS, *args], cwd=cwd, capture_output=True, text=text, timeout=900,
                       env={**STERILE, "HOME": str(home), **(extra or {})})
    if r.returncode:
        err = r.stderr if text else r.stderr.decode(errors="replace")
        raise RuntimeError(f"git {' '.join(args[:3])} failed: {err[-300:]}")
    return r.stdout


def heads(url):
    """Branch heads of a remote, asked from a fresh bare repository (no configuration but our own)."""
    with tempfile.TemporaryDirectory(prefix="trueog-gitea-fork-ls-") as tmp:
        repo = pathlib.Path(tmp) / "empty.git"
        git("init", "--quiet", "--bare", str(repo), cwd=tmp, home=tmp)
        out = git("--git-dir", str(repo), "ls-remote", "--heads", url, cwd=tmp, home=tmp)
    return dict(reversed(line.split("\t")) for line in out.splitlines())


def drift(repo: pathlib.Path, rev: str, home):
    """(changed, missing, gone, file count) of rev's trueog/ against the canonical files."""
    listing = git("--git-dir", str(repo), "ls-tree", "-r", "-z", rev, "trueog/", cwd=home, home=home)
    fork = {}
    for entry in filter(None, listing.split("\0")):
        meta, path = entry.split("\t", 1)
        fork[path[len("trueog/"):]] = meta.split()[2]
    changed, gone = [], []
    for rel, blob in sorted(fork.items()):
        if rel in FORK_ONLY:
            continue
        local = HERE / rel
        if not local.is_file():
            gone.append(rel)
        elif git("hash-object", str(local), cwd=home, home=home).strip() != blob:
            changed.append(rel)
    missing = [str(p.relative_to(HERE)) for top in ("custom-templates", "custom-public")
               for p in sorted((HERE / top).rglob("*"))
               if p.is_file() and str(p.relative_to(HERE)) not in fork and str(p.relative_to(HERE)) not in EXCLUDED]
    return changed, missing, gone, len(fork)


def message_problem(message: str) -> str | None:
    """Why a commit message is not plain (trailers, co-authors), parsed in an empty directory with no
    configuration but git's defaults; None if it is plain."""
    with tempfile.TemporaryDirectory(prefix="trueog-gitea-fork-msg-") as tmp:
        r = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "interpret-trailers", "--parse"], input=message.strip() + "\n",
                           capture_output=True, text=True, timeout=60, cwd=tmp,
                           env={**STERILE, "HOME": tmp, "GIT_CEILING_DIRECTORIES": tmp})
    if r.returncode:
        raise RuntimeError(f"git interpret-trailers failed: {r.stderr.strip()[:200]}")
    if not message.strip():
        return "empty message"
    if r.stdout.strip():
        return f"trailers: {r.stdout.strip()[:120]!r}"
    if "co-authored-by" in message.lower():
        return "a co-author line"
    return None


def report(head, changed, missing, gone, count):
    print(f"trueog/gitea main {head[:12]}: {count} files in trueog/")
    for label, items in (("changed here, not yet in the fork", changed), ("new here, not in the fork", missing),
                         ("in the fork, gone here", gone)):
        for rel in items:
            print(f"  {label}: {rel}")
    for rel, why in EXCLUDED.items():
        print(f"  deliberately not in the fork: {rel} ({why})")


def check() -> int:
    with tempfile.TemporaryDirectory(prefix="trueog-gitea-fork-") as tmp:
        work = pathlib.Path(tmp)
        git("init", "--quiet", "--bare", "fork.git", cwd=work, home=work)
        repo = work / "fork.git"
        git("--git-dir", str(repo), "fetch", "--quiet", "--depth", "1", FORK, "+refs/heads/main:refs/heads/main", cwd=work, home=work)
        head = git("--git-dir", str(repo), "rev-parse", "main", cwd=work, home=work).strip()
        changed, missing, gone, count = drift(repo, "main", work)
    report(head, changed, missing, gone, count)
    if changed or missing or gone:
        print(f"FORK_DRIFT files={len(changed) + len(missing) + len(gone)}: run `prepare`, review, `push`")
        return 3
    print("FORK_IN_STEP")
    return 0


def prepare(message_file: str) -> int:
    message = pathlib.Path(message_file).read_text().strip()
    problem = message_problem(message)
    if problem:
        raise RuntimeError(f"the commit message must be plain text without trailers ({problem})")
    STATE.mkdir(mode=0o700, exist_ok=True)
    if WORK.exists():
        shutil.rmtree(WORK)
    git("clone", "--quiet", "--depth", "1", "--branch", "main", FORK, str(WORK), cwd=STATE, home=STATE)
    base = git("rev-parse", "HEAD", cwd=WORK, home=STATE).strip()
    changed, missing, gone, count = drift(WORK / ".git", "HEAD", STATE)
    report(base, changed, missing, gone, count)
    if not (changed or missing or gone):
        print("FORK_IN_STEP: nothing to commit")
        return 0
    for rel in changed + missing:
        target = WORK / "trueog" / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE / rel, target)
    for rel in gone:
        git("rm", "--quiet", f"trueog/{rel}", cwd=WORK, home=STATE)
    if (WORK / "trueog").exists():  # `git rm` above already staged removals
        git("add", "--all", "trueog", cwd=WORK, home=STATE)
    ident = {"GIT_AUTHOR_NAME": AUTHOR[0], "GIT_AUTHOR_EMAIL": AUTHOR[1],
             "GIT_COMMITTER_NAME": AUTHOR[0], "GIT_COMMITTER_EMAIL": AUTHOR[1]}
    git("commit", "--quiet", "-m", message, cwd=WORK, home=STATE, extra=ident)
    BASE_FILE.write_text(json.dumps({"base": base}) + "\n")
    print(git("show", "--stat", "--format=%H %an <%ae>%n%s", "HEAD", cwd=WORK, home=STATE))
    print(f"PREPARED on {base[:12]} in {WORK}; review it, then run `push`")
    return 0


def push() -> int:
    base = json.loads(BASE_FILE.read_text())["base"]
    env_file = HERE / "sso.env"
    if env_file.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise RuntimeError(f"unsafe permissions on {env_file}")
    token = next((line.split("=", 1)[1].strip().strip('"').strip("'") for line in env_file.read_text().splitlines()
                  if line.strip().startswith("GITEA_TOKEN=")), "")
    if not token:
        raise RuntimeError("GITEA_TOKEN is empty")
    with tempfile.TemporaryDirectory(prefix="trueog-gitea-fork-push-") as tmp:
        # Copy the work clone's HEAD into a fresh bare repository; everything below is checked and pushed
        # there, with replacement objects disabled, so nothing in the work clone can change what is checked.
        repo = pathlib.Path(tmp) / "push.git"
        g = lambda *a, extra=None: git("--no-replace-objects", "--git-dir", str(repo), *a, cwd=tmp, home=tmp, extra=extra)
        git("init", "--quiet", "--bare", str(repo), cwd=tmp, home=tmp)
        # The work clone is shallow (its boundary is the base); --update-shallow lets git copy from it. A
        # boundary on any new commit would make that commit parentless here, which the chain check refuses.
        g("fetch", "--quiet", "--no-tags", "--update-shallow", str(WORK), "+HEAD:refs/push/head")
        head = g("rev-parse", "refs/push/head").strip()
        if head == base:
            raise RuntimeError("nothing prepared")
        chain = g("rev-list", "--reverse", "--parents", f"{base}..{head}").splitlines()
        previous, files = base, set()
        for line in chain:
            commit, *parents = line.split()
            if parents != [previous]:
                raise RuntimeError(f"commit {commit[:12]} is not a single-parent child of {previous[:12]} (merge or side history)")
            changed = [p for p in g("diff-tree", "-r", "-z", "--no-commit-id", "--name-only", "--no-renames", commit).split("\0") if p]
            outside = [p for p in changed if not p.startswith("trueog/")]
            if outside:
                raise RuntimeError(f"commit {commit[:12]} changes files outside trueog/: {outside}")
            who = g("log", "-1", "--format=%an%x00%ae%x00%cn%x00%ce", commit).strip().split("\0")
            if who != [AUTHOR[0], AUTHOR[1], AUTHOR[0], AUTHOR[1]]:
                raise RuntimeError(f"commit {commit[:12]} is not authored and committed by {AUTHOR[0]} <{AUTHOR[1]}>: {who}")
            problem = message_problem(g("log", "-1", "--format=%B", commit))
            if problem:
                raise RuntimeError(f"commit {commit[:12]} message is not plain ({problem})")
            files.update(changed)
            previous = commit
        if previous != head or not chain:
            raise RuntimeError("the checked chain does not end at HEAD")
        if heads(FORK) != {"refs/heads/main": base}:
            raise RuntimeError("trueog/gitea main moved since `prepare` (or has other branches); prepare again")
        askpass = pathlib.Path(tmp) / "askpass.sh"
        askpass.write_text('#!/bin/sh\ncase "$1" in Username*) echo NotAlexNoyle ;; *) printf "%s\\n" "$FORK_GITEA_TOKEN" ;; esac\n')
        askpass.chmod(0o700)
        g("push", "--no-verify", FORK, f"{head}:refs/heads/main", extra={"GIT_ASKPASS": str(askpass), "FORK_GITEA_TOKEN": token})
    if heads(FORK) != {"refs/heads/main": head}:
        raise RuntimeError("Gitea main is not the pushed commit")
    deadline = time.monotonic() + 900
    while heads(GITHUB).get("refs/heads/main") != head:
        if time.monotonic() > deadline:
            raise RuntimeError("the GitHub copy did not follow within 15 minutes")
        time.sleep(10)
    print(f"PUSH_OK trueog/gitea main {base[:12]} -> {head[:12]} (fast-forward, {len(chain)} commit(s), "
          f"{len(files)} files under trueog/); GitHub copy matches")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    try:
        if args == ["check"]:
            sys.exit(check())
        if len(args) == 2 and args[0] == "prepare":
            sys.exit(prepare(args[1]))
        if args == ["push"]:
            sys.exit(push())
        raise SystemExit(__doc__)
    except (RuntimeError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError, KeyError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        sys.exit(1)
