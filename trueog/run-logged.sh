#!/bin/sh
# Run one reviewed root helper with its complete output saved for review.
#
# Every root helper's complete stdout, stderr and exit status must land in a world-readable file under
# /home/system/gitea-upgrade/. install-custom-templates.sh and upgrade-gitea.sh print to the terminal
# only; this wrapper runs them
# unchanged and writes everything to /home/system/gitea-upgrade/logged-<helper>[-<phase>-<version>].log,
# ending with HELPER_EXIT=<status>. Only the helpers listed below are accepted.
#   doas sh /home/system/gitea-upgrade/run-logged.sh install-custom-templates.sh
#   doas sh /home/system/gitea-upgrade/run-logged.sh upgrade-gitea.sh check 28.3.0
#   doas sh /home/system/gitea-upgrade/run-logged.sh upgrade-gitea.sh apply 28.3.0

[ "$(id -u)" = 0 ] || { echo "run as root: doas sh $0 <helper> [args]" >&2; exit 1; }
SRC=/home/system/gitea-upgrade
helper=${1:-}
case "$helper" in
	install-custom-templates.sh) [ "$#" = 1 ] || { echo "install-custom-templates.sh takes no arguments" >&2; exit 2; } ;;
	upgrade-gitea.sh)
		[ "$#" = 3 ] || { echo "usage: $0 upgrade-gitea.sh check|apply|rollback <version>" >&2; exit 2; }
		case "$2" in check|apply|rollback) ;; *) echo "invalid phase: $2" >&2; exit 2 ;; esac
		case "$3" in ''|*[!0-9.]*) echo "invalid version: $3" >&2; exit 2 ;; esac ;;
	'') printf '%s\n' "usage:" "  doas sh $0 install-custom-templates.sh" "  doas sh $0 upgrade-gitea.sh check|apply|rollback <version>" >&2; exit 2 ;;
	*) echo "not an allowed helper: $helper" >&2; exit 2 ;;
esac
shift
name=$(printf '%s' "$helper" | sed 's/\.sh$//')
[ "$#" = 0 ] || name="$name-$1-$2"
LOG=$SRC/logged-$name.log
rm -f "$LOG"
: > "$LOG"
chmod 644 "$LOG"
echo "started $(date -Is): sh $SRC/$helper $*" >> "$LOG"
sh "$SRC/$helper" "$@" >> "$LOG" 2>&1
rc=$?
echo "finished $(date -Is)" >> "$LOG"
echo "HELPER_EXIT=$rc" >> "$LOG"
cat "$LOG"
exit "$rc"
