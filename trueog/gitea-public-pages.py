#!/usr/bin/env python3
"""Generate credential-free public Gitea pull indexes and contribution choosers.

Only Gitea's anonymous API is queried. The generator fails closed if any repository returned by the
repository search is private/internal or if a pull request refers to a repository outside that
anonymous public set. All displayed fields are HTML-escaped and all writes are atomic. Every page
uses one same-origin helper, loaded from <head> so the navbar stays hidden until it knows the session
state, to reveal signed-in navigation after Gitea validates the current session; the homepage remains
JavaScript-free.

API, OUT_DIR, and APP_URL may be overridden for isolated tests.
"""

from __future__ import annotations

import html
import json
import os
import pathlib
import re
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime
from math import ceil


API = os.environ.get("API", "http://127.0.0.1:3000/api/v1").rstrip("/")
OUT_DIR = pathlib.Path(os.environ.get("OUT_DIR", "/opt/gitea/custom/public/assets/html"))
APP_URL = os.environ.get("APP_URL", "https://git.trueog.net").rstrip("/")
PAGE_SIZE = 50
MAX_PAGES = 100
SAFE_REPO_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
# Owners whose repositories never appear in the wizards or the pull and issue indexes. The `upstream`
# organization holds read-only pull mirrors of the projects TrueOG repositories are forked from; their pull requests and issues are switched off, but they are excluded here
# by owner so turning a unit on can never list them. They stay in the public set used for validation.
EXCLUDED_OWNERS = frozenset({"upstream"})
PULL_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25m5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354M3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5m0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5m8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0"/></svg>'
BUG_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.72.22a.75.75 0 0 1 1.06 0l1 .999a3.5 3.5 0 0 1 2.441 0l.999-1a.748.748 0 0 1 1.265.332.75.75 0 0 1-.205.729l-.775.776c.616.63.995 1.493.995 2.444v.327q0 .15-.025.292c.408.14.764.392 1.029.722l1.968-.787a.75.75 0 0 1 .556 1.392L13 7.258V9h2.25a.75.75 0 0 1 0 1.5H13v.5q-.002.615-.141 1.186l2.17.868a.75.75 0 0 1-.557 1.392l-2.184-.873A5 5 0 0 1 8 16a5 5 0 0 1-4.288-2.427l-2.183.873a.75.75 0 0 1-.558-1.392l2.17-.868A5 5 0 0 1 3 11v-.5H.75a.75.75 0 0 1 0-1.5H3V7.258L.971 6.446a.75.75 0 0 1 .558-1.392l1.967.787c.265-.33.62-.583 1.03-.722a1.7 1.7 0 0 1-.026-.292V4.5c0-.951.38-1.814.995-2.444L4.72 1.28a.75.75 0 0 1 0-1.06m.53 6.28a.75.75 0 0 0-.75.75V11a3.5 3.5 0 1 0 7 0V7.25a.75.75 0 0 0-.75-.75ZM6.173 5h3.654A.17.17 0 0 0 10 4.827V4.5a2 2 0 1 0-4 0v.327c0 .096.077.173.173.173"/></svg>'
CHECK_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 .018-1.042.75.75 0 0 1 1.042-.018L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0"/></svg>'
FORK_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M5 5.372v.878c0 .414.336.75.75.75h4.5a.75.75 0 0 0 .75-.75v-.878a2.25 2.25 0 1 1 1.5 0v.878a2.25 2.25 0 0 1-2.25 2.25h-1.5v2.128a2.251 2.251 0 1 1-1.5 0V8.5h-1.5A2.25 2.25 0 0 1 3.5 6.25v-.878a2.25 2.25 0 1 1 1.5 0M5 3.25a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0m6.75.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5m-3 8.75a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0"/></svg>'
# Gitea 28.2.0's own octicon paths for the navbar, copied from its rendered navbar so both bars
# draw identical glyphs.
OCTICON_PATHS = {
    "bell": "M8 16a2 2 0 0 0 1.985-1.75c.017-.137-.097-.25-.235-.25h-3.5c-.138 0-.252.113-.235.25A2 2 0 0 0 8 16M3 5a5 5 0 0 1 10 0v2.947q0 .076.042.139l1.703 2.555A1.519 1.519 0 0 1 13.482 13H2.518a1.516 1.516 0 0 1-1.263-2.36l1.703-2.554A.26.26 0 0 0 3 7.947Zm5-3.5A3.5 3.5 0 0 0 4.5 5v2.947c0 .346-.102.683-.294.97l-1.703 2.556-.003.01.001.006q0 .003.004.006l.006.004.007.001h10.964l.007-.001.006-.004.004-.006.001-.007-.003-.01-1.703-2.554a1.75 1.75 0 0 1-.294-.97V5A3.5 3.5 0 0 0 8 1.5",
    "three-bars": "M1 2.75A.75.75 0 0 1 1.75 2h12.5a.75.75 0 0 1 0 1.5H1.75A.75.75 0 0 1 1 2.75m0 5A.75.75 0 0 1 1.75 7h12.5a.75.75 0 0 1 0 1.5H1.75A.75.75 0 0 1 1 7.75M1.75 12h12.5a.75.75 0 0 1 0 1.5H1.75a.75.75 0 0 1 0-1.5",
    "sign-in": "M2 2.75C2 1.784 2.784 1 3.75 1h2.5a.75.75 0 0 1 0 1.5h-2.5a.25.25 0 0 0-.25.25v10.5c0 .138.112.25.25.25h2.5a.75.75 0 0 1 0 1.5h-2.5A1.75 1.75 0 0 1 2 13.25Zm6.56 4.5h5.69a.75.75 0 0 1 0 1.5H8.56l1.97 1.97a.749.749 0 0 1-.326 1.275.75.75 0 0 1-.734-.215L6.22 8.53a.75.75 0 0 1 0-1.06l3.25-3.25a.749.749 0 0 1 1.275.326.75.75 0 0 1-.215.734Z",
    "plus": "M7.75 2a.75.75 0 0 1 .75.75V7h4.25a.75.75 0 0 1 0 1.5H8.5v4.25a.75.75 0 0 1-1.5 0V8.5H2.75a.75.75 0 0 1 0-1.5H7V2.75A.75.75 0 0 1 7.75 2",
    "triangle-down": "m4.427 7.427 3.396 3.396a.25.25 0 0 0 .354 0l3.396-3.396A.25.25 0 0 0 11.396 7H4.604a.25.25 0 0 0-.177.427",
    "repo-push": "M2 2.5A2.5 2.5 0 0 1 4.5 0h8.75a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0V1.5h-8a1 1 0 0 0-1 1v6.708A2.5 2.5 0 0 1 4.5 9h2.25a.75.75 0 0 1 0 1.5H4.5a1 1 0 0 0 0 2h4.75a.75.75 0 0 1 0 1.5H4.5A2.5 2.5 0 0 1 2 11.5Zm12.23 7.79zl-1.224-1.224v6.184a.75.75 0 0 1-1.5 0V9.066L10.28 10.29a.75.75 0 0 1-1.06-1.061l2.505-2.504a.75.75 0 0 1 1.06 0L15.29 9.23a.75.75 0 0 1-.018 1.042.75.75 0 0 1-1.042.018",
    "organization": "M1.75 16A1.75 1.75 0 0 1 0 14.25V1.75C0 .784.784 0 1.75 0h8.5C11.216 0 12 .784 12 1.75v12.5q0 .127-.018.25h2.268a.25.25 0 0 0 .25-.25V8.285a.25.25 0 0 0-.111-.208l-1.055-.703a.749.749 0 1 1 .832-1.248l1.055.703c.487.325.779.871.779 1.456v5.965A1.75 1.75 0 0 1 14.25 16h-3.5a.8.8 0 0 1-.197-.026q-.148.026-.303.026h-3a.75.75 0 0 1-.75-.75V14h-1v1.25a.75.75 0 0 1-.75.75Zm-.25-1.75c0 .138.112.25.25.25H4v-1.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 .75.75v1.25h2.25a.25.25 0 0 0 .25-.25V1.75a.25.25 0 0 0-.25-.25h-8.5a.25.25 0 0 0-.25.25ZM3.75 6h.5a.75.75 0 0 1 0 1.5h-.5a.75.75 0 0 1 0-1.5M3 3.75A.75.75 0 0 1 3.75 3h.5a.75.75 0 0 1 0 1.5h-.5A.75.75 0 0 1 3 3.75m4 3A.75.75 0 0 1 7.75 6h.5a.75.75 0 0 1 0 1.5h-.5A.75.75 0 0 1 7 6.75M7.75 3h.5a.75.75 0 0 1 0 1.5h-.5a.75.75 0 0 1 0-1.5M3 9.75A.75.75 0 0 1 3.75 9h.5a.75.75 0 0 1 0 1.5h-.5A.75.75 0 0 1 3 9.75M7.75 9h.5a.75.75 0 0 1 0 1.5h-.5a.75.75 0 0 1 0-1.5",
    "person": "M10.561 8.073a6 6 0 0 1 3.432 5.142.75.75 0 1 1-1.498.07 4.5 4.5 0 0 0-8.99 0 .75.75 0 0 1-1.498-.07 6 6 0 0 1 3.431-5.142 3.999 3.999 0 1 1 5.123 0M10.5 5a2.5 2.5 0 1 0-5 0 2.5 2.5 0 0 0 5 0",
    "shield-check": "m8.533.133 5.25 1.68A1.75 1.75 0 0 1 15 3.48V7c0 1.566-.32 3.182-1.303 4.682-.983 1.498-2.585 2.813-5.032 3.855a1.7 1.7 0 0 1-1.33 0c-2.447-1.042-4.049-2.357-5.032-3.855C1.32 10.182 1 8.566 1 7V3.48a1.75 1.75 0 0 1 1.217-1.667l5.25-1.68a1.75 1.75 0 0 1 1.066 0m-.61 1.429zl-5.25 1.68a.25.25 0 0 0-.174.237V7c0 1.36.275 2.666 1.057 3.859.784 1.194 2.121 2.342 4.366 3.298a.2.2 0 0 0 .154 0c2.245-.957 3.582-2.103 4.366-3.297C13.225 9.666 13.5 8.358 13.5 7V3.48a.25.25 0 0 0-.174-.238l-5.25-1.68a.25.25 0 0 0-.153 0M11.28 6.28l-3.5 3.5a.75.75 0 0 1-1.06 0l-1.5-1.5a.749.749 0 0 1 .326-1.275.75.75 0 0 1 .734.215l.97.97 2.97-2.97a.75.75 0 0 1 1.042.018.75.75 0 0 1 .018 1.042",
    "star": "M8 .25a.75.75 0 0 1 .673.418l1.882 3.815 4.21.612a.75.75 0 0 1 .416 1.279l-3.046 2.97.719 4.192a.751.751 0 0 1-1.088.791L8 12.347l-3.766 1.98a.75.75 0 0 1-1.088-.79l.72-4.194L.818 6.374a.75.75 0 0 1 .416-1.28l4.21-.611L7.327.668A.75.75 0 0 1 8 .25m0 2.445L6.615 5.5a.75.75 0 0 1-.564.41l-3.097.45 2.24 2.184a.75.75 0 0 1 .216.664l-.528 3.084 2.769-1.456a.75.75 0 0 1 .698 0l2.77 1.456-.53-3.084a.75.75 0 0 1 .216-.664l2.24-2.183-3.096-.45a.75.75 0 0 1-.564-.41z",
    "tools": "M5.433 2.304A4.49 4.49 0 0 0 3.5 6c0 1.598.832 3.002 2.09 3.802.518.328.929.923.902 1.64v.008l-.164 3.337a.75.75 0 1 1-1.498-.073l.163-3.33c.002-.085-.05-.216-.207-.316A6 6 0 0 1 2 6a6 6 0 0 1 2.567-4.92 1.48 1.48 0 0 1 1.673-.04c.462.296.76.827.76 1.423v2.82c0 .082.041.16.11.206l.75.51a.25.25 0 0 0 .28 0l.75-.51A.25.25 0 0 0 9 5.282V2.463c0-.596.298-1.127.76-1.423a1.48 1.48 0 0 1 1.673.04A6 6 0 0 1 14 6a6 6 0 0 1-2.786 5.068c-.157.1-.209.23-.207.315l.163 3.33a.752.752 0 0 1-1.094.714.75.75 0 0 1-.404-.64l-.164-3.345c-.027-.717.384-1.312.902-1.64A4.5 4.5 0 0 0 12.5 6a4.49 4.49 0 0 0-1.933-3.696c-.024.017-.067.067-.067.16v2.818a1.75 1.75 0 0 1-.767 1.448l-.75.51a1.75 1.75 0 0 1-1.966 0l-.75-.51A1.75 1.75 0 0 1 5.5 5.282V2.463c0-.092-.043-.142-.067-.159",
    "question": "M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8m8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13M6.92 6.085h.001a.749.749 0 1 1-1.342-.67c.169-.339.436-.701.849-.977C6.845 4.16 7.369 4 8 4a2.76 2.76 0 0 1 1.637.525c.503.377.863.965.863 1.725 0 .448-.115.83-.329 1.15-.205.307-.47.513-.692.662-.109.072-.22.138-.313.195l-.006.004a6 6 0 0 0-.26.16 1 1 0 0 0-.276.245.75.75 0 0 1-1.248-.832c.184-.264.42-.489.692-.661q.154-.1.313-.195l.007-.004c.1-.061.182-.11.258-.161a1 1 0 0 0 .277-.245C8.96 6.514 9 6.427 9 6.25a.61.61 0 0 0-.262-.525A1.27 1.27 0 0 0 8 5.5c-.369 0-.595.09-.74.187a1 1 0 0 0-.34.398M9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0",
    "server": "M1.75 1h12.5c.966 0 1.75.784 1.75 1.75v4c0 .372-.116.717-.314 1 .198.283.314.628.314 1v4a1.75 1.75 0 0 1-1.75 1.75H1.75A1.75 1.75 0 0 1 0 12.75v-4c0-.358.109-.707.314-1a1.74 1.74 0 0 1-.314-1v-4C0 1.784.784 1 1.75 1M1.5 2.75v4c0 .138.112.25.25.25h12.5a.25.25 0 0 0 .25-.25v-4a.25.25 0 0 0-.25-.25H1.75a.25.25 0 0 0-.25.25m.25 5.75a.25.25 0 0 0-.25.25v4c0 .138.112.25.25.25h12.5a.25.25 0 0 0 .25-.25v-4a.25.25 0 0 0-.25-.25ZM7 4.75A.75.75 0 0 1 7.75 4h4.5a.75.75 0 0 1 0 1.5h-4.5A.75.75 0 0 1 7 4.75M7.75 10h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5M3 4.75A.75.75 0 0 1 3.75 4h.5a.75.75 0 0 1 0 1.5h-.5A.75.75 0 0 1 3 4.75M3.75 10h.5a.75.75 0 0 1 0 1.5h-.5a.75.75 0 0 1 0-1.5",
    "sign-out": "M2 2.75C2 1.784 2.784 1 3.75 1h2.5a.75.75 0 0 1 0 1.5h-2.5a.25.25 0 0 0-.25.25v10.5c0 .138.112.25.25.25h2.5a.75.75 0 0 1 0 1.5h-2.5A1.75 1.75 0 0 1 2 13.25Zm10.44 4.5-1.97-1.97a.749.749 0 0 1 .326-1.275.75.75 0 0 1 .734.215l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.749.749 0 0 1-1.275-.326.75.75 0 0 1 .215-.734l1.97-1.97H6.75a.75.75 0 0 1 0-1.5Z",
}


def octicon(name: str, class_name: str = "", extra: str = "") -> str:
    class_attr = f' class="{class_name}"' if class_name else ""
    return f'<svg{class_attr} viewBox="0 0 16 16" aria-hidden="true"{extra}><path d="{OCTICON_PATHS[name]}"/></svg>'


# The navbar mirrors Gitea's own (templates/base/head_navbar.tmpl with TrueOG's custom/extra_links.tmpl):
# the same items, labels, menus, and icons. trueog-public.js reveals the signed-in items once Gitea's
# rendered navbar confirms the session; the mobile group and its toggle mirror Gitea's phone layout.
BELL = (
    f'<span class="trueog-public-icon-box">{octicon("bell")}'
    '<span class="trueog-public-count" data-public-notification-count hidden></span></span>'
)
TRIANGLE = f'<span class="trueog-public-not-mobile">{octicon("triangle-down")}</span>'
NAVBAR = f"""<nav class="trueog-public-nav" aria-label="Navigation Bar">
    <div class="trueog-public-nav-left">
      <div class="trueog-public-nav-mobile">
        <a class="trueog-public-nav-icon" href="/notifications" data-public-auth hidden aria-label="Notifications" title="Notifications">{BELL}</a>
        <button class="trueog-public-nav-toggle" type="button" aria-label="Navigation Menu" aria-expanded="false" data-public-nav-toggle>{octicon("three-bars")}</button>
      </div>
      <a href="/" aria-label="Home" data-public-home><span class="trueog-public-home-lambda" aria-hidden="true">λ</span></a>
      <a href="/" data-public-auth hidden>Dashboard</a>
      <a href="/issues" data-public-auth hidden>Issues</a>
      <a href="/pulls" data-public-auth hidden>Pull Requests</a>
      <a href="/milestones" data-public-auth hidden>Milestones</a>
      <a href="/explore/repos">Explore</a>
      <a target="_blank" href="https://docs.gitea.com" data-public-guest>Help</a>
    </div>
    <div class="trueog-public-nav-right">
      <a rel="nofollow" href="/user/login" data-public-guest>{octicon("sign-in")}<span>Sign In</span></a>
      <a class="trueog-public-nav-icon trueog-public-not-mobile" href="/notifications" data-public-auth hidden aria-label="Notifications" title="Notifications">{BELL}</a>
      <details class="trueog-public-menu" data-public-auth hidden>
        <summary aria-label="Create…" title="Create…"><span class="trueog-public-menu-label">{octicon("plus")}<span class="trueog-public-only-mobile">Create…</span>{TRIANGLE}</span></summary>
        <div class="trueog-public-menu-panel">
          <a href="/repo/create">{octicon("plus")}New Repository</a>
          <a href="/repo/migrate" data-public-native-href="/repo/migrate">{octicon("repo-push")}New Migration</a>
          <a href="/org/create" data-public-native-href="/org/create">{octicon("organization")}New Organization</a>
        </div>
      </details>
      <details class="trueog-public-menu trueog-public-profile-menu" data-public-auth hidden>
        <summary aria-label="Profile and Settings…" title="Profile and Settings…"><span class="trueog-public-menu-label"><span class="trueog-public-avatar"><img data-public-avatar hidden alt="" width="24" height="24">{octicon("person", "trueog-public-avatar-fallback", " data-public-avatar-fallback")}{octicon("shield-check", "trueog-public-admin-badge", " data-public-admin hidden")}</span><span class="trueog-public-only-mobile" data-public-username>Profile</span>{TRIANGLE}</span></summary>
        <div class="trueog-public-menu-panel">
          <div class="trueog-public-menu-header">Signed in as <strong data-public-username>Profile</strong></div>
          <div class="trueog-public-menu-divider"></div>
          <a href="/" data-public-profile>{octicon("person")}Profile</a>
          <a href="/" data-public-starred data-public-native-href="?tab=stars">{octicon("star")}Starred</a>
          <a href="/notifications/subscriptions">{octicon("bell")}Subscriptions</a>
          <a href="/user/settings">{octicon("tools")}Settings</a>
          <a target="_blank" href="https://docs.gitea.com">{octicon("question")}Help</a>
          <div class="trueog-public-menu-divider" data-public-admin hidden></div>
          <a href="/-/admin" data-public-admin hidden>{octicon("server")}Site Administration</a>
          <div class="trueog-public-menu-divider"></div>
          <a href="/user/logout">{octicon("sign-out")}Sign Out</a>
        </div>
      </details>
    </div>
  </nav>"""


def api_json(path: str) -> object:
    request = urllib.request.Request(
        f"{API}/{path.lstrip('/')}",
        headers={"Accept": "application/json", "User-Agent": "TrueOG-public-pages/1"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        if response.status != 200:
            raise RuntimeError(f"anonymous API returned HTTP {response.status} for {path}")
        return json.load(response)


def paged(path: str, wrapper: str | None = None) -> list[dict]:
    items: list[dict] = []
    separator = "&" if "?" in path else "?"
    for page in range(1, MAX_PAGES + 1):
        payload = api_json(f"{path}{separator}limit={PAGE_SIZE}&page={page}")
        if wrapper:
            if not isinstance(payload, dict) or not isinstance(payload.get(wrapper), list):
                raise RuntimeError(f"unexpected anonymous API wrapper for {path}")
            batch = payload[wrapper]
        else:
            if not isinstance(payload, list):
                raise RuntimeError(f"unexpected anonymous API list for {path}")
            batch = payload
        if not all(isinstance(item, dict) for item in batch):
            raise RuntimeError(f"unexpected anonymous API item for {path}")
        items.extend(batch)
        if len(batch) < PAGE_SIZE:
            return items
    raise RuntimeError(f"anonymous API pagination exceeded {MAX_PAGES} pages for {path}")


def text(value: object) -> str:
    return html.escape(str(value or ""), quote=True)


def url_segment(value: object) -> str:
    return urllib.parse.quote(str(value), safe="")


def canonical_repo_path(full_name: str) -> str:
    owner, repo = full_name.split("/", 1)
    return f"/{url_segment(owner)}/{url_segment(repo)}"


def short_date(value: object) -> str:
    raw = str(value or "")
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).strftime("%Y-%m-%d")
    except ValueError:
        return "unknown date"


def layout(
    title: str,
    heading: str,
    intro: str,
    body: str,
    heading_icon: str = "",
) -> str:
    heading_content = (
        f'<span class="trueog-public-heading-icon">{heading_icon}</span><span>{text(heading)}</span>'
        if heading_icon
        else text(heading)
    )
    return f"""<!doctype html>
<html lang="en-US">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'">
  <meta name="referrer" content="same-origin">
  <title>{text(title)} - TrueOG Gitea</title>
  <link rel="icon" href="/assets/img/favicon.png?v=1" sizes="32x32" type="image/png">
  <link rel="shortcut icon" href="/assets/img/favicon.ico?v=1" type="image/x-icon">
  <link rel="apple-touch-icon" href="/assets/img/apple-touch-icon.png?v=1" sizes="180x180">
  <link rel="stylesheet" href="/assets/css/trueog-public.css?v=14">
  <script src="/assets/scripts/trueog-public.js?v=7"></script>
</head>
<body>
  {NAVBAR}
  <main>
    <header class="trueog-public-heading">
      <h1>{heading_content}</h1>
      <p>{text(intro)}</p>
    </header>
    {body}
  </main>
  <footer class="trueog-public-footer">
    <a class="trueog-public-footer-left" href="https://about.gitea.com/">Powered by Gitea</a>
    <span class="trueog-public-motto" lang="la">ad astra per aspera</span>
    <a class="trueog-public-footer-right" href="/">TrueOG Gitea</a>
  </footer>
</body>
</html>
"""


# The generated list kinds: pull requests and issues share every function below, so both indexes have the
# same features; the pull pages keep their historical markup and filenames.
LIST_KINDS = {
    "pulls": {
        "path": "/pulls",
        "prefix": "trueog-pulls-",
        "api_type": "pulls",
        "item_path": "pulls",
        "item_noun": "pull request",
        "plural": "pull requests",
        "list_label": "Pull requests",
        "state_label": "Pull request state",
        "titles": {"all": "All pull requests", "open": "Open pull requests", "closed": "Closed pull requests"},
    },
    "issues": {
        "path": "/issues",
        "prefix": "trueog-issues-",
        "api_type": "issues",
        "item_path": "issues",
        "item_noun": "issue",
        "plural": "issues",
        "list_label": "Issues",
        "state_label": "Issue state",
        "titles": {"all": "All issues", "open": "Open issues", "closed": "Closed issues"},
    },
}


def pulls_url(state: str, page: int = 1, hide_personal: bool = False, kind: str = "pulls") -> str:
    """Return an HTML-attribute-ready public index URL; Nginx maps it to a generated file."""
    url = f"{LIST_KINDS[kind]['path']}?state={state}"
    if page > 1:
        url += f"&amp;page={page}"
    if hide_personal:
        url += "&amp;personal=hide"
    return url


def pull_tabs(active: str, counts: dict[str, int], hide_personal: bool = False, kind: str = "pulls") -> str:
    links = []
    for state, label in (("all", "All"), ("open", "Open"), ("closed", "Closed")):
        current = ' aria-current="page"' if state == active else ""
        links.append(
            f'<a href="{pulls_url(state, hide_personal=hide_personal, kind=kind)}"{current}>{label} ({counts[state]})</a>'
        )
    return (f'<nav class="trueog-public-tabs" aria-label="{LIST_KINDS[kind]["state_label"]}">'
            + "".join(links) + "</nav>")


def personal_filter(state: str, hide_personal: bool, kind: str = "pulls") -> str:
    """A server-rendered checkbox: following it opens the other generated variant of this view.

    It is a link rather than a form control so it needs no JavaScript and stays correct across tabs,
    pagination, and browser Back navigation; toggling returns to page 1 of the other variant.
    """
    checked = "true" if hide_personal else "false"
    target = pulls_url(state, hide_personal=not hide_personal, kind=kind)
    return (
        '<div class="trueog-public-filters">'
        f'<a class="trueog-public-filter" role="checkbox" aria-checked="{checked}" href="{target}" '
        'title="Personal repositories are owned by an individual account rather than an organization.">'
        f'<span class="trueog-public-filter-box" aria-hidden="true">{CHECK_ICON}</span>'
        "<span>Hide personal repositories</span></a></div>"
    )


def pull_card(item: dict, kind: str = "pulls") -> str:
    repo = item.get("repository") or {}
    user = item.get("user") or {}
    full_name = str(repo.get("full_name") or "")
    repo_path = canonical_repo_path(full_name)
    number = int(item.get("number") or 0)
    state = str(item.get("state") or "")
    pull_data = item.get("pull_request") or {}
    if state == "open":
        status = "Open"
    elif kind == "pulls" and pull_data.get("merged"):
        status = "Merged"
    else:
        status = "Closed"
    login = str(user.get("login") or "unknown")
    comments = int(item.get("comments") or 0)
    item_path = LIST_KINDS[kind]["item_path"]
    return f"""<article class="trueog-public-card">
  <h2><a href="{repo_path}/{item_path}/{number}">#{number} {text(item.get('title'))}</a></h2>
  <p class="trueog-public-meta"><a href="{repo_path}">{text(full_name)}</a> · {text(status)} · updated {text(short_date(item.get('updated_at')))} by <a href="/{url_segment(login)}">{text(login)}</a> · {comments} comments</p>
</article>"""


def pull_pagination(page: int, total_pages: int, hide_personal: bool = False, kind: str = "pulls") -> str:
    if total_pages <= 1:
        return ""

    def page_url(number: int) -> str:
        return pulls_url("all", number, hide_personal, kind)

    links: list[str] = []
    if page > 1:
        links.append(f'<a rel="prev" href="{page_url(page - 1)}">Previous</a>')
    for number in range(1, total_pages + 1):
        current = ' aria-current="page"' if number == page else ""
        links.append(f'<a href="{page_url(number)}"{current}>{number}</a>')
    if page < total_pages:
        links.append(f'<a rel="next" href="{page_url(page + 1)}">Next</a>')
    return (
        f'<nav class="trueog-public-pagination" aria-label="{LIST_KINDS[kind]["titles"]["all"]} pages">'
        + "".join(links)
        + "</nav>"
    )


def pulls_page(
    state: str,
    items: list[dict],
    counts: dict[str, int],
    page: int = 1,
    total_pages: int = 1,
    hide_personal: bool = False,
    kind: str = "pulls",
) -> str:
    spec = LIST_KINDS[kind]
    cards = "\n".join(pull_card(item, kind) for item in items)
    if not cards:
        cards = f'<p class="trueog-public-empty">No {spec["plural"]} match this view.</p>'
    pagination = pull_pagination(page, total_pages, hide_personal, kind) if state == "all" else ""
    body = (
        pull_tabs(state, counts, hide_personal, kind)
        + personal_filter(state, hide_personal, kind)
        + f'<section class="trueog-public-list" aria-label="{spec["list_label"]}">{cards}</section>'
        + pagination
    )
    label = spec["titles"][state]
    return layout(
        label,
        label,
        f"This public index contains only {spec['plural']} from repositories visible to Gitea's anonymous API.",
        body,
    )


def repo_option(repo: dict) -> str:
    full_name = str(repo["full_name"])
    repo_path = canonical_repo_path(full_name)
    return f'<option value="{text(repo_path)}">{text(full_name)}</option>'


def wizard_page(kind: str, repos: list[dict]) -> str:
    if kind == "pull":
        title = "Pull request / fork"
        intro = "Choose any public repository, then open its Pull Requests tab or fork it into your account."
        select_id = "pull-repository"
        heading_icon = PULL_ICON
        actions = f"""<div class="trueog-public-form-actions">
      <button class="trueog-public-submit" type="submit" data-target-suffix="/pulls">{PULL_ICON}<span>Open pull request</span></button>
      <button class="trueog-public-submit" type="submit" data-target-suffix="/fork">{FORK_ICON}<span>Fork repository</span></button>
    </div>"""
        extra_note = ""
    else:
        title = "File bug report"
        intro = "Choose any public repository with issues enabled. Gitea will open its native issue-template flow; signing in is required before submission."
        select_id = "bug-repository"
        heading_icon = BUG_ICON
        actions = f'<button class="trueog-public-submit" type="submit" data-target-suffix="/issues/new/choose">{BUG_ICON}<span>File bug report</span></button>'
        extra_note = '<p class="trueog-public-not-sure"><strong>Not sure?</strong> Report it in <a href="https://discord.gg/ma9pMYpBU6">#bug-reports on Discord</a>.</p>'
    options = "\n".join(repo_option(repo) for repo in repos)
    body = f"""<section class="trueog-public-form-wrap" aria-label="Repository chooser">
  <form class="trueog-public-form" data-contribution-form method="get">
    <label for="{select_id}">Repository</label>
    <select id="{select_id}" name="target" required>
      <option value="" selected disabled>Choose repository</option>
      {options}
    </select>
    {actions}
    <p class="trueog-public-form-note">Only repositories visible to an anonymous Gitea visitor are listed.</p>
    {extra_note}
  </form>
  <noscript><p class="trueog-public-noscript">This repository chooser requires JavaScript. The Gitea homepage remains JavaScript-free.</p></noscript>
</section>"""
    return layout(title, title, intro, body, heading_icon=heading_icon)


def atomic_write(name: str, content: str) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    temporary: pathlib.Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=OUT_DIR, prefix=f".{name}.", delete=False
        ) as handle:
            temporary = pathlib.Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, OUT_DIR / name)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main() -> None:
    repos = paged("repos/search?sort=alpha&order=asc", "data")
    if not repos:
        raise RuntimeError("anonymous repository search returned no repositories")

    public_repos: dict[str, dict] = {}
    for repo in repos:
        full_name = str(repo.get("full_name") or "")
        if not SAFE_REPO_NAME.fullmatch(full_name):
            raise RuntimeError(f"unsafe repository name from anonymous API: {full_name!r}")
        if repo.get("private") or repo.get("internal"):
            raise RuntimeError(f"non-public repository returned by anonymous API: {full_name}")
        public_repos[full_name] = repo

    def listed(full_name: str) -> bool:
        return full_name.split("/", 1)[0].lower() not in EXCLUDED_OWNERS

    # A personal repository is one whose owner is not an organization. Anything Gitea does not
    # explicitly mark as an organization counts as personal, so the filtered view errs toward hiding.
    def is_personal(item: dict) -> bool:
        full_name = str((item.get("repository") or {}).get("full_name") or "")
        owner = public_repos[full_name].get("owner") or {}
        return owner.get("type") != "Organization"

    active_repos = [
        repo for repo in public_repos.values()
        if not repo.get("archived") and listed(str(repo["full_name"]))
    ]
    pull_repos = sorted(
        (repo for repo in active_repos if repo.get("has_pull_requests")),
        key=lambda repo: str(repo["full_name"]).casefold(),
    )
    issue_repos = sorted(
        (repo for repo in active_repos if repo.get("has_issues")),
        key=lambda repo: str(repo["full_name"]).casefold(),
    )
    if not pull_repos or not issue_repos:
        raise RuntimeError("anonymous API returned no eligible contribution repositories")

    pages = {
        "trueog-pull-wizard.html": wizard_page("pull", pull_repos),
        "trueog-bug-wizard.html": wizard_page("bug", issue_repos),
    }
    summary: dict[str, dict] = {}
    for kind, spec in LIST_KINDS.items():
        open_items = paged(f"repos/issues/search?type={spec['api_type']}&state=open")
        closed_items = paged(f"repos/issues/search?type={spec['api_type']}&state=closed")
        for item in open_items + closed_items:
            repository = item.get("repository") or {}
            full_name = str(repository.get("full_name") or "")
            if full_name not in public_repos:
                raise RuntimeError(f"{spec['item_noun']} refers to a non-public repository: {full_name!r}")

        open_items = [i for i in open_items if listed(str((i.get("repository") or {}).get("full_name") or ""))]
        closed_items = [i for i in closed_items if listed(str((i.get("repository") or {}).get("full_name") or ""))]
        open_items.sort(key=lambda item: str(item.get("updated_at") or ""), reverse=True)
        closed_items.sort(key=lambda item: str(item.get("updated_at") or ""), reverse=True)
        all_items = sorted(
            open_items + closed_items,
            key=lambda item: str(item.get("updated_at") or ""),
            reverse=True,
        )
        views = {
            False: {"all": all_items, "open": open_items, "closed": closed_items},
            True: {
                state: [item for item in items if not is_personal(item)]
                for state, items in (("all", all_items), ("open", open_items), ("closed", closed_items))
            },
        }
        # Each view exists twice: the complete index under its historical filenames, and the "Hide
        # personal repositories" variant under an -org- prefix. Nginx selects the variant from
        # personal=hide; each variant's tabs and pagination stay within it.
        all_page_counts: dict[bool, int] = {}
        for hide_personal, view in views.items():
            prefix = spec["prefix"] + ("org-" if hide_personal else "")
            view_counts = {state: len(items) for state, items in view.items()}
            pages[f"{prefix}open.html"] = pulls_page(
                "open", view["open"], view_counts, hide_personal=hide_personal, kind=kind
            )
            pages[f"{prefix}closed.html"] = pulls_page(
                "closed", view["closed"], view_counts, hide_personal=hide_personal, kind=kind
            )
            all_page_count = max(1, ceil(len(view["all"]) / PAGE_SIZE))
            if all_page_count > MAX_PAGES:
                raise RuntimeError(f"all-{kind} view exceeds the {MAX_PAGES} pages Nginx serves")
            all_page_counts[hide_personal] = all_page_count
            for page_number in range(1, all_page_count + 1):
                start = (page_number - 1) * PAGE_SIZE
                name = f"{prefix}all.html" if page_number == 1 else f"{prefix}all-page-{page_number}.html"
                pages[name] = pulls_page(
                    "all",
                    view["all"][start : start + PAGE_SIZE],
                    view_counts,
                    page=page_number,
                    total_pages=all_page_count,
                    hide_personal=hide_personal,
                    kind=kind,
                )
        summary[kind] = {
            "counts": {state: len(items) for state, items in views[False].items()},
            "org_counts": {state: len(items) for state, items in views[True].items()},
            "all_pages": all_page_counts,
        }
    for name, page in pages.items():
        if page.lower().count("<script") != 1:
            raise RuntimeError(f"generated page has an unexpected script count: {name}")
        if '<script src="/assets/scripts/trueog-public.js?v=7"></script>\n</head>' not in page:
            raise RuntimeError(f"generated page lacks the signed-in navigation helper: {name}")
    for name, page in pages.items():
        atomic_write(name, page)

    # Remove only stale numbered all-item pages from earlier runs. Page 1 keeps its historical
    # filename, and the narrow fullmatch prevents this cleanup from touching any other asset.
    numbered_page = re.compile(r"^trueog-(?:pulls|issues)-(?:org-)?all-page-[0-9]+\.html$")
    expected_names = set(pages)
    for pattern in ("trueog-pulls-*all-page-*.html", "trueog-issues-*all-page-*.html"):
        for candidate in OUT_DIR.glob(pattern):
            if numbered_page.fullmatch(candidate.name) and candidate.name not in expected_names:
                candidate.unlink()

    pulls, issues = summary["pulls"], summary["issues"]
    print(
        "gitea-public-pages: "
        f"repos={len(public_repos)} pull_repos={len(pull_repos)} issue_repos={len(issue_repos)} "
        f"pulls={pulls['counts']['all']} open={pulls['counts']['open']} closed={pulls['counts']['closed']} "
        f"all_pages={pulls['all_pages'][False]} "
        f"org_pulls={pulls['org_counts']['all']} org_open={pulls['org_counts']['open']} "
        f"org_closed={pulls['org_counts']['closed']} org_all_pages={pulls['all_pages'][True]} "
        f"issues={issues['counts']['all']} issues_open={issues['counts']['open']} "
        f"issues_closed={issues['counts']['closed']} issues_all_pages={issues['all_pages'][False]} "
        f"org_issues={issues['org_counts']['all']} org_issues_all_pages={issues['all_pages'][True]}"
    )


if __name__ == "__main__":
    main()
