#!/usr/bin/env bash
set -euo pipefail

config="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"
[[ -r "$config" ]] || { echo "Missing desktop configuration file: $config" >&2; exit 1; }
source "$config"

case "${DESKTOP:-}:${DISPLAY_BACKEND:-}" in
    none:x11) command_line='exit 0' ;;
    kde:x11) command_line='export DISPLAY="${DISPLAY:-:5}"; exec startplasma-x11' ;;
    kde:anland-wayland) command_line='exec startplasma-wayland' ;;
    kde-mobile:anland-wayland) command_line='exec startplasmamobile' ;;
    gnome:anland-wayland) command_line='exec gnome-session --session=gnome' ;;
    # The Anland Next session body is the anland-session shipped in the package
    # (session D-Bus + wayland link + rootless Xwayland + mini-wm) and does not go
    # through any desktop environment. Use the system path under /usr/bin, not a
    # copy in the user home; the script computes XDG_RUNTIME_DIR itself and only
    # warns when the systemd user manager is unavailable, so no user unit is needed.
    anland-next:anland-wayland) command_line='exec /usr/bin/anland-session' ;;
    niri:anland-wayland) command_line='exec /usr/bin/niri-anland' ;;
    *)
        echo "Unsupported desktop session: ${DESKTOP:-unset}/${DISPLAY_BACKEND:-unset}" >&2
        exit 1
        ;;
esac

if [[ "${DROIDSPACES_SESSION_DRY_RUN:-false}" == true ]]; then
    printf '%s\n' "$command_line"
    exit 0
fi

exec /bin/bash -lc "$command_line"
