#!/bin/sh
# Summarize recent problems in the Gitea logs of TrueOG's Dockerless OpenRC deployment.
#
#   doas sh ~/gitea-upgrade/check-gitea-logs.sh [HOURS]      (default: the last 24 hours)
#
# Read-only. Reports service health, log sizes and rotation, counts by log level, the most frequent
# warnings and errors (numbers folded so repeats group together), the latest errors, panics and fatal
# lines, HTTP 5xx responses, known problem patterns, stderr, the GitHub mirror logs, and the OpenRC
# start log. Everything printed is redacted first: webhook tokens, credentials in URLs, token and
# password parameters, OAuth/OIDC callback values (code, state, nonce) and CSRF/session values,
# 40-character hex strings (Gitea access tokens; commit IDs are caught too), and client IP addresses.
# Review the output before sharing it: the redaction covers the patterns above, not every possible secret.
#
# Exit status: 0 nothing found, 1 errors/panics/5xx found in the window, 2 usage or access problem.
# LOG_DIR and APP_INI can be overridden for testing.
set -eu

HOURS=${1:-24}
case $HOURS in '' | *[!0-9]*) echo "usage: $0 [HOURS]" >&2; exit 2 ;; esac
LOG_DIR=${LOG_DIR:-/var/log/gitea}
APP_INI=${APP_INI:-/var/lib/gitea/custom/conf/app.ini}
MAIN=$LOG_DIR/stdout.log
[ -r "$MAIN" ] || { echo "cannot read $MAIN; run as root: doas sh $0 $HOURS" >&2; exit 2; }

CUTOFF=$(date -d "-$HOURS hours" '+%Y/%m/%d %H:%M:%S')
work=$(mktemp -d /tmp/check-gitea-logs.XXXXXX)
trap 'rm -rf "$work"' EXIT

# Gitea writes "YYYY/MM/DD HH:MM:SS ..." in local time. Lines without a timestamp (stack traces)
# follow the decision for the line before them.
window() {
	awk -v cutoff="$CUTOFF" '
		/^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
			keep = (substr($0, 1, 19) >= cutoff)
		}
		keep' "$@"
}

redact() {
	sed -E \
		-e 's#(discord(app)?\.com/api/webhooks/[0-9]+/)[A-Za-z0-9_.-]+#\1<redacted>#Ig' \
		-e 's#(://[^/:@[:space:]]+:)[^@[:space:]/]+@#\1<redacted>@#g' \
		-e 's#((access_)?token|secret|password|passwd|api_?key|sig|signature)=[^&[:space:]"]+#\1=<redacted>#Ig' \
		-e 's#([?&;[:space:]](code|state|nonce|_csrf|session))=[^&[:space:]"]+#\1=<redacted>#Ig' \
		-e 's#(authorization:?[[:space:]]*(bearer|basic|token)?[[:space:]]*)[A-Za-z0-9._~+/=-]{8,}#\1<redacted>#Ig' \
		-e 's#\b[0-9a-fA-F]{40}\b#<hex40>#g' \
		-e 's#\b127\.0\.0\.1\b#LOOPBACK4#g' \
		-e 's#\b(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}\b#<ip>#g' \
		-e 's#LOOPBACK4#127.0.0.1#g' \
		-e 's#\b([0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b#<ip6>#g' \
		-e 's#^(.{300}).+#\1 ...#'
}

findings=0
found() { findings=1; }
heading() { printf '\n== %s ==\n' "$1"; }

report() {
	echo "Gitea log check: last $HOURS hours (since $CUTOFF, server local time), run $(date '+%Y-%m-%d %H:%M %Z')"

	heading "Service"
	printf 'version: %s\n' "$(curl -fsS -m 5 http://127.0.0.1:3000/api/v1/version 2>/dev/null || echo 'NOT RESPONDING')"
	rc-service gitea status 2>&1 | sed 's/^ *//' || true
	printf 'supervise-daemon processes: %s, gitea processes: %s\n' \
		"$(pgrep -fc '^supervise-daemon gitea ' || true)" "$(pgrep -u gitea -xc gitea || true)"

	heading "Log files"
	logroot=
	if [ -r "$APP_INI" ]; then
		logroot=$(awk -F= '/^\[log\]/{s=1;next} /^\[/{s=0} s && $1 ~ /^[[:space:]]*ROOT_PATH[[:space:]]*$/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$APP_INI")
		printf 'app.ini [log] MODE=%s LEVEL=%s ROOT_PATH=%s\n' \
			"$(awk -F= '/^\[log\]/{s=1;next} /^\[/{s=0} s && $1 ~ /^[[:space:]]*MODE[[:space:]]*$/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$APP_INI")" \
			"$(awk -F= '/^\[log\]/{s=1;next} /^\[/{s=0} s && $1 ~ /^[[:space:]]*LEVEL[[:space:]]*$/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$APP_INI")" \
			"${logroot:-(default)}"
	fi
	for f in "$LOG_DIR"/*.log ${logroot:+"$logroot"/*.log}; do
		[ -f "$f" ] || continue
		printf '%8s  %s  %s\n' "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%Y-%m-%d %H:%M')" "$f"
	done
	if grep -rqs "$LOG_DIR" /etc/logrotate.d /etc/logrotate.conf; then
		echo "logrotate: a rule mentions $LOG_DIR"
	else
		echo "logrotate: NO rule covers $LOG_DIR; stdout.log grows forever"
	fi

	window "$MAIN" >"$work/main"
	heading "Main log ($MAIN): lines by level"
	awk '{ if (match($0, / \[[TDIWECF]\] /)) n[substr($0, RSTART + 2, 1)]++ }
		END { printf "trace %d, debug %d, info %d, warning %d, error %d, critical %d, fatal %d\n",
			n["T"], n["D"], n["I"], n["W"], n["E"], n["C"], n["F"] }' "$work/main"

	grep -E ' \[(E|C|F)\] ' "$work/main" >"$work/errors" || true
	[ ! -s "$work/errors" ] || found

	heading "Most frequent warnings and errors (numbers folded into #)"
	awk '/ \[[WECF]\] / {
			msg = substr($0, 21); key = msg; gsub(/[0-9]+/, "#", key)
			count[key]++; last[key] = msg
		}
		END { for (k in count) printf "%6d  %s\n", count[k], last[k] }' "$work/main" |
		sort -rn | head -15
	[ -s "$work/errors" ] || grep -q ' \[W\] ' "$work/main" || echo "(none)"

	heading "Latest errors (newest last)"
	if [ -s "$work/errors" ]; then tail -n 20 "$work/errors"; else echo "(none)"; fi

	heading "Panics and fatal errors"
	grep -nE -i 'panic|fatal error:|goroutine [0-9]+ \[' "$work/main" >"$work/panics" || true
	if [ -s "$work/panics" ]; then
		found
		echo "matching lines: $(wc -l <"$work/panics"); latest:"
		tail -n 10 "$work/panics"
	else
		echo "(none)"
	fi

	heading "Known problem patterns"
	for pattern in \
		'queue lock|resource temporarily unavailable|LOCK: ' \
		'Render failed|template error' \
		'context deadline exceeded|Client.Timeout' \
		'webhook|deliver' \
		'permission denied' \
		'pq: |database|connection refused' \
		'too many open files' \
		'mirror|push mirror'; do
		n=$(grep -E -ci -- "$pattern" "$work/errors" || true)
		printf '%6s  %s\n' "${n:-0}" "$pattern"
	done
	echo "(counted among error/critical/fatal lines only)"

	heading "HTTP 5xx responses"
	grep -E 'completed [A-Z]+ .*, 5[0-9][0-9] ' "$work/main" >"$work/http5xx" || true
	if [ -s "$work/http5xx" ]; then
		found
		echo "5xx responses: $(wc -l <"$work/http5xx"); by status and path:"
		sed -E -n 's#.*completed ([A-Z]+) ([^ ]+) .*, (5[0-9][0-9]) .*#\3 \1 \2#p' "$work/http5xx" |
			sed -E 's#\?.*##' | sort | uniq -c | sort -rn | head -10
	else
		echo "(none)"
	fi

	heading "stderr ($LOG_DIR/stderr.log)"
	if [ -r "$LOG_DIR/stderr.log" ]; then
		window "$LOG_DIR/stderr.log" >"$work/stderr"
		if grep -qiE 'panic|fatal|error' "$work/stderr"; then found; fi
		echo "$(wc -l <"$work/stderr") lines in the window; latest:"
		tail -n 10 "$work/stderr"
		[ -s "$work/stderr" ] || tail -n 5 "$LOG_DIR/stderr.log" | sed 's/^/(older) /'
	else
		echo "(missing)"
	fi

	heading "GitHub mirror logs (problem lines, newest per repository)"
	shown=0
	for f in "$LOG_DIR"/github-mirror-*.log; do
		[ -f "$f" ] || continue
		repo=${f##*/github-mirror-}
		repo=${repo%.log}
		bad=$(tail -n 500 "$f" | grep -Ei 'error|fatal|reject|fail|denied' | tail -n 1 || true)
		if [ -n "$bad" ]; then
			printf '%s (last write %s): %s\n' "$repo" "$(date -r "$f" '+%Y-%m-%d %H:%M')" "$bad"
			shown=1
		fi
	done
	[ "$shown" = 1 ] || echo "(no problem lines in the last 500 lines of any mirror log)"

	heading "OpenRC detached starts ($LOG_DIR/openrc-detached-start.log, last 5 lines)"
	if [ -r "$LOG_DIR/openrc-detached-start.log" ]; then tail -n 5 "$LOG_DIR/openrc-detached-start.log"; else echo "(missing)"; fi

	heading "Result"
	if [ "$findings" = 1 ]; then
		echo "PROBLEMS FOUND in the last $HOURS hours (details above)"
	else
		echo "clean: no errors, panics, or 5xx responses in the last $HOURS hours"
	fi
	echo "$findings" >"$work/status"
}

report >"$work/report" 2>&1 || true
redact <"$work/report"
exit "$(cat "$work/status" 2>/dev/null || echo 2)"
