#!/usr/bin/env bash
#Pin the startup parameters
set -euo pipefail

desktop="${1:-}"
backend="${2:-}"
autostart="${3:-}"
username="${4:-}"
rootfs="${ROOTFS_DIR:-}"
templates="${START_TEMPLATES_DIR:-/tmp/droidspaces-start}"
profile_dir="${DROIDSPACES_DESKTOP_PROFILE_DIR:-/usr/local/lib/droidspaces/desktops}"
config="$rootfs/etc/droidspaces-desktop.conf"

configure_anland_next_runtime() {
    local bashrc="$rootfs/home/$username/.bashrc"
    local kate_source="$rootfs/usr/share/applications/org.kde.kate.desktop"
    local kate_override="$rootfs/usr/local/share/applications/org.kde.kate.desktop"
    local kate_wrapper="$rootfs/usr/local/bin/kate"

    install -d -m 0755 "$(dirname "$bashrc")" "$(dirname "$kate_wrapper")"
    touch "$bashrc"

    sed -i '/^# BEGIN droidspaces-anland-next shell environment$/,/^# END droidspaces-anland-next shell environment$/d' "$bashrc"
    cat >> "$bashrc" <<'EOF'
# BEGIN droidspaces-anland-next shell environment
if [ -r "$HOME/.anlandx-env" ]; then
    while IFS= read -r droidspaces_anland_env; do
        case "$droidspaces_anland_env" in
            ''|'#'*) ;;
            *=*) export "$droidspaces_anland_env" ;;
        esac
    done < "$HOME/.anlandx-env"
fi
if [ -r "$HOME/.anlandx" ]; then
    droidspaces_anland_display=''
    IFS= read -r droidspaces_anland_display < "$HOME/.anlandx" || true
    case "$droidspaces_anland_display" in
        :[0-9]*) export DISPLAY="$droidspaces_anland_display" ;;
    esac
fi
unset droidspaces_anland_env droidspaces_anland_display
# END droidspaces-anland-next shell environment
EOF

    if [[ -f "$kate_source" ]]; then
        install -d -m 0755 "$(dirname "$kate_override")"
        if ! awk '
            /^\[Desktop Entry\]$/ { in_main_group = 1 }
            /^\[/ && $0 != "[Desktop Entry]" { in_main_group = 0 }
            in_main_group && /^Exec=/ && !replaced {
                print "Exec=kate -b %U"
                replaced = 1
                next
            }
            { print }
            END { exit replaced ? 0 : 1 }
        ' "$kate_source" > "$kate_override"; then
            cp "$kate_source" "$kate_override"
        fi
        chmod 0644 "$kate_override"
    fi

    cat > "$kate_wrapper" <<'EOF'
#!/bin/sh
for droidspaces_kate_arg in "$@"; do
    case "$droidspaces_kate_arg" in
        -b|--block) exec /usr/bin/kate "$@" ;;
    esac
done
exec /usr/bin/kate -b "$@"
EOF
    chmod 0755 "$kate_wrapper"
}

[[ "$desktop" =~ ^(none|[a-z][a-z0-9-]*)$ ]] || { echo "Invalid desktop: $desktop" >&2; exit 1; }
case "$backend" in x11|anland-wayland) ;; *) echo "Invalid display backend: $backend" >&2; exit 1 ;; esac
case "$autostart" in true|false) ;; *) echo "Invalid desktop autostart value: $autostart" >&2; exit 1 ;; esac
[[ -n "$username" ]] || { echo "A desktop username must be specified" >&2; exit 1; }

if [[ "$desktop" == none && "$backend" != x11 ]]; then
    echo "Unsupported desktop and display backend combination: $desktop/$backend" >&2
    exit 1
fi
if [[ "$desktop" == kde-mobile && "$backend" != anland-wayland ]]; then
    echo "Unsupported desktop and display backend combination: $desktop/$backend" >&2
    exit 1
fi
if [[ "$desktop" == gnome && "$backend" != anland-wayland ]]; then
    echo "Unsupported desktop and display backend combination: $desktop/$backend" >&2
    exit 1
fi
if [[ "$desktop" == anland-next && "$backend" != anland-wayland ]]; then
    echo "Unsupported desktop and display backend combination: $desktop/$backend" >&2
    exit 1
fi
if [[ "$desktop" == niri && "$backend" != anland-wayland ]]; then
    echo "Unsupported desktop and display backend combination: $desktop/$backend" >&2
    exit 1
fi

cat > "$config" <<EOF
DESKTOP=$desktop
DISPLAY_BACKEND=$backend
EOF
chmod 0644 "$config"

# Desktop-specific environment must be configured after the Dockerfile finishes /etc/environment.
if [[ "$desktop" != none ]]; then
    profile="$profile_dir/$desktop.sh"
    [[ -x "$profile" ]] || { echo "Desktop config script missing or not executable: $profile" >&2; exit 1; }
    ROOTFS_DIR="$rootfs" "$profile" configure-environment "$backend"
fi

if [[ "$desktop" == anland-next ]]; then
    configure_anland_next_runtime
fi

if [[ "$desktop" == kde ]]; then
    install -d -m 0755 "$rootfs/home/$username/.config"
    cat > "$rootfs/home/$username/.config/kwinrc" <<'EOF'
[Compositing]
Enabled=false
EOF
fi

if [[ -z "$rootfs" ]]; then
    chown -R "$username:$username" "/home/$username"
fi

if [[ "$desktop" == none ]]; then
    [[ "$autostart" == false ]] || { echo "Autostart cannot be enabled when the desktop is none" >&2; exit 1; }
    exit 0
fi

if [[ "$autostart" == true ]]; then
    install -Dm0644 "$templates/desktop-session.service" \
        "$rootfs/etc/systemd/system/desktop-session.service"
    install -d -m 0755 "$rootfs/etc/systemd/system/multi-user.target.wants"
    ln -sfn /etc/systemd/system/desktop-session.service \
        "$rootfs/etc/systemd/system/multi-user.target.wants/desktop-session.service"
fi
