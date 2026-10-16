#!/usr/bin/env bash
set -euo pipefail

desktop="${1:-}"
profile_dir="${DROIDSPACES_DESKTOP_PROFILE_DIR:-/usr/local/lib/droidspaces/desktops}"

case "${ENABLE_systemd257_ARG:-false}" in
    true)
        case "$desktop" in
            none|kde) ;;
            *)
                echo "systemd 257 builds only support none and plain KDE; refusing to install: $desktop" >&2
                exit 1
                ;;
        esac
        ;;
    false) ;;
    *)
        echo "ENABLE_systemd257_ARG only supports true or false." >&2
        exit 1
        ;;
esac

case "$desktop" in
    none)
        echo "--> Desktop profile: none"
        exit 0
        ;;
esac

if [[ ! "$desktop" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "Unsupported desktop profile: $desktop" >&2
    exit 1
fi

profile="$profile_dir/$desktop.sh"
if [[ ! -x "$profile" ]]; then
    echo "Desktop profile script is missing or not executable: $profile" >&2
    exit 1
fi

echo "--> Installing desktop profile: $desktop"
exec "$profile"
