#!/bin/sh
# Reusable Dockerless Gitea binary upgrade for TrueOG's OpenRC deployment.
#
#   doas sh /home/system/gitea-upgrade/upgrade-gitea.sh check    28.2.0
#   doas sh /home/system/gitea-upgrade/upgrade-gitea.sh apply    28.2.0
#   doas sh /home/system/gitea-upgrade/upgrade-gitea.sh rollback 28.2.0
#
# The target binary, .sha256 and .asc must already be in /home/system/gitea-upgrade. The detached
# signature must validate under the system user's keyring to Gitea's Teabot primary key.
set -eu

SRC=/home/system/gitea-upgrade
APP_INI=/var/lib/gitea/custom/conf/app.ini
CUSTOM=/opt/gitea/custom
SIGNING_KEY=/opt/gitea/custom/conf/gitea-signing-key
SIGNING_KEY_PUB=$SIGNING_KEY.pub
BACKUP_ROOT=/var/backups/gitea
TEABOT_PRIMARY_FPR=7C9E68152594688862D62AF62D9AE806EC1592E2
PHASE=${1:-}
TARGET=${2:-}

case "$PHASE" in check|apply|rollback) ;; *) echo "usage: $0 check|apply|rollback <version>" >&2; exit 2;; esac
case "$TARGET" in ''|*[!0-9.]*|.*|*.) echo "invalid target version: $TARGET" >&2; exit 2;; esac

BIN="$SRC/gitea-$TARGET-linux-amd64"
SHA_FILE="$BIN.sha256"
ASC_FILE="$BIN.asc"
STATE="$BACKUP_ROOT/upgrade-$TARGET.state"
export GITEA_WORK_DIR=/opt/gitea GITEA_CUSTOM=$CUSTOM

[ "$(id -u)" = 0 ] || { echo "run as root: doas sh $0 $PHASE $TARGET" >&2; exit 1; }
[ -r "$APP_INI" ] || { echo "cannot read $APP_INI" >&2; exit 1; }

tmp_dir=
cleanup() {
	[ -z "$tmp_dir" ] || { [ ! -d "$tmp_dir" ] || rm -r "$tmp_dir"; }
}
trap cleanup 0 1 2 15

say() { printf '\n== %s ==\n' "$1"; }
running_version() {
	curl -fsS -m 5 http://127.0.0.1:3000/api/v1/version 2>/dev/null |
		sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}
as_gitea() {
	su -s /bin/sh gitea -c "GITEA_WORK_DIR=/opt/gitea GITEA_CUSTOM=$CUSTOM HOME=/var/lib/gitea USER=gitea $*"
}
db_name() {
	awk -F= '/^\[database\]/{s=1;next} /^\[/{s=0} s && $1 ~ /^[[:space:]]*NAME[[:space:]]*$/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$APP_INI"
}
wait_up() {
	i=0
	while [ "$i" -lt 120 ]; do
		version=$(running_version || true)
		[ -z "$version" ] || { echo "  up: $version"; return 0; }
		sleep 1
		i=$((i + 1))
	done
	echo "Gitea did not become ready in 120 seconds; inspect /var/log/gitea/stdout.log" >&2
	return 1
}
start_openrc_detached() {
	# The automation runner may reap a supervisor started in its own process tree after the command
	# returns. A new session makes supervise-daemon a child of init, matching a normal host shell.
	setsid -f /bin/sh -c 'rc-service gitea start >>/var/log/gitea/openrc-detached-start.log 2>&1'
	wait_up
	i=0
	while ! pgrep -f '^supervise-daemon gitea ' >/dev/null; do
		[ "$i" -lt 15 ] || { echo "OpenRC supervisor did not remain running" >&2; return 1; }
		sleep 1
		i=$((i + 1))
	done
}
hard_stop() {
	# supervise-daemon can lose its control process while Gitea remains alive. Stop through OpenRC,
	# then gracefully terminate only an orphan owned by the dedicated gitea account.
	rc-service gitea stop || true
	if pgrep -u gitea -x gitea >/dev/null; then
		echo "  stopping orphaned gitea process"
		pkill -TERM -u gitea -x gitea
	fi
	i=0
	while pgrep -u gitea -x gitea >/dev/null; do
		[ "$i" -lt 30 ] || { echo "Gitea did not stop after 30 seconds" >&2; return 1; }
		sleep 1
		i=$((i + 1))
	done
	rc-service gitea zap >/dev/null 2>&1 || true
	rm -f /run/gitea.pid
}
verify_artifacts() {
	[ -x "$BIN" ] || { echo "missing executable $BIN" >&2; return 1; }
	[ -r "$SHA_FILE" ] || { echo "missing $SHA_FILE" >&2; return 1; }
	[ -r "$ASC_FILE" ] || { echo "missing $ASC_FILE" >&2; return 1; }
	(cd "$SRC" && sha256sum -c "$(basename "$SHA_FILE")")
	tmp_dir=${tmp_dir:-$(mktemp -d /tmp/trueog-gitea-upgrade.XXXXXX)}
	if ! runuser -u system -- gpg --batch --status-fd 1 --verify "$ASC_FILE" "$BIN" \
		>"$tmp_dir/gpg-status" 2>"$tmp_dir/gpg-message"; then
		cat "$tmp_dir/gpg-message" >&2
		return 1
	fi
	if ! grep -Eq "^\[GNUPG:\] VALIDSIG [A-F0-9]+ .* $TEABOT_PRIMARY_FPR$" "$tmp_dir/gpg-status"; then
		echo "signature is valid but not rooted in expected Teabot key $TEABOT_PRIMARY_FPR" >&2
		return 1
	fi
	echo "detached signature: valid Teabot signature"
}
template_compatibility() {
	current_bin=/opt/gitea/current/gitea
	[ -x "$current_bin" ] || { echo "missing current binary" >&2; return 1; }
	tmp_dir=${tmp_dir:-$(mktemp -d /tmp/trueog-gitea-upgrade.XXXXXX)}
	for template in templates/home.tmpl templates/user/auth/external_auth_methods.tmpl \
		templates/user/auth/signin.tmpl templates/user/dashboard/dashboard.tmpl \
		templates/repo/code/upstream_diverging_info.tmpl templates/status/404.tmpl \
		templates/base/footer_content.tmpl; do
		name=$(printf '%s' "$template" | tr / _)
		runuser -u system -- /usr/bin/env -u GITEA_WORK_DIR -u GITEA_CUSTOM \
			"$current_bin" embedded view "$template" >"$tmp_dir/current-$name"
		runuser -u system -- /usr/bin/env -u GITEA_WORK_DIR -u GITEA_CUSTOM \
			"$BIN" embedded view "$template" >"$tmp_dir/target-$name"
		if ! cmp -s "$tmp_dir/current-$name" "$tmp_dir/target-$name"; then
			echo "BLOCKER: upstream template changed: $template" >&2
			diff -u "$tmp_dir/current-$name" "$tmp_dir/target-$name" >&2 || true
			echo "Review and update the TrueOG override before applying the upgrade." >&2
			return 1
		fi
		echo "upstream template unchanged: $template"
	done
	runuser -u system -- /usr/bin/env -u GITEA_WORK_DIR -u GITEA_CUSTOM \
		"$BIN" embedded list >"$tmp_dir/embedded-list"
	if ! grep -Fxq templates/custom/header.tmpl "$tmp_dir/embedded-list"; then
		echo "BLOCKER: target removed templates/custom/header.tmpl" >&2
		return 1
	fi
	if ! grep -Fxq templates/custom/extra_links_footer.tmpl "$tmp_dir/embedded-list"; then
		echo "BLOCKER: target removed templates/custom/extra_links_footer.tmpl" >&2
		return 1
	fi
	if ! grep -Fxq templates/custom/extra_links.tmpl "$tmp_dir/embedded-list"; then
		echo "BLOCKER: target removed templates/custom/extra_links.tmpl (navbar Home link)" >&2
		return 1
	fi
	runuser -u system -- /usr/bin/env -u GITEA_WORK_DIR -u GITEA_CUSTOM \
		"$BIN" embedded view templates/base/head_navbar.tmpl >"$tmp_dir/target-head-navbar"
	if ! grep -Fq 'data-signed-in-username="{{.SignedUser.Name}}"' "$tmp_dir/target-head-navbar" || \
		! grep -Fq 'class="navbar-avatar"' "$tmp_dir/target-head-navbar" || \
		! grep -Fq 'href="{{AppSubUrl}}/-/admin"' "$tmp_dir/target-head-navbar"; then
		echo "BLOCKER: target navbar no longer exposes the signed-in marker/avatar/admin hooks used by TrueOG public pages" >&2
		return 1
	fi
	echo "custom header, navbar and footer hooks: present"
}
custom_source_parity() {
	tmp_dir=${tmp_dir:-$(mktemp -d /tmp/trueog-gitea-upgrade.XXXXXX)}
	find "$SRC/custom-templates" -type f -name '*.tmpl' >"$tmp_dir/template-files"
	find "$SRC/custom-public" -type f >"$tmp_dir/public-files"
	status=0
	while IFS= read -r source; do
		rel=${source#"$SRC/custom-templates"/}
		if [ "$rel" = custom/header.tmpl ]; then
			source="$SRC/custom-templates/trueog/header_hook.tmpl"
		fi
		if [ "$rel" = custom/extra_links_footer.tmpl ]; then
			source="$SRC/custom-templates/trueog/footer_hook.tmpl"
		fi
		if ! cmp -s "$source" "$CUSTOM/templates/$rel"; then
			echo "BLOCKER: source/live template mismatch: $rel" >&2
			status=1
		fi
	done <"$tmp_dir/template-files"
	while IFS= read -r source; do
		rel=${source#"$SRC/custom-public"/}
		if ! cmp -s "$source" "$CUSTOM/public/$rel"; then
			echo "BLOCKER: source/live public asset mismatch: $rel" >&2
			status=1
		fi
	done <"$tmp_dir/public-files"
	[ "$status" -eq 0 ] || return 1
	echo "custom source and live files: identical"
}
# TrueOG pieces installed outside /opt/gitea by install-custom-templates.sh. An upgrade does not touch
# them, so this only confirms they are still installed and current (see UPGRADE.md, "TrueOG
# customizations to preserve").
system_customizations() {
	status=0
	for pair in gitea-homepage-stats:/usr/local/sbin/gitea-homepage-stats \
		gitea-homepage-stats.cron:/etc/cron.d/gitea-homepage-stats \
		gitea-public-pages.py:/usr/local/sbin/gitea-public-pages \
		gitea-public-pages.cron:/etc/cron.d/gitea-public-pages \
		gitea-license-bundle:/usr/local/sbin/gitea-license-bundle \
		monocraft.LICENSE:/usr/local/share/licenses/monocraft/OFL-1.1.txt \
		gitea.nginx.conf:/etc/nginx/sites-available/gitea.conf \
		gitea-public-page-headers.nginx:/etc/nginx/snippets/gitea-public-page-headers.conf \
		gitea.logrotate:/etc/logrotate.d/gitea \
		trueog-divergence.py:/usr/local/sbin/trueog-divergence \
		trueog-divergence.initd:/etc/init.d/trueog-divergence; do
		if ! cmp -s "$SRC/${pair%%:*}" "${pair#*:}"; then
			echo "BLOCKER: ${pair#*:} is missing or differs from $SRC/${pair%%:*}; run install-custom-templates.sh" >&2
			status=1
		fi
	done
	[ "$status" -eq 0 ] || return 1
	echo "homepage jobs, public-page proxy configuration, and Gitea log rotation: installed and identical to source"
}
verify_signing_files() {
	[ -r "$SIGNING_KEY" ] || { echo "missing Gitea server signing key" >&2; return 1; }
	[ -r "$SIGNING_KEY_PUB" ] || { echo "missing Gitea server signing public key" >&2; return 1; }
	[ "$(stat -c '%U:%G %a' "$SIGNING_KEY")" = 'gitea:gitea 600' ] || {
		echo "Gitea private signing key ownership/mode is not gitea:gitea 600" >&2
		return 1
	}
	private_public=$(ssh-keygen -y -f "$SIGNING_KEY" | awk 'NR == 1 { print $1 " " $2 }')
	configured_public=$(awk 'NR == 1 { print $1 " " $2 }' "$SIGNING_KEY_PUB")
	[ "$private_public" = "$configured_public" ] || {
		echo "Gitea signing keypair does not match" >&2
		return 1
	}
	grep -Fqx "SIGNING_KEY = $SIGNING_KEY_PUB" "$APP_INI"
	grep -Fqx 'SIGNING_FORMAT = ssh' "$APP_INI"
	grep -Fqx 'INITIAL_COMMIT = always' "$APP_INI"
	grep -Fqx 'CRUD_ACTIONS = always' "$APP_INI"
	grep -Fqx 'WIKI = always' "$APP_INI"
	grep -Fqx 'MERGES = always' "$APP_INI"
	echo "Gitea SSH signing key and always-sign policy: verified"
}
verify_signing_live() {
	verify_signing_files
	served=$(curl -fsS -m 10 http://127.0.0.1:3000/api/v1/signing-key.pub |
		awk 'NR == 1 { print $1 " " $2 }')
	configured=$(awk 'NR == 1 { print $1 " " $2 }' "$SIGNING_KEY_PUB")
	[ "$served" = "$configured" ] || {
		echo "live Gitea signing-key API does not match configured key" >&2
		return 1
	}
	echo "live Gitea signing-key API: verified"
}
install_customizations() {
	find "$SRC/custom-templates" -type f -name '*.tmpl' | while IFS= read -r source; do
		rel=${source#"$SRC/custom-templates"/}
		[ "$rel" != custom/extra_links_footer.tmpl ] || continue
		[ "$rel" != custom/header.tmpl ] || continue
		install -D -m 640 -o gitea -g gitea "$source" "$CUSTOM/templates/$rel"
	done
	install -m 640 -o gitea -g gitea "$SRC/custom-templates/trueog/header_hook.tmpl" "$CUSTOM/templates/custom/header.tmpl"
	install -m 640 -o gitea -g gitea "$SRC/custom-templates/trueog/footer_hook.tmpl" "$CUSTOM/templates/custom/extra_links_footer.tmpl"
	find "$SRC/custom-public" -type f | while IFS= read -r source; do
		rel=${source#"$SRC/custom-public"/}
		install -D -m 644 -o gitea -g gitea "$source" "$CUSTOM/public/$rel"
	done
	# Keep retired canonical files from surviving an upgrade merely because customization installs
	# are additive. The manifest names are included because Gitea reserves site-manifest.json and
	# serves its generated response ahead of a same-named custom public file.
	for rel in public/assets/img/trueog-galaxy.jpg public/assets/img/trueog-sga.svg public/assets/site-manifest.json public/assets/trueog-manifest.webmanifest templates/trueog/hero_code.tmpl templates/trueog/banner.tmpl; do
		case $rel in
		public/*) source=$SRC/custom-public/${rel#public/} ;;
		templates/*) source=$SRC/custom-templates/${rel#templates/} ;;
		*) echo "unknown retired path $rel" >&2; return 1 ;;
		esac
		[ ! -e "$source" ] || continue
		rm -f "$CUSTOM/$rel"
	done
}
# The fork banner's count service must stay enabled and supervised (see UPGRADE.md).
verify_divergence_service() {
	rc-update show default | grep -Eq '(^|[[:space:]])trueog-divergence([[:space:]]|$)' || {
		echo "BLOCKER: trueog-divergence is not enabled in OpenRC's default runlevel; run install-custom-templates.sh" >&2
		return 1
	}
	rc-service trueog-divergence status >/dev/null 2>&1 || {
		echo "BLOCKER: trueog-divergence is not started under OpenRC" >&2
		return 1
	}
	pgrep -f '^supervise-daemon trueog-divergence ' >/dev/null || {
		echo "BLOCKER: trueog-divergence has no supervise-daemon" >&2
		return 1
	}
	# A real count for a known public pair (directly, not through Nginx's rate limit).
	curl -fsS -m 30 'http://127.0.0.1:3992/-/trueog-divergence?fork=trueog/MyWorlds&branch=master&base=upstream/MyWorlds&base_branch=master' |
		grep -Eq '^\{"ahead":[0-9]+,"behind":[0-9]+\}$' || {
		echo "BLOCKER: trueog-divergence does not return counts for trueog/MyWorlds" >&2
		return 1
	}
	# The running process must be the installed code: its version header is a hash of its own file.
	want=$(sha256sum /usr/local/sbin/trueog-divergence | cut -c1-16)
	got=$(curl -fsS -m 30 -D - -o /dev/null 'http://127.0.0.1:3992/-/trueog-divergence?fork=trueog/MyWorlds&branch=master&base=upstream/MyWorlds&base_branch=master' |
		tr -d '\r' | awk -F': ' 'tolower($1) == "x-trueog-divergence-version" { print $2 }')
	[ "$got" = "$want" ] || {
		echo "BLOCKER: the running trueog-divergence ($got) is not the installed code ($want); run install-custom-templates.sh" >&2
		return 1
	}
	# And it refuses reflog syntax.
	[ "$(curl -s -o /dev/null -w '%{http_code}' -m 30 'http://127.0.0.1:3992/-/trueog-divergence?fork=trueog/MyWorlds&branch=master%40%7B1%7D&base=upstream/MyWorlds&base_branch=master')" = 400 ] || {
		echo "BLOCKER: the running trueog-divergence accepts reflog syntax (stale process); run install-custom-templates.sh" >&2
		return 1
	}
}
verify_site() {
	expected=$1
	actual=$(running_version)
	[ "$actual" = "$expected" ] || { echo "running $actual, expected $expected" >&2; return 1; }
	count=$(pgrep -u gitea -x gitea | wc -l)
	[ "$count" -eq 1 ] || { echo "expected one Gitea process, found $count" >&2; return 1; }
	home=$(curl -fsS -m 10 http://127.0.0.1:3000/)
	printf '%s' "$home" | grep -Fq 'trueog-home.css?v=39'
	printf '%s' "$home" | grep -Fq 'GitHub mirror'
	printf '%s' "$home" | grep -Fq 'class="ui button trueog-pr" href="/contribute/pull-request"'
	printf '%s' "$home" | grep -Fq '<span class="trueog-action-label">Pull request / fork</span>'
	printf '%s' "$home" | grep -Fq 'class="ui button trueog-bug" href="/contribute/bug-report"'
	printf '%s' "$home" | grep -Fq 'trueog-nav-home'
	printf '%s' "$home" | grep -Fq 'class="trueog-nav-home-lambda" aria-hidden="true">λ</span>'
	grep -Fq '{{$landingURL = print AppSubUrl "/?home=1"}}' "$SRC/custom-templates/custom/extra_links.tmpl"
	grep -Fq '<a class="item trueog-nav-dashboard' "$SRC/custom-templates/custom/extra_links.tmpl"
	grep -Fq 'href="{{$dashboardURL}}"' "$SRC/custom-templates/custom/extra_links.tmpl"
	printf '%s' "$home" | grep -Fq '/assets/img/favicon.png?v=1'
	printf '%s' "$home" | grep -Fq '/assets/img/favicon.ico?v=1'
	printf '%s' "$home" | grep -Fq '/assets/img/apple-touch-icon.png?v=1'
	printf '%s' "$home" | grep -Fq '/assets/trueog-manifest.json?v=1'
	printf '%s' "$home" | grep -Fq '/assets/browserconfig.xml?v=1'
	printf '%s' "$home" | grep -Fq 'trueog-nav.css?v=13'
	printf '%s' "$home" | grep -Fq 'trueog-global.css?v=2'
	if printf '%s' "$home" | grep -Eq '/assets/(js|scripts)/trueog'; then
		echo "the landing page loads TrueOG JavaScript" >&2
		return 1
	fi
	curl -fsS -m 10 http://127.0.0.1:3000/trueog/true-og | grep -Fq 'trueog-global.js?v=1'
	if printf '%s' "$home" | grep -Fq 'trueog-card-line'; then
		echo "homepage card copy still contains forced line spans" >&2
		return 1
	fi
	for tier in xs sm md lg; do
		[ "$(printf '%s' "$home" | grep -o "trueog-card-copy-$tier" | wc -l)" -eq 5 ] || {
			echo "homepage must contain five responsive $tier card-copy variants" >&2
			return 1
		}
	done
	printf '%s' "$home" | grep -Fq 'Learn how to contribute code or maps to TrueOG Network.'
	printf '%s' "$home" | grep -Fq 'Our custom fork of Purpur runs MCJE 1.19.4'
	printf '%s' "$home" | grep -Fq 'Everything behind TrueOG is public and available to everyone, forever'
	printf '%s' "$home" | grep -Fq 'Chat with the TrueOG community, get assistance in #plugin-help, and see what we'
	printf '%s' "$home" | grep -Fq 'Read-only GitHub mirrors automatically receive'
	if printf '%s' "$home" | grep -Fq 'Monocraft license'; then
		echo "footer still contains a dedicated Monocraft license link" >&2
		return 1
	fi
	printf '%s' "$home" | grep -Fq 'trueog-stats.css?t='
	# TrueOG rule: the landing page runs no JavaScript of TrueOG's own (Gitea's scripts follow the footer).
	if printf '%s' "$home" | sed -n '/class="page-content trueog-home"/,/class="page-footer"/p' | grep -Fq '<script'; then
		echo "homepage body contains a <script>; the homepage must run no JavaScript" >&2
		return 1
	fi
	curl -fsS -m 10 http://127.0.0.1:3000/assets/css/trueog-stats.css | grep -Fq '.trueog-stat-repos::before'
	home_css=$(curl -fsS -m 10 http://127.0.0.1:3000/assets/css/trueog-home.css?v=39)
	printf '%s' "$home_css" | grep -Fq '.page-content.trueog-home:not(.trueog-signin)'
	printf '%s' "$home_css" | grep -Fq 'grid-auto-rows: 1fr;'
	printf '%s' "$home_css" | grep -Fq 'margin: 0 0 1rem;'
	printf '%s' "$home_css" | grep -Fq '.trueog-hero > .trueog-title-row + .trueog-actions {'
	printf '%s' "$home_css" | grep -Fq 'margin-top: 2rem;'
	printf '%s' "$home_css" | grep -Fq 'grid-template-columns: 1.25em minmax(0, 1fr);'
	printf '%s' "$home_css" | grep -Fq 'grid-template-columns: repeat(3, minmax(max-content, 1fr));'
	printf '%s' "$home_css" | grep -Fq 'font-size: min(0.9rem, (100cqi - 1rem) / 16.9);'
	printf '%s' "$home_css" | grep -Fq 'fill: #609926; /* upstream Gitea brand green */'
	printf '%s' "$home_css" | grep -Fq 'color: light-dark(#4d7f1e, #78b542);'
	printf '%s' "$home_css" | grep -Fq 'animation: trueog-fall calc(var(--t) + 4s)'
	printf '%s' "$home_css" | grep -Fq '@media (forced-colors: active)'
	printf '%s' "$home_css" | grep -Fq '@media (prefers-contrast: more)'
	printf '%s' "$home_css" | grep -Fq 'opacity: calc(var(--o) * 0.35);'
	if printf '%s' "$home_css" | grep -Fq '@media (prefers-contrast: more), (forced-colors: active)'; then
		echo "homepage stylesheet still hides contrast-preference glyphs with the retired combined query" >&2
		return 1
	fi
	printf '%s' "$home_css" | grep -Fq -- '-webkit-line-clamp: 3;'
	printf '%s' "$home_css" | grep -Fq 'height: calc(3 * 1.55em);'
	printf '%s' "$home_css" | grep -Fq 'container-type: inline-size;'
	printf '%s' "$home_css" | grep -Fq '@container (min-width: 500px)'
	printf '%s' "$home_css" | grep -Fq '.trueog-actions a.ui.button:visited'
	printf '%s' "$home_css" | grep -Fq '.trueog-actions a.ui.button:hover'
	printf '%s' "$home_css" | grep -Fq '.trueog-signin-box .ui.button:active'
	printf '%s' "$home_css" | grep -Fq '.trueog-signin-box .ui.button .svg'
	printf '%s' "$home_css" | grep -Fq 'color: inherit;'
	printf '%s' "$home_css" | grep -Fq '.trueog-action-icon .svg'
	printf '%s' "$home" | grep -Fq 'class="trueog-action-icon"'
	if printf '%s' "$home_css" | grep -Fq '.trueog-hero::before'; then
		echo "homepage stylesheet still contains the retired hero clearing" >&2
		return 1
	fi
	if printf '%s' "$home" | grep -Fq 'trueog-tagline'; then
		echo "homepage still contains the retired banner tagline" >&2
		return 1
	fi
	nav_css=$(curl -fsS -m 10 http://127.0.0.1:3000/assets/css/trueog-nav.css?v=13)
	printf '%s' "$nav_css" | grep -Fq '.trueog-nav-dashboard'
	printf '%s' "$nav_css" | grep -Fq ':has(> .trueog-nav-dashboard) > #navbar-logo'
	printf '%s' "$nav_css" | grep -Fq ':has(> .trueog-nav-dashboard) > a.item:not(.trueog-nav-home)'
	printf '%s' "$nav_css" | grep -Fq '.trueog-nav-home-lambda'
	printf '%s' "$nav_css" | grep -Fq 'transform: translateX(calc(1em / 18));'
	printf '%s' "$nav_css" | grep -Fq 'content: "ad astra per aspera";'
	printf '%s' "$nav_css" | grep -Fq 'grid-template-columns: auto minmax(0, 1fr) auto;'
	printf '%s' "$nav_css" | grep -Fq 'background: rgba(96, 153, 38, 0.14);'
	printf '%s' "$nav_css" | grep -Fq 'color: light-dark(#4a7a1d, #78b542);'
	printf '%s' "$nav_css" | grep -Fq 'background-color: light-dark(rgb(0 0 0 / 0.75), transparent);'
	printf '%s' "$nav_css" | grep -Fq 'background-color: rgba(0, 0, 0, 0.75);'
	printf '%s' "$nav_css" | grep -Fq '.page-footer .left-links strong a {'
	printf '%s' "$nav_css" | grep -Fq '.page-footer .right-links > a {'
	curl -fsS -m 10 http://127.0.0.1:3000/explore/repos | tr -d '\n\t' | grep -Fq 'Version:<strong>'
	printf '%s' "$nav_css" | grep -Fq 'color: #55ffff;'
	printf '%s' "$nav_css" | grep -Fq 'text-shadow: 0.1em 0.1em 0 #153f3f;'
	printf '%s' "$nav_css" | grep -Fq '.page-footer .right-links > .ui.dropdown > .flex-text-inline,'
	printf '%s' "$nav_css" | grep -Fq '.page-footer .left-links > a[target="_blank"][href^="https://about.gitea.com"]::before'
	printf '%s' "$nav_css" | grep -Fq 'mask: url("/assets/img/logo.svg") center / contain no-repeat;'
	curl -fsS -m 10 http://127.0.0.1:3000/assets/css/trueog-global.css?v=2 | grep -Fq 'trueog-logo.png?v=1'
	curl -fsS -m 10 http://127.0.0.1:3000/assets/js/trueog-global.js?v=1 | grep -Fq 'Required approval team: Admins.'
	login=$(curl -fsS -m 10 http://127.0.0.1:3000/user/login)
	printf '%s' "$login" | grep -Fq 'Sign in as staff'
	printf '%s' "$login" | grep -Fq 'Sign in with GitHub'
	printf '%s' "$login" | grep -Fq 'class="trueog-signin-box"'
	if printf '%s' "$login" | grep -Eq '/assets/(js|scripts)/trueog'; then
		echo "the sign-in page loads TrueOG JavaScript" >&2
		return 1
	fi
	printf '%s' "$login" | grep -Fq 'trueog-nav.css?v=13'
	# Each pull and issue view exists twice: complete (trueog-pulls-*, trueog-issues-*) and with personal
	# repositories hidden (trueog-*-org-*, served for personal=hide). Each variant's checkbox must report
	# its own state. Issue lists may legitimately be empty; the pull lists may not.
	for prefix in trueog-pulls- trueog-pulls-org- trueog-issues- trueog-issues-org-; do
		case "$prefix" in *-org-) filter_checked=true ;; *) filter_checked=false ;; esac
		for page in "${prefix}open.html" "${prefix}closed.html"; do
			page_body=$(curl -fsS -m 10 "http://127.0.0.1:3000/assets/html/$page")
			printf '%s' "$page_body" | grep -Fq 'trueog-public.css?v=14'
			printf '%s' "$page_body" | grep -Fq 'class="trueog-public-footer-left" href="https://about.gitea.com/">Powered by Gitea</a>'
			printf '%s' "$page_body" | grep -Fq '<script src="/assets/scripts/trueog-public.js?v=7"></script>'
			printf '%s' "$page_body" | grep -Fq "class=\"trueog-public-filter\" role=\"checkbox\" aria-checked=\"$filter_checked\""
			[ "$(printf '%s' "$page_body" | grep -oi '<script' | wc -l)" -eq 1 ] || {
				echo "generated pull list has an unexpected script count: $page" >&2
				return 1
			}
		done
		[ -f "$CUSTOM/public/assets/html/${prefix}all.html" ] || { echo "missing generated ${prefix}all.html" >&2; return 1; }
		all_pull_cards=0
		for page_path in "$CUSTOM/public/assets/html/${prefix}all.html" "$CUSTOM"/public/assets/html/"${prefix}"all-page-*.html; do
			[ -f "$page_path" ] || continue
			page_body=$(curl -fsS -m 10 "http://127.0.0.1:3000/assets/html/${page_path##*/}")
			printf '%s' "$page_body" | grep -Fq 'trueog-public.css?v=14'
			printf '%s' "$page_body" | grep -Fq '<script src="/assets/scripts/trueog-public.js?v=7"></script>'
			printf '%s' "$page_body" | grep -Fq "class=\"trueog-public-filter\" role=\"checkbox\" aria-checked=\"$filter_checked\""
			[ "$(printf '%s' "$page_body" | grep -oi '<script' | wc -l)" -eq 1 ] || {
				echo "generated pull list has an unexpected script count: ${page_path##*/}" >&2
				return 1
			}
			page_cards=$(printf '%s' "$page_body" | grep -o 'class="trueog-public-card"' | wc -l)
			[ "$page_cards" -le 50 ] || { echo "all-pulls page exceeds 50 entries: ${page_path##*/}" >&2; return 1; }
			all_pull_cards=$((all_pull_cards + page_cards))
		done
		case "$prefix" in
		trueog-pulls-*) [ "$all_pull_cards" -gt 0 ] || { echo "generated ${prefix}all pagination is empty" >&2; return 1; } ;;
		*) [ "$all_pull_cards" -gt 0 ] || curl -fsS -m 10 "http://127.0.0.1:3000/assets/html/${prefix}all.html" | grep -Fq 'No issues match this view.' || { echo "generated ${prefix}all.html has neither issues nor the empty notice" >&2; return 1; } ;;
		esac
	done
	for page in trueog-pull-wizard.html trueog-bug-wizard.html; do
		page_body=$(curl -fsS -m 10 "http://127.0.0.1:3000/assets/html/$page")
		printf '%s' "$page_body" | grep -Fq 'trueog-public.css?v=14'
		printf '%s' "$page_body" | grep -Fq 'class="trueog-public-form"'
		printf '%s' "$page_body" | grep -Fq '<select '
		printf '%s' "$page_body" | grep -Fq 'class="trueog-public-heading-icon"'
		printf '%s' "$page_body" | grep -Fq 'aria-label="Navigation Bar"'
		printf '%s' "$page_body" | grep -Fq '<a href="/" aria-label="Home" data-public-home><span class="trueog-public-home-lambda" aria-hidden="true">λ</span></a>'
		printf '%s' "$page_body" | grep -Fq '<a href="/" data-public-auth hidden>Dashboard</a>'
		printf '%s' "$page_body" | grep -Fq '<a href="/pulls" data-public-auth hidden>Pull Requests</a>'
		printf '%s' "$page_body" | grep -Fq 'class="trueog-public-menu trueog-public-profile-menu" data-public-auth hidden'
		printf '%s' "$page_body" | grep -Fq '>Sign Out</a>'
		printf '%s' "$page_body" | grep -Fq '>Site Administration</a>'
		printf '%s' "$page_body" | grep -Fq 'aria-label="Navigation Menu" aria-expanded="false" data-public-nav-toggle'
		printf '%s' "$page_body" | grep -Fq 'class="trueog-public-admin-badge"'
		printf '%s' "$page_body" | grep -Fq '<link rel="icon" href="/assets/img/favicon.png?v=1" sizes="32x32" type="image/png">'
		printf '%s' "$page_body" | grep -Fq '<a href="/explore/repos">Explore</a>'
		printf '%s' "$page_body" | grep -Fq '<a target="_blank" href="https://docs.gitea.com" data-public-guest>Help</a>'
		printf '%s' "$page_body" | grep -Fq '<a rel="nofollow" href="/user/login" data-public-guest>'
		if printf '%s' "$page_body" | grep -Fq 'trueog-logo.png'; then
			echo "generated chooser still contains the standalone navbar logo: $page" >&2
			return 1
		fi
		printf '%s' "$page_body" | grep -Fq '<script src="/assets/scripts/trueog-public.js?v=7"></script>'
		[ "$(printf '%s' "$page_body" | grep -oi '<script' | wc -l)" -eq 1 ] || {
			echo "generated chooser has an unexpected script count: $page" >&2
			return 1
		}
	done
	pull_wizard=$(curl -fsS -m 10 http://127.0.0.1:3000/assets/html/trueog-pull-wizard.html)
	printf '%s' "$pull_wizard" | grep -Fq 'data-target-suffix="/pulls"'
	printf '%s' "$pull_wizard" | grep -Fq 'data-target-suffix="/fork"'
	printf '%s' "$pull_wizard" | grep -Fq '<span>Open pull request</span>'
	if printf '%s' "$pull_wizard" | grep -Fq '/compare/'; then
		echo "pull chooser still targets a branch comparison" >&2
		return 1
	fi
	bug_wizard=$(curl -fsS -m 10 http://127.0.0.1:3000/assets/html/trueog-bug-wizard.html)
	printf '%s' "$bug_wizard" | grep -Fq '<strong>Not sure?</strong>'
	printf '%s' "$bug_wizard" | grep -Fq 'https://discord.gg/ma9pMYpBU6">#bug-reports on Discord</a>'
	printf '%s' "$bug_wizard" | grep -Fq 'data-target-suffix="/issues/new/choose"'
	# The helper must load from <head> so it can hide the navbar before the guest links are painted.
	printf '%s' "$bug_wizard" | sed -n '/<head>/,/<\/head>/p' | grep -Fq '<script src="/assets/scripts/trueog-public.js?v=7"></script>'
	public_js=$(curl -fsS -m 10 http://127.0.0.1:3000/assets/scripts/trueog-public.js?v=7)
	printf '%s' "$public_js" | grep -Fq 'allowedSuffixes'
	printf '%s' "$public_js" | grep -Fq 'fetch("/explore/repos"'
	printf '%s' "$public_js" | grep -Fq 'credentials: "same-origin"'
	printf '%s' "$public_js" | grep -Fq 'redirect: "error"'
	printf '%s' "$public_js" | grep -Fq 'new DOMParser().parseFromString'
	printf '%s' "$public_js" | grep -Fq '[data-signed-in-username]'
	printf '%s' "$public_js" | grep -Fq 'username.textContent = login'
	printf '%s' "$public_js" | grep -Fq 'avatarUrl.origin === window.location.origin'
	if printf '%s' "$public_js" | grep -Fq '.innerHTML'; then
		echo "public navigation helper must not inject fetched Gitea markup with innerHTML" >&2
		return 1
	fi
	if printf '%s' "$public_js" | grep -Eq 'document\.cookie|localStorage|sessionStorage'; then
		echo "public navigation helper must not read browser credential or storage values" >&2
		return 1
	fi
	if printf '%s' "$public_js" | grep -Fq '/api/v1/user'; then
		echo "public navigation helper still uses the API endpoint that cannot read Gitea browser sessions" >&2
		return 1
	fi
	printf '%s' "$public_js" | grep -Fq 'if (home) home.setAttribute("href", "/?home=1")'
	printf '%s' "$public_js" | grep -Fq 'root.classList.add("trueog-js", "trueog-auth-pending")'
	printf '%s' "$public_js" | grep -Fq 'window.setTimeout(revealNavigation, 2500)'
	printf '%s' "$public_js" | grep -Fq 'const applyTheme = (nativePage) =>'
	printf '%s' "$public_js" | grep -Fq '[data-public-nav-toggle]'
	printf '%s' "$public_js" | grep -Fq 'control.getAttribute("role") !== "checkbox"'
	public_css=$(curl -fsS -m 10 http://127.0.0.1:3000/assets/css/trueog-public.css?v=14)
	printf '%s' "$public_css" | grep -Fq '.trueog-public-nav-left'
	printf '%s' "$public_css" | grep -Fq 'color-scheme: dark;'
	printf '%s' "$public_css" | grep -Fq 'font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;'
	printf '%s' "$public_css" | grep -Fq 'font-family: "Monocraft", monospace;'
	printf '%s' "$public_css" | grep -Fq 'font-feature-settings: "kern" 0, "liga" 0, "calt" 0;'
	printf '%s' "$public_css" | grep -Fq '@media (max-width: 767.98px)'
	printf '%s' "$public_css" | grep -Fq 'html.trueog-theme-dark .trueog-public-nav {'
	printf '%s' "$public_css" | grep -Fq '.trueog-js .trueog-public-nav-open'
	if printf '%s' "$public_css" | grep -Fq 'font-size: 12px;'; then
		echo "generated-page navbar still shrinks below the native 14px size" >&2
		return 1
	fi
	printf '%s' "$public_css" | grep -Fq '.trueog-public-heading h1'
	printf '%s' "$public_css" | grep -Fq 'font-family: "Monocraft", monospace;'
	printf '%s' "$public_css" | grep -Fq -- '--trueog-nav-bg: #f6f7fa;'
	printf '%s' "$public_css" | grep -Fq 'font-size: 14px;'
	printf '%s' "$public_css" | grep -Fq 'font-size: clamp(1.5rem, 4vw, 1.75rem);'
	printf '%s' "$public_css" | grep -Fq 'color: #FFAA00; /* Bukkit ChatColor.GOLD */'
	printf '%s' "$public_css" | grep -Fq 'transform: translateX(calc(1em / 18));'
	printf '%s' "$public_css" | grep -Fq '.trueog-public-footer-left::before'
	printf '%s' "$public_css" | grep -Fq 'mask: url("/assets/img/logo.svg") center / contain no-repeat;'
	curl -fsSI -m 10 http://127.0.0.1:3000/assets/trueog-manifest.json?v=1 | tr -d '\r' | grep -iFxq 'Content-Type: application/json'
	for asset in assets/img/favicon.png assets/img/favicon.ico assets/img/apple-touch-icon.png assets/img/trueog-icon-192.png assets/img/trueog-icon-512.png assets/trueog-manifest.json assets/browserconfig.xml; do
		curl -fsS -m 10 "http://127.0.0.1:3000/$asset?v=1" | cmp - "$SRC/custom-public/$asset"
	done
	printf '%s' "$public_css" | grep -Fq 'background: rgba(96, 153, 38, 0.14);'
	printf '%s' "$public_css" | grep -Fq 'grid-template-columns: auto minmax(0, 1fr) auto;'
	printf '%s' "$public_css" | grep -Fq 'justify-self: center;'
	printf '%s' "$public_css" | grep -Fq '.trueog-public-pagination'
	printf '%s' "$public_css" | grep -Fq '.trueog-public-filter[aria-checked="true"] .trueog-public-filter-box'
	printf '%s' "$public_css" | grep -Fq 'color: #131416;'
	printf '%s' "$public_css" | grep -Fq '[hidden]'
	printf '%s' "$public_css" | grep -Fq '.trueog-public-nav-authenticated'
	printf '%s' "$public_css" | grep -Fq '.trueog-auth-pending .trueog-public-nav-left'
	printf '%s' "$public_css" | grep -Fq '.trueog-public-menu-panel'
	printf '%s' "$public_css" | grep -Fq '.trueog-public-submit span'
	printf '%s' "$public_css" | grep -Fq 'fill: currentColor;'
	curl -fsS -m 10 http://127.0.0.1:3000/assets/licenses.txt | grep -Fq 'Monocraft - SIL Open Font License 1.1'
	origin='https://git.trueog.net'
	bare_pulls_headers=$(curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -sS -m 10 -D - -o /dev/null "$origin/pulls" | tr -d '\r')
	printf '%s' "$bare_pulls_headers" | grep -Eq '^HTTP/[0-9.]+ 30[23] '
	printf '%s' "$bare_pulls_headers" | grep -iEq '^location: .*/user/login'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/pulls?state=all" | grep -Fq '<h1>All pull requests</h1>'
	if [ -f "$CUSTOM/public/assets/html/trueog-pulls-all-page-2.html" ]; then
		curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/pulls?state=all&page=2" | grep -Fq 'aria-current="page">2</a>'
	fi
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/pulls?state=open" | grep -Fq '<h1>Open pull requests</h1>'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/pulls?state=open" | grep -Fq 'role="checkbox" aria-checked="false" href="/pulls?state=open&amp;personal=hide"'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/pulls?state=open&personal=hide" | grep -Fq 'role="checkbox" aria-checked="true" href="/pulls?state=open"'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/pulls?state=all&personal=hide" | grep -Fq 'role="checkbox" aria-checked="true" href="/pulls?state=all"'
	bare_issues_headers=$(curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -sS -m 10 -D - -o /dev/null "$origin/issues" | tr -d '\r')
	printf '%s' "$bare_issues_headers" | grep -Eq '^HTTP/[0-9.]+ 30[23] '
	printf '%s' "$bare_issues_headers" | grep -iEq '^location: .*/user/login'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/issues?state=all" | grep -Fq '<h1>All issues</h1>'
	if [ -f "$CUSTOM/public/assets/html/trueog-issues-all-page-2.html" ]; then
		curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/issues?state=all&page=2" | grep -Fq 'aria-current="page">2</a>'
	fi
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/issues?state=open" | grep -Fq '<h1>Open issues</h1>'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/issues?state=open" | grep -Fq 'role="checkbox" aria-checked="false" href="/issues?state=open&amp;personal=hide"'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/issues?state=open&personal=hide" | grep -Fq 'role="checkbox" aria-checked="true" href="/issues?state=open"'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 -D - -o /dev/null "$origin/issues?state=open" | tr -d '\r' | grep -iFq "content-security-policy: default-src 'none'; script-src 'self'; connect-src 'self'"
	curl -fsS -m 10 http://127.0.0.1:3000/ | grep -Fq 'class="trueog-stat trueog-stat-issues" href="/issues?state=open"'
	curl -fsS -m 10 http://127.0.0.1:3000/assets/css/trueog-stats.css | grep -Fq '.trueog-stat-issues::before'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 30 "$origin/-/trueog-divergence?fork=trueog/MyWorlds&branch=master&base=upstream/MyWorlds&base_branch=master" | grep -Eq '"ahead":[0-9]+'
	curl -fsS -m 10 http://127.0.0.1:3000/trueog/MyWorlds | grep -Fq 'class="ui message flex-text-block trueog-upstream"'
	not_found=$(curl -sS -m 10 -H 'Accept: text/html' -w '\nHTTP %{http_code}' http://127.0.0.1:3000/trueog-404-check-missing)
	printf '%s' "$not_found" | grep -Fxq 'HTTP 404'
	printf '%s' "$not_found" | grep -Fq 'class="status-page-error trueog-404"'
	printf '%s' "$not_found" | grep -Fq '/assets/img/trueog-404.jpg?v=1'
	printf '%s' "$not_found" | grep -Fq '/assets/css/trueog-404.css?v=2'
	curl -fsS -m 10 'http://127.0.0.1:3000/assets/img/trueog-404.jpg?v=1' | cmp -s - "$SRC/custom-public/assets/img/trueog-404.jpg"
	[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:3000/assets/img/trueog-galaxy.jpg)" = 404 ]
	verify_divergence_service
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/contribute/pull-request" | grep -Fq '<span>Pull request / fork</span>'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 "$origin/contribute/bug-report" | grep -Fq '<span>File bug report</span>'
	curl --noproxy '*' --resolve git.trueog.net:443:127.0.0.1 -fsS -m 10 -D - -o /dev/null "$origin/pulls?state=open" | tr -d '\r' | grep -iFq "content-security-policy: default-src 'none'; script-src 'self'; connect-src 'self'"
	verify_signing_live
	echo "version, process count, homepage (no JavaScript, live statistics), session-aware public pull/contribution pages, fork banner, 404 page, branding assets, navbar, footer, login page and signing key: verified"
}

case "$PHASE" in
check)
	say "Dockerless OpenRC baseline"
	echo "running: $(running_version || true)"
	echo "current: $(readlink -f /opt/gitea/current)"
	rc-service gitea status || true
	rc-update show default | grep -E '(^|[[:space:]])gitea([[:space:]]|$)' || {
		echo "BLOCKER: gitea is not enabled in OpenRC's default runlevel" >&2
		exit 1
	}
	verify_divergence_service || exit 1
	[ ! -e /etc/systemd/system/gitea.service ] || {
		echo "BLOCKER: unexpected systemd unit exists; this deployment must remain OpenRC-only" >&2
		exit 1
	}

	say "target artifact verification"
	verify_artifacts
	echo "$($BIN --version)"

	say "custom template compatibility"
	template_compatibility
	custom_source_parity
	system_customizations
	verify_signing_live

	say "database and capacity"
	db=$(db_name)
	echo "database: $db ($(su -s /bin/sh postgres -c "psql -Atc \"select pg_size_pretty(pg_database_size('$db'))\""))"
	df -h /opt "$BACKUP_ROOT"

	if [ "$(running_version || true)" = "$TARGET" ]; then
		echo "Nothing changed. Target $TARGET is already active."
	else
		echo "Nothing changed. Apply with: doas sh $0 apply $TARGET"
	fi
	;;

apply)
	old_version=$(running_version)
	[ -n "$old_version" ] || { echo "Gitea is not reachable before upgrade" >&2; exit 1; }
	[ "$old_version" != "$TARGET" ] || { echo "Gitea $TARGET is already running"; exit 0; }
	old_link=$(readlink /opt/gitea/current)

	say "preflight"
	verify_artifacts
	template_compatibility
	custom_source_parity
	system_customizations
	verify_signing_files
	db=$(db_name)
	ts=$(date +%F_%H-%M-%S)
	umask 077
	mkdir -p "$BACKUP_ROOT"
	install -D -m 755 -o root -g root "$BIN" "/opt/gitea/releases/$TARGET/gitea"

	say "stop native OpenRC service"
	hard_stop

	say "offline backup"
	dump="$BACKUP_ROOT/${db}_pre-${TARGET}_${ts}.dump"
	archive="$BACKUP_ROOT/gitea-custom-data_pre-${TARGET}_${ts}.tgz"
	appini="$BACKUP_ROOT/app.ini.pre-${TARGET}_${ts}"
	initfile="$BACKUP_ROOT/init.d-gitea.pre-${TARGET}_${ts}"
	confd="$BACKUP_ROOT/conf.d-gitea.pre-${TARGET}_${ts}"
	su -s /bin/sh postgres -c "pg_dump -Fc $db" >"$dump"
	pg_restore -l "$dump" | grep -q 'TABLE DATA' || { echo "database dump has no table data" >&2; exit 1; }
	tar -C /opt/gitea -czf "$archive" custom data
	cp -a "$APP_INI" "$appini"
	cp -a /etc/init.d/gitea "$initfile"
	cp -a /etc/conf.d/gitea "$confd"
	printf 'old_version=%s\nold_link=%s\ndb=%s\ndump=%s\narchive=%s\nappini=%s\ninitfile=%s\nconfd=%s\n' \
		"$old_version" "$old_link" "$db" "$dump" "$archive" "$appini" "$initfile" "$confd" >"$STATE"
	echo "database: $dump"
	echo "custom/data: $archive"
	echo "rollback state: $STATE"

	say "install customizations and migrate"
	install_customizations
	ln -sfn "releases/$TARGET" /opt/gitea/current
	echo "current -> $(readlink /opt/gitea/current)"
	/usr/local/sbin/gitea-license-bundle /opt/gitea/current/gitea "$CUSTOM/public/assets/licenses.txt"
	if ! as_gitea "/opt/gitea/current/gitea migrate --config $APP_INI" >"$BACKUP_ROOT/migrate-${TARGET}_${ts}.log" 2>&1; then
		tail -n 30 "$BACKUP_ROOT/migrate-${TARGET}_${ts}.log" >&2
		echo "Migration failed; Gitea remains stopped. Run: doas sh $0 rollback $TARGET" >&2
		exit 1
	fi
	tail -n 5 "$BACKUP_ROOT/migrate-${TARGET}_${ts}.log"

	say "start through OpenRC"
	logmark=$(wc -l </var/log/gitea/stdout.log 2>/dev/null || echo 0)
	start_openrc_detached

	say "post-upgrade checks"
	verify_site "$TARGET"
	rc-service gitea status || true
	echo "fresh serious log messages (empty is good):"
	tail -n +"$((logmark + 1))" /var/log/gitea/stdout.log 2>/dev/null |
		grep -iE 'queue.*lock|fatal|panic|\[E\]|error' | head -n 30 || true
	echo "Upgrade complete. Roll back with: doas sh $0 rollback $TARGET"
	;;

rollback)
	[ -r "$STATE" ] || { echo "no rollback state: $STATE" >&2; exit 1; }
	. "$STATE"
	say "stop native OpenRC service"
	hard_stop
	say "preserve failed target state"
	ts=$(date +%F_%H-%M-%S)
	[ ! -e "$CUSTOM" ] || mv "$CUSTOM" "$BACKUP_ROOT/custom.failed-${TARGET}_$ts"
	[ ! -e /opt/gitea/data ] || mv /opt/gitea/data "$BACKUP_ROOT/data.failed-${TARGET}_$ts"
	say "restore database, data, configuration and prior binary"
	owner=$(su -s /bin/sh postgres -c "psql -Atc \"select pg_get_userbyid(datdba) from pg_database where datname='$db'\"")
	su -s /bin/sh postgres -c "dropdb $db"
	su -s /bin/sh postgres -c "createdb -O $owner $db"
	su -s /bin/sh postgres -c "pg_restore -d $db '$dump'"
	tar -C /opt/gitea -xzf "$archive"
	cp -a "$appini" "$APP_INI"
	cp -a "$initfile" /etc/init.d/gitea
	cp -a "$confd" /etc/conf.d/gitea
	ln -sfn "$old_link" /opt/gitea/current
	start_openrc_detached
	verify_site "$old_version"
	echo "rollback complete: $old_version"
	;;
esac
