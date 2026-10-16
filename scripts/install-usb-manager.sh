#!/usr/bin/env bash
set -euo pipefail

readonly UPSTREAM_ARCHIVE_URL="https://github.com/Yizhou147/Droidspaces-USB-Manager/archive/refs/heads/main.tar.gz"
readonly INSTALL_DIR="/usr/share/usb-manager"
readonly SUDOERS_FILE="/etc/sudoers.d/droidspaces-usb-manager"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
WORK_DIR=""
SOURCE_DIR=""
TARGET_USER=""
TARGET_GROUP=""
TARGET_HOME=""
PACKAGE_FAMILY=""

msg() {
    printf '%s' "$1"
}

log() {
    printf '[usb-manager] %s\n' "$(msg "$1")"
}

die() {
    printf '[usb-manager] %s: %s\n' "$(msg 'Error')" "$(msg "$1")" >&2
    exit 1
}

usage() {
    cat <<EOF
$(msg 'Usage'): $0 [--user USER] [--source DIR]

  --user USER   $(msg 'Configure passwordless USB management permissions for USER.')
  --source DIR  $(msg 'Use a local Droidspaces-USB-Manager source directory.')
  -h, --help    $(msg 'Show this help.')
EOF
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        log "Restarting the installer with sudo..."
        exec sudo --preserve-env=LANG,LC_ALL,LC_MESSAGES,USB_MANAGER_SOURCE_DIR -- "$0" "$@"
    fi

    die "Please run this script as root."
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --user)
                (($# >= 2)) || die "--user requires a username."
                TARGET_USER="$2"
                shift 2
                ;;
            --source)
                (($# >= 2)) || die "--source requires a directory."
                SOURCE_DIR="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
}

detect_target() {
    [[ -r /etc/os-release ]] || die "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die "/etc/os-release does not contain ID."

    case "$ID" in
        debian|ubuntu) PACKAGE_FAMILY="apt" ;;
        fedora) PACKAGE_FAMILY="dnf" ;;
        arch|archarm) PACKAGE_FAMILY="pacman" ;;
        *)
            case " ${ID_LIKE:-} " in
                *" debian "*|*" ubuntu "*) PACKAGE_FAMILY="apt" ;;
                *" fedora "*|*" rhel "*) PACKAGE_FAMILY="dnf" ;;
                *" arch "*) PACKAGE_FAMILY="pacman" ;;
                *)
                    die "Unsupported system: ${PRETTY_NAME:-$ID}. Debian/Ubuntu, Fedora, and Arch families are supported."
                    ;;
            esac
            ;;
    esac

    log "Detected system: ${PRETTY_NAME:-$ID} (${PACKAGE_FAMILY})"
}

resolve_target_user() {
    local candidate=""
    local passwd_entry=""

    if [[ -z "$TARGET_USER" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
    fi

    if [[ -z "$TARGET_USER" ]]; then
        candidate="$(logname 2>/dev/null || true)"
        if [[ -n "$candidate" && "$candidate" != "root" ]]; then
            TARGET_USER="$candidate"
        fi
    fi

    if [[ -z "$TARGET_USER" ]]; then
        TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1; exit }' /etc/passwd)"
    fi

    [[ -n "$TARGET_USER" ]] || die \
        "Unable to determine the desktop user; specify it with --user USER."
    [[ "$TARGET_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || die \
        "Invalid username: $TARGET_USER"
    passwd_entry="$(getent passwd "$TARGET_USER")" || die \
        "User does not exist: $TARGET_USER"
    TARGET_GROUP="$(id -gn "$TARGET_USER")"
    TARGET_HOME="$(cut -d: -f6 <<<"$passwd_entry")"
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die \
        "User home directory does not exist: ${TARGET_HOME:-unknown}"

    log "USB management permissions will be configured for ${TARGET_USER}."
}

install_pacman_dependencies() {
    local state_file="${1:-$SYSTEMD257_STATE}"
    local -a packages=(
        python python-pyqt5 qt5-wayland qt5-svg util-linux sudo
        android-tools ntfs-3g exfatprogs desktop-file-utils gvfs gvfs-mtp kio-extras
        xdg-utils ca-certificates curl wget tar
    )

    if [[ -f "$state_file" ]]; then
        log "Detected the systemd 257 compatibility state; preserving Pacman IgnorePkg without explicitly requesting systemd."
    else
        # A regular Arch installation ships systemd; keep declaring the
        # dependency explicitly for minimal or non-Droidspaces environments
        # that have not been downgraded yet.
        packages+=(systemd)
    fi

    pacman -Syu --noconfirm --needed "${packages[@]}"
}

install_dependencies() {
    log "Installing GUI, USB, ADB, and filesystem dependencies..."

    case "$PACKAGE_FAMILY" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends \
                python3 python3-pyqt5 qtwayland5 libqt5svg5 udev util-linux sudo \
                adb ntfs-3g exfatprogs desktop-file-utils gvfs-backends gvfs-fuse kio-extras \
                xdg-utils ca-certificates curl wget tar
            ;;
        dnf)
            dnf install -y --setopt=install_weak_deps=False \
                python3 python3-qt5 qt5-qtwayland qt5-qtsvg systemd-udev util-linux sudo \
                android-tools ntfs-3g exfatprogs desktop-file-utils gvfs-mtp gvfs-fuse kio-extras \
                xdg-utils ca-certificates curl wget tar
            ;;
        pacman)
            install_pacman_dependencies
            ;;
    esac
}

has_sources() {
    local base="$1"
    [[ -f "$base/src/usb-manager.py" \
        && -f "$base/src/usb-passthrough.sh" \
        && -f "$base/src/usb-storage-passthrough.sh" ]]
}

download_sources() {
    local archive extract_root

    WORK_DIR="$(mktemp -d -t droidspaces-usb-manager.XXXXXXXX)"
    archive="$WORK_DIR/upstream.tar.gz"

    log "Local sources were not found; downloading Droidspaces-USB-Manager..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 "$UPSTREAM_ARCHIVE_URL" -o "$archive"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$archive" "$UPSTREAM_ARCHIVE_URL"
    else
        die "Neither curl nor wget was found; sources cannot be downloaded."
    fi

    tar -xzf "$archive" -C "$WORK_DIR"
    extract_root="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$extract_root" ]] || die "The downloaded source snapshot is invalid."
    has_sources "$extract_root" || die "The source snapshot is missing required files."
    SOURCE_DIR="$extract_root"
}

locate_sources() {
    local candidate
    local -a candidates=()

    if [[ -n "${USB_MANAGER_SOURCE_DIR:-}" ]]; then
        candidates+=("$USB_MANAGER_SOURCE_DIR")
    fi
    if [[ -n "$SOURCE_DIR" ]]; then
        candidates+=("$SOURCE_DIR")
    fi
    if [[ -n "$SCRIPT_DIR" ]]; then
        candidates+=(
            "$SCRIPT_DIR/Droidspaces-USB-Manager"
            "$SCRIPT_DIR/usb-manager"
            "$SCRIPT_DIR/../Droidspaces-USB-Manager"
        )
    fi
    candidates+=("$PWD")

    for candidate in "${candidates[@]}"; do
        if has_sources "$candidate"; then
            SOURCE_DIR="$(cd -- "$candidate" && pwd -P)"
            log "Using local sources: ${SOURCE_DIR}"
            return
        fi
    done

    download_sources
}

require_commands() {
    local command_name
    for command_name in python3 sudo bash mount umount mknod chmod mkdir blkid xdg-open visudo desktop-file-validate; do
        command -v "$command_name" >/dev/null 2>&1 || die \
            "Command is still unavailable after dependency installation: $command_name"
    done
}

install_program() {
    log "Installing Droidspaces USB Manager..."

    install -d -m 0755 "$INSTALL_DIR" /usr/share/applications /usr/share/doc/droidspaces-usb-manager
    install -m 0644 "$SOURCE_DIR/src/usb-manager.py" "$INSTALL_DIR/usb-manager.py"
    install -m 0755 "$SOURCE_DIR/src/usb-passthrough.sh" "$INSTALL_DIR/usb-passthrough.sh"
    install -m 0755 "$SOURCE_DIR/src/usb-storage-passthrough.sh" "$INSTALL_DIR/usb-storage-passthrough.sh"
    
    # Install the bundled icon
    if [[ -d "$SOURCE_DIR/icons" ]]; then
        install -d -m 0755 "$INSTALL_DIR/icons"
        install -m 0644 "$SOURCE_DIR/icons/"*.svg "$INSTALL_DIR/icons/"
        if [[ -f "$SOURCE_DIR/icons/LICENSE" ]]; then
            install -m 0644 "$SOURCE_DIR/icons/LICENSE" "$INSTALL_DIR/icons/LICENSE"
        fi
    fi

    # Upstream currently assumes Debian's /usr/sbin paths; Debian/Ubuntu, Fedora
    # and Arch (including merged-/usr installs) all share /usr/bin. Keep
    # upstream's preference for the X11 (xcb) backend to avoid Wayland issues.
    # The blkid path is resolved at runtime through BLKID_CMD, so it needs no patch.
    sed -i \
        -e 's|"dolphin", path|"xdg-open", path|g' \
        -e 's|Please run: sudo apt install python3-pyqt5|Please install the PyQt5 package for your distribution|g' \
        "$INSTALL_DIR/usb-manager.py"
    sed -i \
        's|SUDOERS_FILE="/etc/sudoers.d/usb-storage"|SUDOERS_FILE="/etc/sudoers.d/droidspaces-usb-manager"|g' \
        "$INSTALL_DIR/usb-storage-passthrough.sh"

    if [[ -f "$SOURCE_DIR/LICENSE" ]]; then
        install -m 0644 "$SOURCE_DIR/LICENSE" /usr/share/doc/droidspaces-usb-manager/LICENSE
    fi
    printf '%s\n' "$UPSTREAM_ARCHIVE_URL" > /usr/share/doc/droidspaces-usb-manager/upstream-source

    cat > /usr/bin/usb-manager <<'EOF'
#!/usr/bin/env bash
exec python3 /usr/share/usb-manager/usb-manager.py "$@"
EOF
    chmod 0755 /usr/bin/usb-manager

    cat > /usr/bin/usb-passthrough <<'EOF'
#!/usr/bin/env bash
exec sudo /usr/bin/bash /usr/share/usb-manager/usb-passthrough.sh "$@"
EOF
    chmod 0755 /usr/bin/usb-passthrough

    cat > /usr/bin/usb-storage-passthrough <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/bash /usr/share/usb-manager/usb-storage-passthrough.sh "$@"
EOF
    chmod 0755 /usr/bin/usb-storage-passthrough

    # Prefer the bundled icon, otherwise fall back to the system theme
    local icon_path="${INSTALL_DIR}/icons/usb-manager.svg"
    if [[ ! -f "$icon_path" ]]; then
        icon_path="drive-removable-media-usb"
        log "Bundled icons not found, falling back to system theme."
    fi
    
    cat > /usr/share/applications/usb-manager.desktop <<EOF
[Desktop Entry]
Name=USB Manager
Name[en]=USB Manager
Comment=Droidspaces USB Device Manager
Comment[en]=Droidspaces USB Device Manager
Exec=/usr/bin/usb-manager
Icon=${icon_path}
Terminal=false
Type=Application
Categories=System;
StartupNotify=false
EOF

    install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/Desktop"
    # If the desktop shortcut is already a symlink to the source file, delete it before
    # copying so install does not fail with a same-file error
    if [ -L "$TARGET_HOME/Desktop/usb-manager.desktop" ]; then
        rm -f -- "$TARGET_HOME/Desktop/usb-manager.desktop"
    fi
    install -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" \
        /usr/share/applications/usb-manager.desktop \
        "$TARGET_HOME/Desktop/usb-manager.desktop"
}

validate_program() {
    grep -Fq '"xdg-open", path' "$INSTALL_DIR/usb-manager.py" || die \
        "The file-manager compatibility patch could not be applied."
    grep -Fq "SUDOERS_FILE=\"$SUDOERS_FILE\"" "$INSTALL_DIR/usb-storage-passthrough.sh" || die \
        "The storage-script permission patch could not be applied."

    python3 -c 'import pathlib, sys; p = pathlib.Path(sys.argv[1]); compile(p.read_text(encoding="utf-8"), str(p), "exec")' \
        "$INSTALL_DIR/usb-manager.py"
    bash -n "$INSTALL_DIR/usb-passthrough.sh"
    bash -n "$INSTALL_DIR/usb-storage-passthrough.sh"
    desktop-file-validate /usr/share/applications/usb-manager.desktop
    desktop-file-validate "$TARGET_HOME/Desktop/usb-manager.desktop"
}

configure_permissions() {
    local sudoers_tmp
    sudoers_tmp="$(mktemp -t droidspaces-usb-manager-sudoers.XXXXXXXX)"

    # Add the desktop user to the ntfsusb group (gid 1023).
    # NTFS volumes mounted by recent ntfs-3g (2026.x) always use root:1023 770
    # ownership, so a regular user in that group can read and write the mount
    # point directly without going through pkexec authentication.
    if command -v groupadd >/dev/null 2>&1; then
        groupadd -g 1023 ntfsusb 2>/dev/null || true
        usermod -a -G 1023 "${TARGET_USER}" 2>/dev/null || true
        log "User ${TARGET_USER} has been added to the ntfsusb group."
    fi

    cat > "$sudoers_tmp" <<EOF
# Droidspaces USB Manager: create device nodes and mount removable media
# blkid is allowed for both the /usr/bin and /usr/sbin layouts (they differ between distributions/versions)
Cmnd_Alias DROIDSPACES_USB_MANAGER = /usr/bin/mount *, /usr/bin/umount *, /usr/bin/mknod *, /usr/bin/chmod *, /usr/bin/mkdir -p /dev/bus/usb/*, /usr/bin/blkid *, /usr/sbin/blkid *, /usr/bin/bash ${INSTALL_DIR}/usb-passthrough.sh
${TARGET_USER} ALL=(root) NOPASSWD: DROIDSPACES_USB_MANAGER
EOF

    visudo -cf "$sudoers_tmp" >/dev/null || die \
        "The generated sudoers configuration failed validation."
    install -m 0440 "$sudoers_tmp" "$SUDOERS_FILE"
    rm -f -- "$sudoers_tmp"

    if [[ -f /etc/fuse.conf ]] && ! grep -Eq '^[[:space:]]*user_allow_other([[:space:]]|$)' /etc/fuse.conf; then
        if grep -Eq '^[[:space:]]*#[[:space:]]*user_allow_other([[:space:]]|$)' /etc/fuse.conf; then
            sed -i 's/^[[:space:]]*#[[:space:]]*user_allow_other[[:space:]]*$/user_allow_other/' /etc/fuse.conf
        else
            printf '\nuser_allow_other\n' >> /etc/fuse.conf
        fi
    fi

    install -d -m 0755 /mnt/usb-storage
}

refresh_desktop_database() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    fi
}

main() {
    parse_args "$@"
    require_root "$@"
    detect_target
    resolve_target_user
    install_dependencies
    require_commands
    locate_sources
    install_program
    validate_program
    configure_permissions
    refresh_desktop_database

    log "Installation complete. Start USB Manager from the application menu or desktop shortcut, or run usb-manager."
    log "Added to the ntfsusb group; log out and back in (or restart the container) for it to take effect."
    log "Hardware access must be enabled when importing the Droidspaces container."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
