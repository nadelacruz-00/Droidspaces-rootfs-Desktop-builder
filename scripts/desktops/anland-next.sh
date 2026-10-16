#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    # Only the variables this anland chain really reads or publishes are set:
    # ANLAND_RUNTIME_DIR is the container view of the host runtime dir
    # (droidspaces bind-mounts it to /run/anland), the three GPU variables are
    # the kgsl/freedreno paths, and the session forwards XDG_SESSION_TYPE to
    # apps. WAYLAND_DISPLAY is deliberately left out: the session checks the
    # host socket at $ANLAND_RUNTIME_DIR/$WAYLAND_DISPLAY and then publishes the
    # application-side wayland-anland link, so hardcoding either one breaks it.
    local -a assignments=(
        XDG_SESSION_CLASS=user
        XDG_SESSION_TYPE=wayland
        ANLAND_RUNTIME_DIR=/run/anland
        MESA_LOADER_DRIVER_OVERRIDE=kgsl
        GALLIUM_DRIVER=kgsl
        FD_FORCE_KGSL=1
        DISPLAY=:0
        QT_QPA_PLATFORM=wayland
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "Invalid Anland Next display backend: $backend" >&2
        return 1
    }

    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        if [[ "$key" == QT_QPA_PLATFORM ]] && grep -q "^${key}=" "$environment_file"; then
            sed -i "s|^${key}=.*|${assignment}|" "$environment_file"
        else
            grep -q "^${key}=" "$environment_file" || printf '%s\n' "$assignment" >> "$environment_file"
        fi
    done
}


install_apt() {
    sed -i 's|^path-exclude=/usr/share/locale/\*/LC_MESSAGES/\*.mo|#&|' \
        /etc/dpkg/dpkg.cfg.d/excludes 2>/dev/null || true

    case "$ID:$VERSION_ID" in
        debian:13)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji qt6-wayland pipewire pipewire-alsa pipewire-pulse \
                wireplumber ark upower konsole dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools \
                dbus-user-session clinfo dmidecode wayland-utils kfind \
                filelight glmark2 vkmark kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat6-plugins libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
                sound-theme-freedesktop
            ;;
        ubuntu:26.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji qt6-wayland pipewire pipewire-alsa pipewire-pulse \
                wireplumber ark upower konsole dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools \
                dbus-user-session clinfo dmidecode wayland-utils kfind filelight \
                glmark2 vkmark kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat6-plugins libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
                sound-theme-freedesktop libpam-systemd libpam-modules libpam-kwallet5 language-pack-kde-zh-hans \
                language-pack-zh-hans qt6-translations-l10n
            ;;
        *)
            echo "Anland Next does not support the current system: $ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in
        43|44) ;;
        *) echo "Anland Next does not support Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 xrandr xset xrdb xhost google-noto-cjk-fonts google-noto-emoji-color-fonts pipewire pipewire-alsa \
        pipewire-pulseaudio wireplumber ark upower konsole dolphin kate kinfocenter qt6-qtwayland glx-utils pulseaudio-utils \
        vulkan-tools clinfo dmidecode wayland-utils kfind \
        filelight glmark2 vkmark kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kf6-kimageformats libcanberra-gtk3 gstreamer1-plugins-base gstreamer1-plugins-good sound-theme-freedesktop
}

install_arch() {
    pacman -S --noconfirm --needed \
        xorg-xrandr noto-fonts-cjk noto-fonts-emoji qt6-wayland pipewire pipewire-alsa pipewire-pulse wireplumber ark upower konsole \
        dolphin kate kinfocenter mesa-utils libpulse vulkan-tools clinfo dmidecode wayland-utils kfind \
        filelight glmark2 vkmark kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kimageformats libcanberra gstreamer gst-plugins-base gst-plugins-good sound-theme-freedesktop
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_apt ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "Anland Next does not support the current distribution: $ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *)
        echo "Invalid Anland Next profile action: $1" >&2
        exit 1
        ;;
esac
