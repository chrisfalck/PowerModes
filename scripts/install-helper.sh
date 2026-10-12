#!/bin/sh
# Root half of the install. Run: sudo ./scripts/install-helper.sh
# The app's "Install Helper…" button runs the copy in its bundle through the macOS admin prompt,
# passing --user and --no-restart.
#   1. Installs the root-owned helper that changes power modes.
#   2. Lets the installing user run only that helper's mode commands without a password.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
user=${SUDO_USER:-}
restart=1
while [ $# -gt 0 ]; do
    case "$1" in
        --user) user=${2:-}; shift 2 ;;
        --no-restart) restart=0; shift ;;
        *) echo "Usage: $0 [--user NAME] [--no-restart]" >&2; exit 2 ;;
    esac
done
case "$user" in ''|root|*[!A-Za-z0-9._-]*) echo "Run with sudo from your own account." >&2; exit 1 ;; esac
id -u "$user" >/dev/null 2>&1 || { echo "Unknown user: $user" >&2; exit 1; }
dir=$(cd "$(dirname "$0")" && pwd)
# In the app bundle the helper sits beside this script; in the repo it is in build/.
built="$dir/io.github.chrisfalck.powermodes.helper"
[ -x "$built" ] || built="$dir/../build/io.github.chrisfalck.powermodes.helper"
[ -x "$built" ] || { echo "Build first: ./scripts/build.sh" >&2; exit 1; }

HELPER=/Library/PrivilegedHelperTools/io.github.chrisfalck.powermodes.helper
# sudoers.d ignores file names containing a dot.
SUDOERS=/etc/sudoers.d/power-modes-helper

mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 0755 "$built" "$HELPER"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
{
    echo "# Power Modes menu bar app: mode changes only, arguments fixed."
    printf 'Cmnd_Alias POWER_MODES_HELPER ='
    sep=' '
    for verb in --switch --set; do
        for source in b c; do
            for mode in 0 1 2; do
                printf '%s%s %s %s %s' "$sep" "$HELPER" "$verb" "$source" "$mode"
                sep=', \
    '
            done
        done
    done
    printf '\n%s ALL = (root) NOPASSWD: POWER_MODES_HELPER\n' "$user"
} > "$tmp"
visudo -cf "$tmp" >/dev/null
install -o root -g wheel -m 0440 "$tmp" "$SUDOERS"
visudo -c >/dev/null
# Ask as the user, not with -U: an admin may run anything with a password, so only a
# password-free answer shows this rule is the one in effect. The rule's scope is the fixed list above.
sudo -u "$user" sudo -n -l "$HELPER" --set c 0 >/dev/null 2>&1 || {
    echo "ERROR: sudoers rule installed but not in effect (is /etc/sudoers.d included?)." >&2; exit 1; }

echo "Installed $HELPER and $SUDOERS for $user."
# Restart the running app so it takes over now rather than at its next minute tick.
[ "$restart" = 0 ] || launchctl kickstart -k "gui/$(id -u "$user")/io.github.chrisfalck.power-modes" 2>/dev/null || true
