#!/bin/sh
# Install Gitea template and public-asset overrides from ~/gitea-upgrade into /opt/gitea/custom and restart.
#   doas sh ~/gitea-upgrade/install-custom-templates.sh
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
SRC=/home/system/gitea-upgrade/custom-templates
DST=/opt/gitea/custom/templates
find "$SRC" -type f -name '*.tmpl' | while read -r f; do
	rel=${f#"$SRC"/}
	[ "$rel" != custom/extra_links_footer.tmpl ] || continue
	[ "$rel" != custom/header.tmpl ] || continue
	install -D -m 640 -o gitea -g gitea "$f" "$DST/$rel" && echo "installed $rel"
done
# The historical canonical header hook is root-owned. Install the maintained effective hook, which
# preserves the existing TrueOG CSS/JS and adds cross-browser favicon metadata.
install -m 640 -o gitea -g gitea "$SRC/trueog/header_hook.tmpl" "$DST/custom/header.tmpl"
echo "installed custom/header.tmpl from trueog/header_hook.tmpl"
# The historical canonical hook is root-owned. Install the effective no-output hook from the
# maintained TrueOG partial so the existing Gitea Licenses link is the footer's only license link.
install -m 640 -o gitea -g gitea "$SRC/trueog/footer_hook.tmpl" "$DST/custom/extra_links_footer.tmpl"
echo "installed custom/extra_links_footer.tmpl from trueog/footer_hook.tmpl"
PUBLIC_SRC=/home/system/gitea-upgrade/custom-public
PUBLIC_DST=/opt/gitea/custom/public
find "$PUBLIC_SRC" -type f | while read -r f; do
	rel=${f#"$PUBLIC_SRC"/}
	install -D -m 644 -o gitea -g gitea "$f" "$PUBLIC_DST/$rel" && echo "installed public/$rel"
done

# The loops above only add or replace files, so a file dropped from the canonical source would stay
# live. Remove each retired file, but only while it is still absent from the source tree.
for rel in public/assets/img/trueog-galaxy.jpg public/assets/img/trueog-sga.svg public/assets/site-manifest.json public/assets/trueog-manifest.webmanifest templates/trueog/hero_code.tmpl templates/trueog/banner.tmpl; do
	case $rel in
	public/*) source=$PUBLIC_SRC/${rel#public/} ;;
	templates/*) source=$SRC/${rel#templates/} ;;
	*) echo "unknown retired path $rel" >&2; exit 1 ;;
	esac
	[ ! -e "$source" ] || continue
	if [ -e "/opt/gitea/custom/$rel" ]; then
		rm -f "/opt/gitea/custom/$rel" && echo "removed retired $rel"
	fi
done

# The homepage runs no JavaScript; its statistics stylesheet is rewritten every 5 minutes by this job.
install -m 755 -o root -g root /home/system/gitea-upgrade/gitea-homepage-stats /usr/local/sbin/gitea-homepage-stats
install -m 644 -o root -g root /home/system/gitea-upgrade/gitea-homepage-stats.cron /etc/cron.d/gitea-homepage-stats
echo "installed /usr/local/sbin/gitea-homepage-stats and /etc/cron.d/gitea-homepage-stats"

# Public pull indexes and repository-selection wizards are generated from the anonymous API only.
install -d -m 755 -o gitea -g gitea "$PUBLIC_DST/assets/html"
install -m 755 -o root -g root /home/system/gitea-upgrade/gitea-public-pages.py /usr/local/sbin/gitea-public-pages
install -m 644 -o root -g root /home/system/gitea-upgrade/gitea-public-pages.cron /etc/cron.d/gitea-public-pages
echo "installed /usr/local/sbin/gitea-public-pages and /etc/cron.d/gitea-public-pages"

# Live ahead/behind counts for the fork banner: a small OpenRC service (as gitea) behind Nginx.
# Stop the service synchronously and wait for the old process to exit, then start it detached (like Gitea
# below), so the checks can only see the new process.
divergence_restart() {
	rc-service trueog-divergence stop >/dev/null 2>&1 || true
	n=0
	while pgrep -f '^/usr/bin/python3 /usr/local/sbin/trueog-divergence' >/dev/null; do
		[ "$n" -lt 30 ] || { echo "trueog-divergence did not stop after 30 seconds" >&2; return 1; }
		sleep 1
		n=$((n + 1))
	done
	setsid -f /bin/sh -c 'rc-service trueog-divergence start >>/var/log/gitea/openrc-detached-start.log 2>&1'
	n=0
	until rc-service trueog-divergence status >/dev/null 2>&1 &&
		pgrep -f '^supervise-daemon trueog-divergence ' >/dev/null &&
		curl -fs -o /dev/null "http://127.0.0.1:3992/-/trueog-divergence?fork=trueog/MyWorlds&branch=master&base=upstream/MyWorlds&base_branch=master"; do
		[ "$n" -lt 30 ] || { echo "trueog-divergence was not started, supervised and answering after 30 seconds" >&2; return 1; }
		sleep 1
		n=$((n + 1))
	done
}
# From the moment its files are replaced until the new version is verified running, any failing exit of
# this installer (here, in Gitea's restart, the license or logrotate steps, or the count service's own
# start) puts the previous files and runlevel state back and restarts the previous service; a first
# installation is removed again instead.
divergence_enabled() {
	rc-update show default | grep -Eq '(^|[[:space:]])trueog-divergence([[:space:]]|$)'
}
# Each step is verified: restored files must equal the backup, a first installation's files must be gone,
# and runlevel membership must equal what it was. Only then is the previous service restarted and success
# reported; otherwise ROLLBACK INCOMPLETE is printed and the backup kept.
divergence_rollback() {
	echo "restoring the previous trueog-divergence" >&2
	ok=yes
	if [ -e "$DIV_BACKUP/service" ]; then
		install -m 755 -o root -g root "$DIV_BACKUP/service" /usr/local/sbin/trueog-divergence &&
			cmp -s "$DIV_BACKUP/service" /usr/local/sbin/trueog-divergence || ok=no
	else
		rc-service trueog-divergence stop >/dev/null 2>&1 || true
		rm -f /usr/local/sbin/trueog-divergence || true
		[ ! -e /usr/local/sbin/trueog-divergence ] || ok=no
	fi
	if [ -e "$DIV_BACKUP/initd" ]; then
		install -m 755 -o root -g root "$DIV_BACKUP/initd" /etc/init.d/trueog-divergence &&
			cmp -s "$DIV_BACKUP/initd" /etc/init.d/trueog-divergence || ok=no
	else
		rm -f /etc/init.d/trueog-divergence || true
		[ ! -e /etc/init.d/trueog-divergence ] || ok=no
	fi
	if [ "$DIV_WAS_ENABLED" = yes ]; then
		divergence_enabled || rc-update add trueog-divergence default >/dev/null 2>&1 || true
		divergence_enabled || ok=no
	else
		rc-update del trueog-divergence default >/dev/null 2>&1 || true
		! divergence_enabled || ok=no
	fi
	if [ "$ok" = no ]; then
		echo "ROLLBACK INCOMPLETE: trueog-divergence files or runlevel differ from the previous state; backup in $DIV_BACKUP" >&2
		return 1
	fi
	if [ ! -e "$DIV_BACKUP/service" ]; then
		echo "first installation of trueog-divergence removed" >&2
		return 0
	fi
	if divergence_restart; then
		echo "previous trueog-divergence restored and answering (backup kept in $DIV_BACKUP)" >&2
	else
		echo "previous trueog-divergence files restored, but it is not answering (Gitea down?); backup in $DIV_BACKUP" >&2
		return 1
	fi
}
DIV_BACKUP=$(mktemp -d /var/tmp/trueog-divergence-previous.XXXXXX)
[ ! -e /usr/local/sbin/trueog-divergence ] || cp -p /usr/local/sbin/trueog-divergence "$DIV_BACKUP/service"
[ ! -e /etc/init.d/trueog-divergence ] || cp -p /etc/init.d/trueog-divergence "$DIV_BACKUP/initd"
if divergence_enabled; then
	DIV_WAS_ENABLED=yes
else
	DIV_WAS_ENABLED=no
fi
# Every catchable Linux signal whose default action terminates the process becomes an ordinary failing
# exit (128 + its number) so the EXIT trap runs: 1-8 (HUP INT QUIT ILL TRAP ABRT BUS FPE), 10-16 (USR1
# SEGV USR2 PIPE ALRM TERM STKFLT), 24-27 (XCPU XFSZ VTALRM PROF), 29-31 (IO PWR SYS) and the real-time
# signals 34-64. Not listed: KILL (9) and STOP (19), which cannot be caught; 32 and 33, which the C library
# reserves for itself so no shell can catch them; and CHLD, CONT, TSTP, TTIN, TTOU, URG and WINCH, whose
# default does not terminate. Numbers are used because dash knows no STKFLT or
# POLL name. Each handler ignores all of them before anything else, and the EXIT handler ignores them
# before it disarms itself, so none can end the shell and skip the rollback.
DIV_SIGNALS="1 2 3 4 5 6 7 8 10 11 12 13 14 15 16 24 25 26 27 29 30 31"
n=34
while [ "$n" -le 64 ]; do
	DIV_SIGNALS="$DIV_SIGNALS $n"
	n=$((n + 1))
done
divergence_signal() {
	trap '' $DIV_SIGNALS
	exit "$1"
}
divergence_on_exit() {
	status=$?
	trap '' $DIV_SIGNALS
	trap - EXIT
	if [ "$status" -ne 0 ]; then
		divergence_rollback || true
	fi
	exit "$status"
}
for sig in $DIV_SIGNALS; do
	trap "divergence_signal $((128 + sig))" "$sig"
done
trap 'divergence_on_exit' EXIT
install -m 755 -o root -g root /home/system/gitea-upgrade/trueog-divergence.py /usr/local/sbin/trueog-divergence
install -m 755 -o root -g root /home/system/gitea-upgrade/trueog-divergence.initd /etc/init.d/trueog-divergence
rc-update add trueog-divergence default >/dev/null 2>&1 || true  # status differs between OpenRC versions; membership is checked next
rc-update show default | grep -Eq '(^|[[:space:]])trueog-divergence([[:space:]]|$)' || {
	echo "trueog-divergence is not in OpenRC's default runlevel" >&2
	exit 1
}
echo "installed /usr/local/sbin/trueog-divergence and /etc/init.d/trueog-divergence"

# Preserve Gitea's version-specific aggregate dependency notices and append Monocraft's OFL. The
# bundle is generated from the active binary so a future Gitea update cannot freeze old notices.
install -m 755 -o root -g root /home/system/gitea-upgrade/gitea-license-bundle /usr/local/sbin/gitea-license-bundle
install -D -m 644 -o root -g root /home/system/gitea-upgrade/monocraft.LICENSE /usr/local/share/licenses/monocraft/OFL-1.1.txt
/usr/local/sbin/gitea-license-bundle /opt/gitea/current/gitea "$PUBLIC_DST/assets/licenses.txt"

# Gitea's console log and the mirror logs are rotated by logrotate's daily cron run (see
# gitea.logrotate). The dry run must parse cleanly before Gitea is restarted.
install -m 644 -o root -g root /home/system/gitea-upgrade/gitea.logrotate /etc/logrotate.d/gitea
if logrotate -d /etc/logrotate.d/gitea 2>&1 | grep -i '^error'; then
	echo "logrotate rejected /etc/logrotate.d/gitea" >&2
	exit 1
fi
echo "installed /etc/logrotate.d/gitea"

# A previous failed supervise-daemon restart can leave an orphaned Gitea process behind. Stop the
# managed service, then gracefully stop only remaining processes owned by the gitea service account.
rc-service gitea stop || true
if pgrep -u gitea -x gitea >/dev/null; then
	echo "stopping orphaned gitea process"
	pkill -TERM -u gitea -x gitea
fi
n=0
while pgrep -u gitea -x gitea >/dev/null; do
	[ "$n" -lt 30 ] || { echo "gitea did not stop after 30 seconds; refusing to start a second instance" >&2; exit 1; }
	sleep 1
	n=$((n + 1))
done

rc-service gitea zap >/dev/null 2>&1 || true
rm -f /run/gitea.pid
# Start in a separate session so automation runners cannot reap supervise-daemon when their own
# command exits. This is still the native Dockerless OpenRC service.
setsid -f /bin/sh -c 'rc-service gitea start >>/var/log/gitea/openrc-detached-start.log 2>&1'
ready=0
n=0
while [ "$n" -lt 60 ]; do
	if curl -fs http://127.0.0.1:3000/ | grep -F 'trueog-home.css?v=39' >/dev/null; then
		ready=1
		break
	fi
	sleep 1
	n=$((n + 1))
done
[ "$ready" -eq 1 ] || { echo "gitea did not become ready after 60 seconds" >&2; exit 1; }
# The counting service starts after Gitea (its OpenRC dependency); a failure here exits, and the EXIT trap
# armed when its files were replaced puts the previous version back.
divergence_restart || exit 1
# The running process must be the code just installed (its version header is a hash of its own file).
want=$(sha256sum /usr/local/sbin/trueog-divergence | cut -c1-16)
got=$(curl -fsS -D - -o /dev/null "http://127.0.0.1:3992/-/trueog-divergence?fork=trueog/MyWorlds&branch=master&base=upstream/MyWorlds&base_branch=master" |
	tr -d '\r' | awk -F': ' 'tolower($1) == "x-trueog-divergence-version" { print $2 }')
[ "$got" = "$want" ] || { echo "running trueog-divergence ($got) is not the installed code ($want)" >&2; exit 1; }
trap - EXIT $DIV_SIGNALS  # the new service is verified: nothing to roll back from here on
rm -rf "$DIV_BACKUP"
echo "trueog-divergence restarted: answering, enabled, supervised, running version $got"
count=$(pgrep -u gitea -x gitea | wc -l)
[ "$count" -eq 1 ] || { echo "expected one gitea process, found $count" >&2; exit 1; }
pgrep -f '^supervise-daemon gitea ' >/dev/null || { echo "OpenRC supervisor is not running" >&2; exit 1; }
curl -fsS http://127.0.0.1:3000/assets/img/trueog-logo.png >/dev/null
curl -fsS http://127.0.0.1:3000/assets/css/trueog-global.css?v=2 | grep -F 'trueog-logo.png?v=1' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F '>GitHub mirror</a>' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F 'trueog-nav-home' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F 'class="trueog-nav-home-lambda" aria-hidden="true">λ</span>' >/dev/null
for page in / /user/login; do
	if curl -fsS "http://127.0.0.1:3000$page" | grep -Eq '/assets/(js|scripts)/trueog'; then
		echo "$page loads TrueOG JavaScript; the landing and sign-in pages must not" >&2
		exit 1
	fi
done
curl -fsS http://127.0.0.1:3000/trueog/true-og | grep -F 'trueog-global.js?v=1' >/dev/null
curl -fsS http://127.0.0.1:3000/trueog/MyWorlds | grep -F 'class="ui message flex-text-block trueog-upstream"' >/dev/null
curl -fsS http://127.0.0.1:3000/trueog/MyWorlds | grep -F 'scripts/trueog-upstream.js?v=1' >/dev/null
# The 404 page shows TrueOG's picture (templates/status/404.tmpl, css/trueog-404.css).
not_found=$(curl -sS -H 'Accept: text/html' -w '\nHTTP %{http_code}' http://127.0.0.1:3000/trueog-404-check-missing)
printf '%s' "$not_found" | grep -Fx 'HTTP 404' >/dev/null
printf '%s' "$not_found" | grep -F 'class="status-page-error trueog-404"' >/dev/null
printf '%s' "$not_found" | grep -F '/assets/img/trueog-404.jpg?v=1' >/dev/null
printf '%s' "$not_found" | grep -F '/assets/css/trueog-404.css?v=2' >/dev/null
for asset in assets/img/trueog-404.jpg assets/css/trueog-404.css; do
	curl -fsS "http://127.0.0.1:3000/$asset?v=1" | cmp - "$PUBLIC_SRC/$asset"
done
grep -F '{{$landingURL = print AppSubUrl "/?home=1"}}' "$SRC/custom/extra_links.tmpl" >/dev/null
grep -F '<a class="item trueog-nav-dashboard' "$SRC/custom/extra_links.tmpl" >/dev/null
grep -F 'href="{{$dashboardURL}}"' "$SRC/custom/extra_links.tmpl" >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F '/assets/img/favicon.png?v=1' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F '/assets/img/favicon.ico?v=1' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F '/assets/img/apple-touch-icon.png?v=1' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F '/assets/trueog-manifest.json?v=1' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F '/assets/browserconfig.xml?v=1' >/dev/null
curl -fsSI http://127.0.0.1:3000/assets/trueog-manifest.json?v=1 | tr -d '\r' | grep -iFx 'Content-Type: application/json' >/dev/null
for asset in assets/img/favicon.png assets/img/favicon.ico assets/img/apple-touch-icon.png assets/img/trueog-icon-192.png assets/img/trueog-icon-512.png assets/trueog-manifest.json assets/browserconfig.xml; do
	curl -fsS "http://127.0.0.1:3000/$asset?v=1" | cmp - "$PUBLIC_SRC/$asset"
done
home_css=$(curl -fsS http://127.0.0.1:3000/assets/css/trueog-home.css?v=39)
printf '%s' "$home_css" | grep -F '.trueog-title-row' >/dev/null
printf '%s' "$home_css" | grep -F 'grid-auto-rows: 1fr;' >/dev/null
printf '%s' "$home_css" | grep -F 'margin: 0 0 1rem;' >/dev/null
printf '%s' "$home_css" | grep -F '.trueog-hero > .trueog-title-row + .trueog-actions {' >/dev/null
printf '%s' "$home_css" | grep -F 'margin-top: 2rem;' >/dev/null
printf '%s' "$home_css" | grep -F '.trueog-signin-box' >/dev/null
printf '%s' "$home_css" | grep -F '.page-content.trueog-home:not(.trueog-signin)' >/dev/null
printf '%s' "$home_css" | grep -F 'grid-template-columns: 1.25em minmax(0, 1fr);' >/dev/null
printf '%s' "$home_css" | grep -F 'grid-template-columns: repeat(3, minmax(max-content, 1fr));' >/dev/null
printf '%s' "$home_css" | grep -F 'font-size: min(0.9rem, (100cqi - 1rem) / 16.9);' >/dev/null
printf '%s' "$home_css" | grep -F 'fill: #609926; /* upstream Gitea brand green */' >/dev/null
printf '%s' "$home_css" | grep -F 'color: light-dark(#4d7f1e, #78b542);' >/dev/null
printf '%s' "$home_css" | grep -F 'animation: trueog-fall calc(var(--t) + 4s)' >/dev/null
printf '%s' "$home_css" | grep -F '@media (forced-colors: active)' >/dev/null
printf '%s' "$home_css" | grep -F '@media (prefers-contrast: more)' >/dev/null
printf '%s' "$home_css" | grep -F 'opacity: calc(var(--o) * 0.35);' >/dev/null
if printf '%s' "$home_css" | grep -F '@media (prefers-contrast: more), (forced-colors: active)' >/dev/null; then
	echo "homepage stylesheet still hides contrast-preference glyphs with the retired combined query" >&2
	exit 1
fi
printf '%s' "$home_css" | grep -F -- '-webkit-line-clamp: 3;' >/dev/null
printf '%s' "$home_css" | grep -F 'height: calc(3 * 1.55em);' >/dev/null
printf '%s' "$home_css" | grep -F 'container-type: inline-size;' >/dev/null
printf '%s' "$home_css" | grep -F '@container (min-width: 500px)' >/dev/null
printf '%s' "$home_css" | grep -F '.trueog-actions a.ui.button:visited' >/dev/null
printf '%s' "$home_css" | grep -F '.trueog-actions a.ui.button:hover' >/dev/null
printf '%s' "$home_css" | grep -F '.trueog-signin-box .ui.button:active' >/dev/null
printf '%s' "$home_css" | grep -F '.trueog-signin-box .ui.button .svg' >/dev/null
printf '%s' "$home_css" | grep -F 'color: inherit;' >/dev/null
printf '%s' "$home_css" | grep -F '.trueog-action-icon .svg' >/dev/null
if printf '%s' "$home_css" | grep -F '.trueog-hero::before' >/dev/null; then
	echo "homepage stylesheet still contains the retired hero clearing" >&2
	exit 1
fi
curl -fsS http://127.0.0.1:3000/ | grep -F 'href="/trueog/true-og/activity">Statistics</a>' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F 'class="ui button trueog-pr" href="/contribute/pull-request"' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F '<span class="trueog-action-label">Pull request / fork</span>' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F 'class="ui button trueog-bug" href="/contribute/bug-report"' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F 'class="trueog-action-icon"' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F 'href="https://true-og.net/TrueOG-Contributor-Guide.pdf">Contributor guide</a>' >/dev/null
home_body=$(curl -fsS http://127.0.0.1:3000/)
if printf '%s' "$home_body" | grep -F 'trueog-card-line' >/dev/null; then
	echo "homepage card copy still contains forced line spans" >&2
	exit 1
fi
for tier in xs sm md lg; do
	[ "$(printf '%s' "$home_body" | grep -o "trueog-card-copy-$tier" | wc -l)" -eq 5 ] || {
		echo "homepage must contain five responsive $tier card-copy variants" >&2
		exit 1
	}
done
printf '%s' "$home_body" | grep -F 'Learn how to contribute code or maps to TrueOG Network.' >/dev/null
printf '%s' "$home_body" | grep -F 'Our custom fork of Purpur runs MCJE 1.19.4' >/dev/null
printf '%s' "$home_body" | grep -F 'Everything behind TrueOG is public and available to everyone, forever' >/dev/null
printf '%s' "$home_body" | grep -F 'Chat with the TrueOG community, get assistance in #plugin-help, and see what we' >/dev/null
printf '%s' "$home_body" | grep -F 'Read-only GitHub mirrors automatically receive' >/dev/null
curl -fsS http://127.0.0.1:3000/user/login | grep -F 'class="trueog-signin-box"' >/dev/null
runuser -u gitea -- /usr/local/sbin/gitea-homepage-stats
runuser -u gitea -- /usr/local/sbin/gitea-public-pages
curl -fsS http://127.0.0.1:3000/assets/css/trueog-stats.css | grep -F '.trueog-stat-repos::before' >/dev/null
curl -fsS http://127.0.0.1:3000/ | grep -F 'trueog-stats.css?t=' >/dev/null
# Each pull view exists twice: complete (trueog-pulls-*) and with personal repositories hidden
# (trueog-pulls-org-*, served for personal=hide). Each variant's checkbox must report its own state.
for prefix in trueog-pulls- trueog-pulls-org-; do
	if [ "$prefix" = trueog-pulls-org- ]; then filter_checked=true; else filter_checked=false; fi
	for page in "${prefix}open.html" "${prefix}closed.html"; do
		page_body=$(curl -fsS "http://127.0.0.1:3000/assets/html/$page")
		printf '%s' "$page_body" | grep -F 'trueog-public.css?v=14' >/dev/null
		printf '%s' "$page_body" | grep -F 'class="trueog-public-footer-left" href="https://about.gitea.com/">Powered by Gitea</a>' >/dev/null
		printf '%s' "$page_body" | grep -F '<script src="/assets/scripts/trueog-public.js?v=7"></script>' >/dev/null
		printf '%s' "$page_body" | grep -F "class=\"trueog-public-filter\" role=\"checkbox\" aria-checked=\"$filter_checked\"" >/dev/null
		[ "$(printf '%s' "$page_body" | grep -oi '<script' | wc -l)" -eq 1 ] || {
			echo "generated pull list has an unexpected script count: $page" >&2
			exit 1
		}
	done
	[ -f "$PUBLIC_DST/assets/html/${prefix}all.html" ] || { echo "missing generated ${prefix}all.html" >&2; exit 1; }
	all_pull_cards=0
	for page_path in "$PUBLIC_DST/assets/html/${prefix}all.html" "$PUBLIC_DST"/assets/html/"${prefix}"all-page-*.html; do
		[ -f "$page_path" ] || continue
		page_body=$(curl -fsS "http://127.0.0.1:3000/assets/html/${page_path##*/}")
		printf '%s' "$page_body" | grep -F 'trueog-public.css?v=14' >/dev/null
		printf '%s' "$page_body" | grep -F '<script src="/assets/scripts/trueog-public.js?v=7"></script>' >/dev/null
		printf '%s' "$page_body" | grep -F "class=\"trueog-public-filter\" role=\"checkbox\" aria-checked=\"$filter_checked\"" >/dev/null
		[ "$(printf '%s' "$page_body" | grep -oi '<script' | wc -l)" -eq 1 ] || {
			echo "generated pull list has an unexpected script count: ${page_path##*/}" >&2
			exit 1
		}
		page_cards=$(printf '%s' "$page_body" | grep -o 'class="trueog-public-card"' | wc -l)
		[ "$page_cards" -le 50 ] || { echo "all-pulls page exceeds 50 entries: ${page_path##*/}" >&2; exit 1; }
		all_pull_cards=$((all_pull_cards + page_cards))
	done
	[ "$all_pull_cards" -gt 0 ] || { echo "generated ${prefix}all pagination is empty" >&2; exit 1; }
done
for page in trueog-pull-wizard.html trueog-bug-wizard.html; do
	page_body=$(curl -fsS "http://127.0.0.1:3000/assets/html/$page")
	printf '%s' "$page_body" | grep -F 'trueog-public.css?v=14' >/dev/null
	printf '%s' "$page_body" | grep -F 'class="trueog-public-form"' >/dev/null
	printf '%s' "$page_body" | grep -F '<select ' >/dev/null
	printf '%s' "$page_body" | grep -F 'class="trueog-public-heading-icon"' >/dev/null
	printf '%s' "$page_body" | grep -F 'aria-label="Navigation Bar"' >/dev/null
	printf '%s' "$page_body" | grep -F '<a href="/" aria-label="Home" data-public-home><span class="trueog-public-home-lambda" aria-hidden="true">λ</span></a>' >/dev/null
	printf '%s' "$page_body" | grep -F '<a href="/" data-public-auth hidden>Dashboard</a>' >/dev/null
	printf '%s' "$page_body" | grep -F '<a href="/pulls" data-public-auth hidden>Pull Requests</a>' >/dev/null
	printf '%s' "$page_body" | grep -F 'class="trueog-public-menu trueog-public-profile-menu" data-public-auth hidden' >/dev/null
	printf '%s' "$page_body" | grep -F '>Sign Out</a>' >/dev/null
	printf '%s' "$page_body" | grep -F '>Site Administration</a>' >/dev/null
	printf '%s' "$page_body" | grep -F 'aria-label="Navigation Menu" aria-expanded="false" data-public-nav-toggle' >/dev/null
	printf '%s' "$page_body" | grep -F 'class="trueog-public-admin-badge"' >/dev/null
	printf '%s' "$page_body" | grep -F '<link rel="icon" href="/assets/img/favicon.png?v=1" sizes="32x32" type="image/png">' >/dev/null
	printf '%s' "$page_body" | grep -F '<a href="/explore/repos">Explore</a>' >/dev/null
	printf '%s' "$page_body" | grep -F '<a target="_blank" href="https://docs.gitea.com" data-public-guest>Help</a>' >/dev/null
	printf '%s' "$page_body" | grep -F '<a rel="nofollow" href="/user/login" data-public-guest>' >/dev/null
	if printf '%s' "$page_body" | grep -F 'trueog-logo.png' >/dev/null; then
		echo "generated chooser still contains the standalone navbar logo: $page" >&2
		exit 1
	fi
	printf '%s' "$page_body" | grep -F '<script src="/assets/scripts/trueog-public.js?v=7"></script>' >/dev/null
	[ "$(printf '%s' "$page_body" | grep -oi '<script' | wc -l)" -eq 1 ] || {
		echo "generated chooser has an unexpected script count: $page" >&2
		exit 1
	}
done
pull_wizard=$(curl -fsS http://127.0.0.1:3000/assets/html/trueog-pull-wizard.html)
printf '%s' "$pull_wizard" | grep -F 'data-target-suffix="/pulls"' >/dev/null
printf '%s' "$pull_wizard" | grep -F 'data-target-suffix="/fork"' >/dev/null
printf '%s' "$pull_wizard" | grep -F '<span>Open pull request</span>' >/dev/null
if printf '%s' "$pull_wizard" | grep -F '/compare/' >/dev/null; then
	echo "pull chooser still targets a branch comparison" >&2
	exit 1
fi
bug_wizard=$(curl -fsS http://127.0.0.1:3000/assets/html/trueog-bug-wizard.html)
printf '%s' "$bug_wizard" | grep -F '<strong>Not sure?</strong>' >/dev/null
printf '%s' "$bug_wizard" | grep -F 'https://discord.gg/ma9pMYpBU6">#bug-reports on Discord</a>' >/dev/null
printf '%s' "$bug_wizard" | grep -F 'data-target-suffix="/issues/new/choose"' >/dev/null
# The helper must load from <head> so it can hide the navbar before the guest links are painted.
printf '%s' "$bug_wizard" | sed -n '/<head>/,/<\/head>/p' | grep -F '<script src="/assets/scripts/trueog-public.js?v=7"></script>' >/dev/null
public_js=$(curl -fsS http://127.0.0.1:3000/assets/scripts/trueog-public.js?v=7)
printf '%s' "$public_js" | grep -F 'allowedSuffixes' >/dev/null
printf '%s' "$public_js" | grep -F 'fetch("/explore/repos"' >/dev/null
printf '%s' "$public_js" | grep -F 'credentials: "same-origin"' >/dev/null
printf '%s' "$public_js" | grep -F 'redirect: "error"' >/dev/null
printf '%s' "$public_js" | grep -F 'new DOMParser().parseFromString' >/dev/null
printf '%s' "$public_js" | grep -F '[data-signed-in-username]' >/dev/null
printf '%s' "$public_js" | grep -F 'username.textContent = login' >/dev/null
printf '%s' "$public_js" | grep -F 'avatarUrl.origin === window.location.origin' >/dev/null
if printf '%s' "$public_js" | grep -F '.innerHTML' >/dev/null; then
	echo "public navigation helper must not inject fetched Gitea markup with innerHTML" >&2
	exit 1
fi
if printf '%s' "$public_js" | grep -E 'document\.cookie|localStorage|sessionStorage' >/dev/null; then
	echo "public navigation helper must not read browser credential or storage values" >&2
	exit 1
fi
if printf '%s' "$public_js" | grep -F '/api/v1/user' >/dev/null; then
	echo "public navigation helper still uses the API endpoint that cannot read Gitea browser sessions" >&2
	exit 1
fi
printf '%s' "$public_js" | grep -F 'if (home) home.setAttribute("href", "/?home=1")' >/dev/null
printf '%s' "$public_js" | grep -F 'root.classList.add("trueog-js", "trueog-auth-pending")' >/dev/null
printf '%s' "$public_js" | grep -F 'window.setTimeout(revealNavigation, 2500)' >/dev/null
printf '%s' "$public_js" | grep -F 'const applyTheme = (nativePage) =>' >/dev/null
printf '%s' "$public_js" | grep -F '[data-public-nav-toggle]' >/dev/null
printf '%s' "$public_js" | grep -F 'control.getAttribute("role") !== "checkbox"' >/dev/null
public_css=$(curl -fsS http://127.0.0.1:3000/assets/css/trueog-public.css?v=14)
printf '%s' "$public_css" | grep -F '.trueog-public-nav-left' >/dev/null
printf '%s' "$public_css" | grep -F 'color-scheme: dark;' >/dev/null
printf '%s' "$public_css" | grep -F 'font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;' >/dev/null
printf '%s' "$public_css" | grep -F 'font-family: "Monocraft", monospace;' >/dev/null
printf '%s' "$public_css" | grep -F 'font-feature-settings: "kern" 0, "liga" 0, "calt" 0;' >/dev/null
printf '%s' "$public_css" | grep -F '@media (max-width: 767.98px)' >/dev/null
printf '%s' "$public_css" | grep -F 'html.trueog-theme-dark .trueog-public-nav {' >/dev/null
printf '%s' "$public_css" | grep -F '.trueog-js .trueog-public-nav-open' >/dev/null
if printf '%s' "$public_css" | grep -F 'font-size: 12px;' >/dev/null; then
	echo "generated-page navbar still shrinks below the native 14px size" >&2
	exit 1
fi
printf '%s' "$public_css" | grep -F '.trueog-public-heading h1' >/dev/null
printf '%s' "$public_css" | grep -F 'font-family: "Monocraft", monospace;' >/dev/null
printf '%s' "$public_css" | grep -F -- '--trueog-nav-bg: #f6f7fa;' >/dev/null
printf '%s' "$public_css" | grep -F 'font-size: 14px;' >/dev/null
printf '%s' "$public_css" | grep -F 'font-size: clamp(1.5rem, 4vw, 1.75rem);' >/dev/null
printf '%s' "$public_css" | grep -F 'color: #FFAA00; /* Bukkit ChatColor.GOLD */' >/dev/null
printf '%s' "$public_css" | grep -F 'transform: translateX(calc(1em / 18));' >/dev/null
printf '%s' "$public_css" | grep -F '.trueog-public-footer-left::before' >/dev/null
printf '%s' "$public_css" | grep -F 'mask: url("/assets/img/logo.svg") center / contain no-repeat;' >/dev/null
printf '%s' "$public_css" | grep -F 'background: rgba(96, 153, 38, 0.14);' >/dev/null
printf '%s' "$public_css" | grep -F 'grid-template-columns: auto minmax(0, 1fr) auto;' >/dev/null
printf '%s' "$public_css" | grep -F 'justify-self: center;' >/dev/null
printf '%s' "$public_css" | grep -F '.trueog-public-pagination' >/dev/null
printf '%s' "$public_css" | grep -F '.trueog-public-filter[aria-checked="true"] .trueog-public-filter-box' >/dev/null
printf '%s' "$public_css" | grep -F 'color: #131416;' >/dev/null
printf '%s' "$public_css" | grep -F '[hidden]' >/dev/null
printf '%s' "$public_css" | grep -F '.trueog-public-nav-authenticated' >/dev/null
printf '%s' "$public_css" | grep -F '.trueog-auth-pending .trueog-public-nav-left' >/dev/null
printf '%s' "$public_css" | grep -F '.trueog-public-menu-panel' >/dev/null
printf '%s' "$public_css" | grep -F '.trueog-public-submit span' >/dev/null
printf '%s' "$public_css" | grep -F 'fill: currentColor;' >/dev/null
curl -fsS http://127.0.0.1:3000/assets/licenses.txt | grep -F 'Monocraft - SIL Open Font License 1.1' >/dev/null
if curl -fsS http://127.0.0.1:3000/ | grep -F 'Monocraft license' >/dev/null; then
	echo "footer still contains a dedicated Monocraft license link" >&2
	exit 1
fi

# Install the reviewed reverse-proxy configuration only after all static pages exist. On any syntax
# or reload failure, restore the previous configuration and reload it before aborting.
NGINX_CONFIG=/etc/nginx/sites-available/gitea.conf
NGINX_SNIPPET=/etc/nginx/snippets/gitea-public-page-headers.conf
nginx_backup=/var/backups/nginx/gitea-public-pages-$(date '+%Y-%m-%d_%H-%M-%S')
install -d -m 700 -o root -g root "$nginx_backup"
cp -p "$NGINX_CONFIG" "$nginx_backup/gitea.conf"
snippet_existed=0
if [ -e "$NGINX_SNIPPET" ]; then
	snippet_existed=1
	cp -p "$NGINX_SNIPPET" "$nginx_backup/gitea-public-page-headers.conf"
fi
restore_nginx() {
	install -m 644 -o root -g root "$nginx_backup/gitea.conf" "$NGINX_CONFIG"
	if [ "$snippet_existed" -eq 1 ]; then
		install -m 644 -o root -g root "$nginx_backup/gitea-public-page-headers.conf" "$NGINX_SNIPPET"
	else
		rm -f "$NGINX_SNIPPET"
	fi
	nginx -t
	rc-service nginx reload
}
install -m 644 -o root -g root /home/system/gitea-upgrade/gitea.nginx.conf "$NGINX_CONFIG"
install -m 644 -o root -g root /home/system/gitea-upgrade/gitea-public-page-headers.nginx "$NGINX_SNIPPET"
if ! nginx -t; then
	echo "new Nginx configuration failed validation; restoring previous files" >&2
	restore_nginx
	exit 1
fi
if ! rc-service nginx reload; then
	echo "Nginx reload failed; restoring previous files" >&2
	restore_nginx
	exit 1
fi
echo "installed public Gitea routes; Nginx backup: $nginx_backup"

origin='https://git.trueog.net'
verify_public_routes() {
	bare_pulls_headers=$(curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -sS -D - -o /dev/null "$origin/pulls" | tr -d '\r') || return 1
	printf '%s' "$bare_pulls_headers" | grep -Eq '^HTTP/[0-9.]+ 30[23] ' || return 1
	printf '%s' "$bare_pulls_headers" | grep -iE '^location: .*/user/login' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/pulls?state=all" | grep -F '<h1>All pull requests</h1>' >/dev/null || return 1
	if [ -f "$PUBLIC_DST/assets/html/trueog-pulls-all-page-2.html" ]; then
		curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/pulls?state=all&page=2" | grep -F 'aria-current="page">2</a>' >/dev/null || return 1
	fi
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/pulls?state=open" | grep -F '<h1>Open pull requests</h1>' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/pulls?state=open" | grep -F 'role="checkbox" aria-checked="false" href="/pulls?state=open&amp;personal=hide"' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/pulls?state=open&personal=hide" | grep -F 'role="checkbox" aria-checked="true" href="/pulls?state=open"' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/pulls?state=all&personal=hide" | grep -F 'role="checkbox" aria-checked="true" href="/pulls?state=all"' >/dev/null || return 1
	bare_issues_headers=$(curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -sS -D - -o /dev/null "$origin/issues" | tr -d '\r') || return 1
	printf '%s' "$bare_issues_headers" | grep -Eq '^HTTP/[0-9.]+ 30[23] ' || return 1
	printf '%s' "$bare_issues_headers" | grep -iE '^location: .*/user/login' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/issues?state=all" | grep -F '<h1>All issues</h1>' >/dev/null || return 1
	if [ -f "$PUBLIC_DST/assets/html/trueog-issues-all-page-2.html" ]; then
		curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/issues?state=all&page=2" | grep -F 'aria-current="page">2</a>' >/dev/null || return 1
	fi
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/issues?state=open" | grep -F '<h1>Open issues</h1>' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/issues?state=open" | grep -F 'role="checkbox" aria-checked="false" href="/issues?state=open&amp;personal=hide"' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/issues?state=open&personal=hide" | grep -F 'role="checkbox" aria-checked="true" href="/issues?state=open"' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -D - -o /dev/null "$origin/issues?state=open" | tr -d '\r' | grep -iF "content-security-policy: default-src 'none'; script-src 'self'; connect-src 'self'" >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/contribute/pull-request" | grep -F '<span>Pull request / fork</span>' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/contribute/bug-report" | grep -F '<span>File bug report</span>' >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -D - -o /dev/null "$origin/pulls?state=open" | tr -d '\r' | grep -iF "content-security-policy: default-src 'none'; script-src 'self'; connect-src 'self'" >/dev/null || return 1
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS "$origin/-/trueog-divergence?fork=trueog/MyWorlds&branch=master&base=upstream/MyWorlds&base_branch=master" | grep -Eq '"ahead":[0-9]+' || return 1
	cmp /home/system/gitea-upgrade/gitea.nginx.conf "$NGINX_CONFIG" || return 1
	cmp /home/system/gitea-upgrade/gitea-public-page-headers.nginx "$NGINX_SNIPPET" || return 1
}
routes_verified=0
n=0
# A graceful Nginx reload can leave an old worker answering a local TLS connection for a moment.
# Retry the complete route/header/parity check so that brief worker drain time is not mistaken for
# a bad configuration. Persistent failures still restore the previous files.
while [ "$n" -lt 15 ]; do
	if verify_public_routes; then
		routes_verified=1
		break
	fi
	n=$((n + 1))
	sleep 1
done
if [ "$routes_verified" -ne 1 ]; then
	echo "new public routes failed local TLS verification; restoring previous Nginx files" >&2
	restore_nginx
	exit 1
fi
# Only TrueOG's landing content is checked; Gitea's own scripts come after its page footer.
if curl -fsS http://127.0.0.1:3000/ | sed -n '/class="page-content trueog-home"/,/class="page-footer"/p' | grep -F '<script' >/dev/null; then
	echo "homepage body contains a <script>; the homepage must run no JavaScript" >&2
	exit 1
fi
curl -fsS http://127.0.0.1:3000/ | grep -F 'class="trueog-glyphs"' >/dev/null
curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/assets/img/trueog-sga.svg | grep -Fx 404 >/dev/null
nav_css=$(curl -fsS http://127.0.0.1:3000/assets/css/trueog-nav.css?v=13)
printf '%s' "$nav_css" | grep -F '.trueog-nav-dashboard' >/dev/null
printf '%s' "$nav_css" | grep -F ':has(> .trueog-nav-dashboard) > #navbar-logo' >/dev/null
printf '%s' "$nav_css" | grep -F ':has(> .trueog-nav-dashboard) > a.item:not(.trueog-nav-home)' >/dev/null
printf '%s' "$nav_css" | grep -F '.trueog-nav-home-lambda' >/dev/null
printf '%s' "$nav_css" | grep -F 'transform: translateX(calc(1em / 18));' >/dev/null
printf '%s' "$nav_css" | grep -F 'content: "ad astra per aspera";' >/dev/null
printf '%s' "$nav_css" | grep -F 'grid-template-columns: auto minmax(0, 1fr) auto;' >/dev/null
printf '%s' "$nav_css" | grep -F 'background: rgba(96, 153, 38, 0.14);' >/dev/null
printf '%s' "$nav_css" | grep -F 'color: light-dark(#4a7a1d, #78b542);' >/dev/null
printf '%s' "$nav_css" | grep -F 'background-color: light-dark(rgb(0 0 0 / 0.75), transparent);' >/dev/null
printf '%s' "$nav_css" | grep -F 'background-color: rgba(0, 0, 0, 0.75);' >/dev/null
printf '%s' "$nav_css" | grep -F '.page-footer .left-links strong a {' >/dev/null
printf '%s' "$nav_css" | grep -F '.page-footer .right-links > a {' >/dev/null
# The footer's version number is wrapped in <strong> (base/footer_content.tmpl) so it can be green.
curl -fsS http://127.0.0.1:3000/explore/repos | tr -d '\n\t' | grep -F 'Version:<strong>' >/dev/null
printf '%s' "$nav_css" | grep -F 'color: #55ffff;' >/dev/null
printf '%s' "$nav_css" | grep -F 'text-shadow: 0.1em 0.1em 0 #153f3f;' >/dev/null
printf '%s' "$nav_css" | grep -F '.page-footer .right-links > .ui.dropdown > .flex-text-inline,' >/dev/null
printf '%s' "$nav_css" | grep -F '.page-footer .left-links > a[target="_blank"][href^="https://about.gitea.com"]::before' >/dev/null
printf '%s' "$nav_css" | grep -F 'mask: url("/assets/img/logo.svg") center / contain no-repeat;' >/dev/null
curl -fsS http://127.0.0.1:3000/assets/js/trueog-global.js?v=1 | grep -F 'Required approval team: Admins.' >/dev/null
if curl -fsS http://127.0.0.1:3000/ | grep -F 'trueog-tagline' >/dev/null; then
	echo "homepage still contains the retired banner tagline" >&2
	exit 1
fi
curl -fsS http://127.0.0.1:3000/user/login | grep -F 'trueog-nav.css?v=13' >/dev/null
curl -fsS http://127.0.0.1:3000/user/login | grep -oE 'Sign in (as|with) [A-Za-z]+' | sort -u
echo "homepage and TrueOG branding verified; one gitea process running"
