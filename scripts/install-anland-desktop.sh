#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || { echo "A desktop slug must be specified." >&2; exit 1; }
desktop="$1"
shift

case "$desktop" in
    kde|kde-mobile) installer="/usr/local/sbin/install-anland-kde" ;;
    gnome) installer="/usr/local/sbin/install-anland-gnome" ;;
    anland-next) installer="/usr/local/sbin/install-anland-next" ;;
    niri) installer="/usr/local/sbin/install-anland-niri" ;;
    *)
        echo "Desktop $desktop has no Anland package installer." >&2
        exit 1
        ;;
esac

[[ -x "$installer" ]] || { echo "Anland installer is missing or not executable: $installer" >&2; exit 1; }
exec "$installer" "$@"
