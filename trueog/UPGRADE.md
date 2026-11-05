# TrueOG Gitea upgrade runbook

This deployment is permanently **Dockerless**. Gitea runs as a native Linux binary under OpenRC
using `/etc/init.d/gitea` and `/etc/conf.d/gitea`. Do not introduce Docker, Compose, systemd, or a
second process manager.

Before any upgrade, read the operator's handoff notes (`HANDOFF.md`, kept beside these scripts on the
server, not in the repository) completely and re-examine the live state. The canonical
customizations live in `custom-templates/` and `custom-public/`; never edit only
`/opt/gitea/custom`, because a later deployment would overwrite a live-only change.

## TrueOG customizations to preserve

Every upgrade must keep all of the following working on the new version. They were built and
approved over many revisions (history in the handoff notes, "Homepage and custom assets"); do not drop, simplify, or "reset to upstream" any of them. If an upstream change conflicts,
port the customization to the new markup and keep its behavior.

**Templates** (`custom-templates/`, installed to `/opt/gitea/custom/templates/`; see its README):

- `home.tmpl` and `user/dashboard/dashboard.tmpl`: the landing page at `/` (signed out) and
  `/?home=1` (signed in; the dashboard override's else branch is the unchanged upstream dashboard).
- `trueog/landing.tmpl`, `trueog/title.tmpl`, `trueog/glyphs.tmpl`: the landing body (big logo, title
  with Gitea's teacup between "TrueOG" and "Gitea", four banner buttons, six cards), the
  shared title, and the generated Matrix glyph rain.
- `user/auth/signin.tmpl` and `user/auth/external_auth_methods.tmpl`: the sign-in page in the landing
  style (title, glyph rain, boxed form, custom provider labels and colors, people icon for staff).
- `repo/code/upstream_diverging_info.tmpl`: the fork banner. Like GitHub, every branch of a non-archived
  fork (Gitea prepares no upstream information for archived ones) says how many
  commits it is ahead of and behind its upstream branch, each linking to that diff
  (`<upstream>/compare/<branch>...<fork>:<branch>` and the reverse); `scripts/trueog-upstream.js` fetches
  the live counts from `/-/trueog-divergence`, the `trueog-divergence` service (installed as
  `/usr/local/sbin/trueog-divergence`, OpenRC `/etc/init.d/trueog-divergence`, user gitea,
  127.0.0.1:3992, routed by Nginx with per-visitor rate limits). It counts with git on disk, only when the
  visitor can read both repositories' code: Gitea itself must serve each repository's
  `/<owner>/<repo>/branches/list` to the visitor's own session. At most 16 requests run at once (more get
  503; identical requests share one count; Nginx allows each visitor one request at a time); branch names
  must be valid git branch names (no reflog or revision syntax). Each response's X-TrueOG-Divergence-Version
  header is a hash of the running code, which the installer and `upgrade-gitea.sh check` compare with the
  installed file. For an upstream not
  open to everyone (a private repository, a limited/private owning user or organization, or a disabled
  Code unit) the banner appears only when Gitea's own banner would.
  Gitea's Sync fork button keeps Gitea's own condition.
- `base/footer_content.tmpl`: Gitea's footer with the version number wrapped in `<strong>` (like the page
  and template times), so the three footer numbers can be Gitea green.
- `status/404.tmpl`: Gitea's 404 page with TrueOG's picture (`img/trueog-404.jpg`) above the "404 Not
  Found" heading and the message; `css/trueog-404.css`, linked only from this template, starts the block higher so
  everything fits on one screen.
- The effective header hook `trueog/header_hook.tmpl` (installed as `custom/header.tmpl`; sitewide
  CSS plus cross-browser TrueOG favicon metadata, and `js/trueog-global.js` only under `/trueog/`), and `custom/extra_links.tmpl` (Bukkit-gold
  Minecraft lambda Home and signed-in Dashboard links, signed-in logo hiding, and
  `trueog-nav.css`, including theme-safe green navbar selections plus the Monocraft footer, its green
  links and miniature Gitea teacup, and its sitewide light-aqua motto), and the effective
  no-output footer hook `trueog/footer_hook.tmpl` (installed as `custom/extra_links_footer.tmpl`).

**Public assets** (`custom-public/`, installed to `/opt/gitea/custom/public/`): `css/trueog-home.css`,
`css/trueog-nav.css`, `css/trueog-public.css`, `css/trueog-global.css`, `css/trueog-404.css` and
`img/trueog-404.jpg` (404 page only), `js/trueog-global.js` (only on `/trueog/...` pages; never on the
landing or sign-in page), `scripts/trueog-upstream.js` (fork banner only), `scripts/trueog-public.js`
(chooser pages only),
`fonts/Monocraft.woff2`, `img/trueog-logo.png`, the favicon family
(`img/favicon.png`, `img/favicon.ico`, `img/apple-touch-icon.png`, `img/trueog-icon-192.png`,
`img/trueog-icon-512.png`), `assets/trueog-manifest.json`, and `assets/browserconfig.xml`.

**Installed outside `/opt/gitea`** by `install-custom-templates.sh`: `/usr/local/sbin/gitea-homepage-stats`
with `/etc/cron.d/gitea-homepage-stats` (every 5 minutes it writes `css/trueog-stats.css`, the
landing page's statistics, from the API's `X-Total-Count` headers); `/usr/local/sbin/gitea-public-pages`
with `/etc/cron.d/gitea-public-pages` (every 5 minutes it generates the credential-free public pull and
issue indexes and repository choosers solely from Gitea's anonymous API); the reviewed Nginx vhost and
public-page security-header snippet in `gitea.nginx.conf` and `gitea-public-page-headers.nginx` (including
the per-visitor rate limits on `/-/trueog-divergence`); the fork banner's count service
`/usr/local/sbin/trueog-divergence` with its OpenRC script `/etc/init.d/trueog-divergence` (enabled in the
default runlevel, run by supervise-daemon as gitea on 127.0.0.1:3992; the installer fails if it is not
enabled, started and supervised); and `/etc/logrotate.d/gitea` (daily `copytruncate` rotation of the
supervise-daemon logs, weekly for the count service's log). The installer
also puts `gitea-license-bundle` in `/usr/local/sbin` and the canonical Monocraft OFL in
`/usr/local/share/licenses/monocraft/OFL-1.1.txt`. It rebuilds
`/opt/gitea/custom/public/assets/licenses.txt` from the active Gitea binary's embedded aggregate
notices, then appends Monocraft's OFL. The upgrade script repeats that operation from the target
binary after switching versions, so neither Gitea's version-specific notices nor the font license
are lost across updates. Because Gitea refuses to execute as root, the root-owned bundle helper runs
only `embedded view` through `runuser -u gitea`; its atomic destination installation remains in the
root shell.
`check-gitea-logs.sh` parses Gitea's console log format (`YYYY/MM/DD HH:MM:SS ... [E]`, router
`completed ... 5xx` lines).

**TrueOG rules baked into these files:** the landing and sign-in pages run no JavaScript of TrueOG's own
(`js/trueog-global.js` loads only under `/trueog/`); no two
cards link to the same place; each of the five prose cards uses responsive natural-flow copy that
fills exactly three rendered lines across the supported card widths, without forced line breaks or
clipped copy; the title outline is a
`filter: drop-shadow()` (dark-mode extensions recolor `text-shadow`); asset URLs carry `?v=`/`?t=`
cache keys because Cloudflare caches `/assets/` for 6 hours, so bump the key whenever a file changes.
The contribution-button glyphs explicitly retain their intended foreground across normal, visited,
focused, active, and hovered link states, including browser back navigation.
The complete landing page and standard footer use Monocraft; the motto appears in every standard
footer, centered in the space between its left and right text groups, in Bukkit's light aqua (§b,
`#55ffff`) with Minecraft's text shadow (`#153f3f`), on a translucent black backing in light themes (like
a Minecraft chat line; 8.7:1). Powered by Gitea and the footer's three numbers (the
version, which `base/footer_content.tmpl` wraps in `<strong>`, and the page and template times) use a
contrast-safe Gitea green (`light-dark(#4a7a1d, #78b542)`, 4.8:1 and 7.0:1); Licenses and API use the text color, like the
theme and language selectors; a miniature Gitea teacup in that green precedes “Powered by Gitea,” and
every footer icon is followed by one character's space (`1ch`). The transparent TrueOG browser icon is
declared in PNG, multi-size ICO, Apple touch, web-app manifest, and Microsoft tile formats. The
Matrix rain is not cleared behind the landing logo, title, or buttons; it uses Gitea green and only
20 active compositor layers. Forced colors hide the decorative rain, while
`prefers-contrast: more` keeps it visible at 35% of each stream's normal opacity so Android's High
Contrast preference does not remove the background. The first action row follows the title row with
an explicit `2rem` gap; the selector must remain adjacent to the title rather than use
`:first-of-type`, because the title is already the hero's first `div`.

The exact public routes `/pulls?state=all|open|closed` and `/issues?state=all|open|closed`
are static indexes generated from the same code, while bare `/pulls` and `/issues` remain Gitea's signed-in
personalized dashboards. The landing page's statistics are Public Repos (linking to `/explore/repos`), Open pull requests (linking to
`/pulls?state=open`) and Open issues (linking to `/issues?state=open`); only open items are counted,
and repositories of the `upstream` organization are excluded from all of them. The
labels are two lines each ("Public" / "Repos", "Open" / "pull requests", "Open" / "issues");
`trueog-home.css` (`?v=39`) sizes them by their widest lines, 25 Monocraft characters
(`(100cqi - 1rem) / 16.9`), and top-aligns the columns so the numbers line up; recompute that divisor if a
label changes. Everything said below about the pull indexes applies to the
issue indexes too (`trueog-issues-*`, `trueog-issues-org-*`; an empty issue list is valid). The all-state index is paginated at exactly 50 pull requests
per page (`&page=N` after page 1); open and closed remain complete list views. Every pull list carries a
“Hide personal repositories” checkbox. It is a server-rendered link (`role="checkbox"`, no form or
script needed) to a second generated set, `trueog-pulls-org-*.html`, that omits pull requests in
repositories whose owner Gitea does not mark as an organization; Nginx serves that set for
`&personal=hide`, and its tabs and pagination keep the parameter. The shared helper only adds the
native Space-key toggle. The generator uses no credentials, rejects private/internal
repositories and any pull not belonging to the anonymous public-repository set, and escapes all
output. Every generated page uses one small external, same-origin helper. Gitea's API token endpoint
does not recognize the normal browser session, so the helper makes a credentialed, no-store GET of
Gitea's own public `/explore/repos` HTML and accepts only Gitea's server-rendered
`data-signed-in-username` navbar
marker. It then replaces guest controls with Dashboard, Issues, Pull Requests, Milestones, Explore,
notifications, native-style create/profile menus, optional Admin, and Sign Out controls. The
generated navbar is a measured copy of Gitea 28.2.0's own navbar as TrueOG customizes it: the same
item geometry, octicons, menu labels, dividers, admin badge, unread-notification count, light and
dark colors, and the phone layout below 768px with its menu toggle. The helper also applies the
theme Gitea renders for the visitor (a fixed light or dark account theme; auto follows the OS) and
shows only the optional menu links Gitea itself offers. After an upgrade that changes upstream
`templates/base/head_navbar.tmpl` or its CSS, re-compare the two bars signed in and out at desktop
and phone widths and port any change to `gitea-public-pages.py` and `trueog-public.css`.
Pull-request content and forms retain the more readable system UI font. It never
reads a cookie value, uses `innerHTML`, embeds a credential, or sends session-derived data off-site;
profile text uses `textContent`, URL path segments are encoded, and avatar URLs must remain
same-origin. Failed or anonymous checks leave signed-out navigation untouched, and every destination
remains protected by Gitea's normal authorization. The probe refuses redirects as an additional
fail-closed guard. The helper loads synchronously from `<head>` (not deferred) so it can hide the
navbar links, though not the bar itself, until the check settles; signed-in visitors therefore never
see the guest links first. It reveals them after 2.5 seconds at most, and without JavaScript nothing
is hidden.
`/contribute/pull-request` and `/contribute/bug-report` also use that helper to
open Gitea's native repository Pull Requests tab, fork flow, or issue-template wizard; there is no
PHP or additional backend. The chooser titles carry the matching Gitea glyph, the bug form points
uncertain visitors to the Discord `#bug-reports` channel, and the custom navigation controls use a
subtle Gitea-green tint while matching the native signed-out homepage navbar's flat Minecraft-lambda Home, Explore,
Help (the same Gitea documentation target), and Sign In layout. Authentication and repository authorization still protect every
submission. The generated-page CSP permits only same-origin scripts and connections; the homepage remains JavaScript-free.
All custom button SVGs use `currentColor`, so their glyph and label change together across normal,
visited, focus, hover, and active states. Filled green, gold, and aqua controls use a dark
foreground; the dark-red staff control uses white; unfilled controls use the foreground appropriate
to their dark surface.

**What `upgrade-gitea.sh` enforces:** source/live parity of every template and asset, the
out-of-tree pieces above (and that the count service is enabled, started and supervised), upstream
changes to the seven overridden templates (`home.tmpl`, `user/auth/signin.tmpl`,
`user/auth/external_auth_methods.tmpl`, `user/dashboard/dashboard.tmpl`,
`repo/code/upstream_diverging_info.tmpl`, `status/404.tmpl`, `base/footer_content.tmpl`; a hard blocker until the override is
updated), the three hooks' existence, and after `apply` the landing page (no `<script>`, statistics,
Home link), the sign-in box, the signed-in Dashboard-link CSS, the fork banner, the 404 page, and the
retired galaxy image's absence.

**What it cannot see: CSS that depends on upstream markup.** After an upgrade, check these still
exist in the new release and still look right (signed out and signed in, desktop and mobile):

- `.full.height` wrapping `#navbar` and the page's `.page-content` (page background, glyph layer,
  hiding `#navbar #navbar-logo` signed out on `/` and `/user/login`).
- `#navbar .navbar-left`, `#navbar-logo`, `.navbar-mobile-right` (Minecraft-lambda Home/Dashboard ordering and the
  `:has(> .trueog-nav-dashboard)` rule that hides the redundant signed-in logo link).
- `signin_inner.tmpl`'s `.ui.container`, `.ui.attached.header`/`.segment`,
  `#external-login-navigator`, and Gitea's `.ui.container` `--page-margin-x` and
  `.svg[width="24"] { min-width }` rules, which `trueog-home.css` overrides inside the sign-in box.
- The fork banner's data: `.UpstreamDivergingInfo` (`BaseBranchName`, `BaseBranchHasNewCommits`),
  `.Repository.BaseRepo`, `.BranchName`, `.CanWriteCode`, and Gitea's `repo.pulls.upstream_diverging_*`
  locale keys and `link-action` button; `.Repository.BaseRepo.IsPrivate`, `MustOwner ctx`, and the owner's
  `.ID` and `.Visibility.IsPublic`, `UnitEnabled ctx ctx.Consts.RepoUnitTypeCode` (the private-upstream
  rule), and the `QueryEscape` helper for the Sync button's branch parameter.
- The 404 page's data and classes: `.NotFoundPrompt`, `.NotFoundGoBackURL`, `.IsRepo`, `base/alert`,
  `.status-page-error`/`-title`, and the `--border-radius-medium` and `--color-shadow` theme variables.
- Template data keys and helpers used by the overrides: `.CurrentURL`, `.IsSigned`, `.PageStartTime`, `StringUtils`,
  `AssetUrlPrefix`, `AppSubUrl`, `svg`, and the octicons `bug`, `book`, `graph`, `heart-fill`,
  `mark-github`, `people`, `git-pull-request`, plus `gitea-discord` and `/assets/img/logo.svg`.

## Prepare a target release

1. Confirm the latest patch in the requested release line using Gitea's official release page.
2. Read the release notes and official upgrade documentation for breaking changes.
3. Download these three files from `https://dl.gitea.com/gitea/<version>/` into this directory:
   `gitea-<version>-linux-amd64`, its `.sha256`, and its `.asc`.
4. Set the binary executable and keep all three owned by `system:system`.
5. The system user's GPG keyring must contain Gitea's Teabot primary key fingerprint
   `7C9E68152594688862D62AF62D9AE806EC1592E2`.

## Upgrade

Run the phases separately, replacing the example version:

```sh
doas sh /home/system/gitea-upgrade/run-logged.sh upgrade-gitea.sh check 28.3.0
doas sh /home/system/gitea-upgrade/run-logged.sh upgrade-gitea.sh apply 28.3.0
```

`run-logged.sh` runs the helper unchanged and saves its complete output and `HELPER_EXIT=<status>` in
`logged-upgrade-gitea-<phase>-<version>.log` (likewise `logged-install-custom-templates.log`).

The check phase is read-only. It verifies the checksum/signature, Dockerless OpenRC baseline,
available capacity, source/live customization parity, both generated-page jobs, the reviewed Nginx
public routes, and Gitea log rotation installed outside `/opt/gitea`, the custom
header/navbar/footer hooks, the count service (enabled, started, supervised and returning counts), and
whether any upstream template overridden by TrueOG (`home.tmpl`, `user/auth/external_auth_methods.tmpl`,
`user/auth/signin.tmpl`, `user/dashboard/dashboard.tmpl`, `repo/code/upstream_diverging_info.tmpl`,
`status/404.tmpl`, `base/footer_content.tmpl`) changed between the active and target binaries. It
also verifies the dedicated Gitea SSH signing key, its permissions, the always-sign policy, and the
live public-key endpoint. A template difference is a hard blocker: review the target template and
update the override first.

The apply phase installs the versioned binary, gracefully stops OpenRC (including a known orphaned
`supervise-daemon` child case), takes an offline PostgreSQL dump and `custom`/`data` archive, writes
rollback state, redeploys the canonical customizations, migrates, starts through OpenRC, and checks
the version, process count, homepage (no `<script>` in the landing content, live statistics), public
pull/contribution pages and their script boundary, navbar Home/Dashboard links, theme-safe navbar/footer/card
colors, signed-in logo hiding, logo/font assets, aggregate license file, approval wording
script, both custom login labels, and the sign-in box. The signing key lives under `/opt/gitea/custom/conf`, so it is included in
the offline `custom/` archive; the post-upgrade check confirms that Gitea still serves that key.

## Rollback

If migration or validation fails:

```sh
doas sh /home/system/gitea-upgrade/run-logged.sh upgrade-gitea.sh rollback <target-version>
```

Rollback stops Gitea, preserves the failed target's current `custom` and `data` directories, restores
the offline database/data/config backups and previous version symlink, then starts through OpenRC.

After a successful upgrade, visually verify signed-out desktop/mobile pages and a signed-in page,
check repository branch protections and branch/tag mirrors, then update `HANDOFF.md` with the actual
version, backup paths, template-compatibility result, health checks, and any retained known issues.
