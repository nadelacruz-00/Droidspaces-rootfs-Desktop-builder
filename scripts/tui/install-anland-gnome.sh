#!/usr/bin/env bash
set -euo pipefail

# The package archives are deliberately kept out of Git. Override the
# repository when installing packages published by a fork.
readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${ANLAND_GNOME_RELEASE_REPOSITORY:-${ANLAND_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}}"
RELEASE_TAG="${ANLAND_GNOME_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-gnome-packages"
readonly MANIFEST_NAME="anland-gnome-manifest"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_STATE="/var/lib/anland-gnome/apt-holds"
readonly PACMAN_PACKAGE_STATE="/var/lib/anland-gnome/pacman-packages"
readonly COMPONENT_STATE_DIR="/var/lib/droidspaces-tui/components"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_GNOME_WORK_DIR:-}"
PREPARED_PACKAGE_DIR="${ANLAND_GNOME_PACKAGE_DIR:-}"
TARGET=""
ARCHIVE_PREFIX=""
ARCHIVE_SUFFIX=""
ARCHIVE_NAME=""
ARCHIVE_TARGET=""
PACKAGE_TYPE=""
PACKAGE_DIR=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
EXPECTED_MANIFEST_SHA256=""
EXPECTED_ARCHIVE_SHA256=""
OFFICIAL_RELEASE_METADATA=""
UNINSTALL=false

msg() {
    printf '%s' "$1"
}

log() {
    printf '[anland-gnome] %s\n' "$(msg "$1")"
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/gnome.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "Could not record the installed Mutter version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "Could not record the installed Mutter version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "Could not record the installed Mutter version."
    return 0
}

update_desktop_config() {
    local desktop="gnome" config_dir temporary_file line configured_desktop=""
    local desktop_lines=0

    config_dir="$(dirname -- "$DESKTOP_CONFIG")"
    if [[ ! -e "$DESKTOP_CONFIG" && ! -L "$DESKTOP_CONFIG" ]]; then
        if [[ ! -d "$config_dir" ]]; then
            install -d -m 0755 -- "$config_dir" || \
                die "Could not create the desktop configuration directory."
        fi
        temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
            die "Could not create a temporary desktop configuration."
        if ! printf 'DESKTOP=%s\n' "$desktop" > "$temporary_file" || \
            ! chmod 0644 "$temporary_file" || ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
            rm -f -- "$temporary_file" || true
            die "Could not create the desktop configuration."
        fi
        log "Created the desktop configuration with DESKTOP=${desktop}."
        return
    fi

    if [[ ! -f "$DESKTOP_CONFIG" || -L "$DESKTOP_CONFIG" || ! -r "$DESKTOP_CONFIG" ]]; then
        die "The desktop configuration is not a safely writable regular file: ${DESKTOP_CONFIG}."
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            DESKTOP=*)
                configured_desktop="${line#DESKTOP=}"
                ((desktop_lines += 1))
                ;;
        esac
    done < "$DESKTOP_CONFIG"
    if ((desktop_lines != 1)) || \
        [[ ! "$configured_desktop" =~ ^(none|[a-z][a-z0-9-]*)$ ]]; then
        die "The desktop configuration is invalid; the original file was not overwritten."
    fi
    if [[ "$configured_desktop" != none ]]; then
        log "Keeping the existing desktop configuration: DESKTOP=${configured_desktop}."
        return
    fi

    temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
        die "Could not create a temporary desktop configuration."
    if ! awk -v desktop="$desktop" '
        /^DESKTOP=/ { print "DESKTOP=" desktop; next }
        { print }
    ' "$DESKTOP_CONFIG" > "$temporary_file" || ! chmod 0644 "$temporary_file" || \
        ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
        rm -f -- "$temporary_file" || true
        die "Could not update the desktop configuration."
    fi
    log "Updated the desktop configuration to DESKTOP=${desktop}."
}

die() {
    printf '[anland-gnome] %s: %s\n' "$(msg 'Error')" "$(msg "$1")" >&2
    exit 1
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        case "$argument" in
            -1|--1)
                DOWNLOAD_SOURCE="1"
                SKIP_SOURCE_PROBE=true
                ;;
            -2|--2)
                DOWNLOAD_SOURCE="2"
                SKIP_SOURCE_PROBE=true
                ;;
            -3|--3)
                DOWNLOAD_SOURCE="3"
                SKIP_SOURCE_PROBE=true
                ;;
            --uninstall)
                UNINSTALL=true
                ;;
            *)
                die "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, -3/--3, and --uninstall."
                ;;
        esac
    done
}

uninstall_gnome_deb() {
    local package candidate
    local -a packages=() package_specs=()
    [[ -s "$APT_HOLD_STATE" ]] || {
        rm -f -- "$COMPONENT_STATE_DIR/gnome.version"
        log "No Anland GNOME installation record was found."
        return 0
    }
    command -v apt-cache >/dev/null 2>&1 || die "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "apt-get was not found."
    command -v apt-mark >/dev/null 2>&1 || die "apt-mark was not found."
    mapfile -t packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
    ((${#packages[@]} > 0)) || die "The APT hold list is empty."
    for package in "${packages[@]}"; do
        candidate="$(apt-cache madison "$package" | awk -F '|' 'NR == 1 {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }')"
        [[ -n "$candidate" ]] || \
            die "No distribution candidate was found for $package."
        package_specs+=("$package=$candidate")
    done
    apt-mark unhold "${packages[@]}" >/dev/null
    apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages \
        "${package_specs[@]}"
    rm -f -- "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/gnome.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
    log "Anland GNOME was uninstalled and distribution Mutter/Xwayland packages were restored."
}

uninstall_gnome_arch() {
    local package backup stripped
    local -a packages=()

    command -v pacman >/dev/null 2>&1 || die "pacman was not found."
    [[ -f /etc/pacman.conf ]] || die "pacman.conf was not found."
    if [[ -s "$PACMAN_PACKAGE_STATE" ]]; then
        mapfile -t packages < <(sed -nE 's/^([A-Za-z0-9@.+_-]+)$/\1/p' "$PACMAN_PACKAGE_STATE" | sort -u)
    else
        local ignored_package
        for ignored_package in mutter xorg-xwayland; do
            if awk -v package="$ignored_package" '
                /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
                    value = $0
                    sub(/^[^=]*=/, "", value)
                    count = split(value, entries, /[[:space:]]+/)
                    for (i = 1; i <= count; i++) if (entries[i] == package) found = 1
                }
                END { exit found ? 0 : 1 }
            ' /etc/pacman.conf; then
                packages+=("$ignored_package")
            fi
        done
        if ((${#packages[@]} == 0)); then
            rm -f -- "$COMPONENT_STATE_DIR/gnome.version"
            log "No Anland GNOME installation record was found."
            return 0
        fi
    fi
    ((${#packages[@]} > 0)) || die "The Arch package restore list is empty."

    backup="$(mktemp -t anland-gnome-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t anland-gnome-uninstall.XXXXXXXX)"
    cp -p -- /etc/pacman.conf "$backup"
    if ! awk -v remove_list="${packages[*]}" '
        BEGIN { remove_count = split(remove_list, remove_names, /[[:space:]]+/) }
        /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
            equals = index($0, "=")
            count = split(substr($0, equals + 1), items, /[[:space:]]+/)
            output = ""
            for (i = 1; i <= count; i++) {
                remove = 0
                for (j = 1; j <= remove_count; j++) {
                    if (items[i] == remove_names[j]) remove = 1
                }
                if (items[i] != "" && !remove) {
                    output = output (output == "" ? "" : " ") items[i]
                }
            }
            if (output != "") print substr($0, 1, equals) " " output
            next
        }
        { print }
    ' /etc/pacman.conf > "$stripped"; then
        rm -f -- "$backup" "$stripped"
        die "Could not process pacman.conf."
    fi
    if ! install -m 0644 -- "$stripped" /etc/pacman.conf || \
        ! pacman -S --noconfirm "${packages[@]}"; then
        install -m 0644 -- "$backup" /etc/pacman.conf || true
        rm -f -- "$backup" "$stripped"
        die "Failed to restore the distribution Mutter/Xwayland packages."
    fi

    rm -f -- "$backup" "$stripped" "$PACMAN_PACKAGE_STATE" \
        "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/gnome.version"
    rmdir -- "${PACMAN_PACKAGE_STATE%/*}" 2>/dev/null || true
    log "Anland GNOME was uninstalled and distribution Mutter/Xwayland packages were restored."
}

uninstall_gnome() {
    case "$PACKAGE_TYPE" in
        deb) uninstall_gnome_deb ;;
        pkg.tar.*) uninstall_gnome_arch ;;
        *) die "Could not determine the GNOME package type." ;;
    esac
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

    command -v sudo >/dev/null 2>&1 || die "Please run this script as root."
    log "Restarting the installer with sudo..."
    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    local status
    if sudo env \
        "ANLAND_GNOME_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_GNOME_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_GNOME_WORK_DIR=$WORK_DIR" \
        "ANLAND_GNOME_PACKAGE_DIR=$PACKAGE_DIR" \
        "DROIDSPACES_DESKTOP_CONFIG=$DESKTOP_CONFIG" \
        bash "$script_path" "$@"; then
        status=0
    else
        status=$?
    fi
    cleanup
    exit "$status"
}

detect_target() {
    [[ -r /etc/os-release ]] || die "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die "/etc/os-release does not contain ID."
    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    case "$distro_id" in
        arch|archarm|archlinux)
            TARGET="Arch Linux"
            PACKAGE_TYPE="pkg.tar.*"
            ARCHIVE_PREFIX="anland-gnome-arch-mutter-"
            ARCHIVE_SUFFIX="-aarch64.tar.gz"
            ARCHIVE_TARGET="arch"
            ;;
        *)
            [[ -n "$version_id" ]] || die "/etc/os-release does not contain VERSION_ID."
            case "$distro_id:$version_id" in
                debian:13*)
                    TARGET="Debian 13"
                    PACKAGE_TYPE="deb"
                    ARCHIVE_PREFIX="anland-gnome-debian13-mutter-"
                    ARCHIVE_SUFFIX="-arm64.tar.gz"
                    ARCHIVE_TARGET="debian13"
                    ;;
                ubuntu:26.04*)
                    TARGET="Ubuntu 26.04"
                    PACKAGE_TYPE="deb"
                    ARCHIVE_PREFIX="anland-gnome-ubuntu2604-mutter-"
                    ARCHIVE_SUFFIX="-arm64.tar.gz"
                    ARCHIVE_TARGET="ubuntu2604"
                    ;;
                *)
                    die "Unsupported system: ${system_name}. Supported systems are Debian 13, Ubuntu 26.04, and Arch Linux ARM."
                    ;;
            esac
            ;;
    esac

    log "Detected system: ${system_name} -> ${TARGET}"
}

check_architecture() {
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            die "The prebuilt packages support ARM64/aarch64 only; current architecture is $(uname -m)."
            ;;
    esac
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O "$destination" "$url"
    else
        die "Neither curl nor wget was found; packages cannot be downloaded."
    fi
}

download_stdout() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 60 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O - "$url"
    else
        die "Neither curl nor wget was found; Release information cannot be read."
    fi
}

validate_release_tag() {
    case "$RELEASE_TAG" in
        "$ROLLING_RELEASE_TAG") ;;
        *)
            die "The Release tag must be ${ROLLING_RELEASE_TAG}."
            ;;
    esac
}

validate_repository() {
    if [[ ! "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        die "The Release repository must use the owner/repository format."
    fi
}

resolve_release_tag() {
    validate_repository
    if [[ -z "$RELEASE_TAG" ]]; then
        RELEASE_TAG="$ROLLING_RELEASE_TAG"
    fi
    validate_release_tag
    log "Using rolling Release: ${RELEASE_TAG}"
}

resolve_archive_name() {
    local manifest_file="$1"
    local manifest_format manifest_release_tag selected_name checksum_key checksum_count checksum

    manifest_format="$(awk -F= '$1 == "format" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    manifest_release_tag="$(awk -F= '$1 == "release_tag" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    [[ "$manifest_format" == "1" && "$manifest_release_tag" == "$RELEASE_TAG" ]] || {
        log "The Release manifest format is invalid."
        return 1
    }

    selected_name="$(awk -F= -v key="$ARCHIVE_TARGET" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    case "$selected_name" in
        "${ARCHIVE_PREFIX}"*"${ARCHIVE_SUFFIX}") ;;
        *)
            log "The Release manifest has no matching ARM64 archive for ${TARGET}."
            return 1
            ;;
    esac
    if [[ ! "$selected_name" =~ ^[A-Za-z0-9._+~_-]+$ || "$selected_name" == *..* ]]; then
        log "The archive name in the Release manifest is invalid."
        return 1
    fi

    ARCHIVE_NAME="$selected_name"
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "3" ]]; then
        checksum_key="${ARCHIVE_TARGET}_sha256"
        checksum_count="$(awk -F= -v key="$checksum_key" '$1 == key { count += 1 } END { print count + 0 }' "$manifest_file")" || return 1
        case "$checksum_count" in
            0)
                log "The legacy CNB Release manifest has no SHA-256 for ${ARCHIVE_NAME}; only archive structure and package metadata will be verified."
                ;;
            1)
                checksum="$(awk -F= -v key="$checksum_key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file")" || return 1
                [[ "$checksum" =~ ^[0-9A-Fa-f]{64}$ ]] || {
                    log "The CNB Release manifest has an invalid SHA-256 for ${ARCHIVE_NAME}."
                    return 1
                }
                EXPECTED_ARCHIVE_SHA256="${checksum,,}"
                ;;
            *)
                log "The CNB Release manifest has multiple SHA-256 entries for ${ARCHIVE_NAME}."
                return 1
                ;;
        esac
    fi
    log "Selected ${ARCHIVE_NAME}"
}

fetch_official_release_metadata() {
    local api_url

    api_url="${GITHUB_API_URL}/repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}"
    if ! OFFICIAL_RELEASE_METADATA="$(download_stdout "$api_url")"; then
        log "Could not obtain GitHub's official SHA-256 digest; refusing the third-party mirror package."
        return 1
    fi
}

release_asset_sha256() {
    local requested_name="$1"
    local digest

    if ! digest="$(jq -er --arg name "$requested_name" --arg tag "$RELEASE_TAG" '
        if .tag_name != $tag then
            error("release tag mismatch")
        else
            [.assets[] | select(.name == $name) | .digest] |
            if length == 1 then .[0] else error("asset digest is not unique") end
        end
    ' <<< "$OFFICIAL_RELEASE_METADATA" 2>/dev/null)"; then
        return 1
    fi
    if [[ ! "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        return 1
    fi

    printf '%s' "${BASH_REMATCH[1],,}"
}

resolve_official_manifest_sha256() {
    EXPECTED_MANIFEST_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi
    command -v jq >/dev/null 2>&1 || \
        die "Selecting a third-party mirror requires jq to verify the GitHub Release."
    command -v sha256sum >/dev/null 2>&1 || \
        die "Selecting a third-party mirror requires sha256sum to verify downloaded files."
    if ! fetch_official_release_metadata; then
        return 1
    fi
    if ! EXPECTED_MANIFEST_SHA256="$(release_asset_sha256 "$MANIFEST_NAME")"; then
        log "GitHub Release did not provide a SHA-256 digest for ${MANIFEST_NAME}; refusing the third-party mirror package."
        return 1
    fi
}

resolve_official_archive_sha256() {
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi
    if EXPECTED_ARCHIVE_SHA256="$(release_asset_sha256 "$ARCHIVE_NAME")"; then
        return
    fi
    log "GitHub Release did not provide a SHA-256 digest for ${ARCHIVE_NAME}; refusing the third-party mirror package."
    return 1
}

release_download_base() {
    case "$DOWNLOAD_SOURCE" in
        1) printf '%s/%s/releases/download/%s' "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        2) printf '%s/%s/releases/download/%s' "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        3) printf '%s/%s/-/releases/download/%s' "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        *) die "The selected download source is invalid." ;;
    esac
}

download_source_name() {
    case "$1" in
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'CNB' ;;
        *) return 1 ;;
    esac
}

download_source_probe_url() {
    local source="$1"

    case "$source" in
        1)
            printf '%s/%s/releases/download/%s/%s' \
                "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        2)
            printf '%s/%s/releases/download/%s/%s' \
                "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        3)
            printf '%s/%s/-/releases/download/%s/%s' \
                "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        *) return 1 ;;
    esac
}

format_latency() {
    local seconds="$1"

    awk -v seconds="$seconds" 'BEGIN { printf "%d ms", (seconds * 1000) + 0.5 }'
}

probe_download_source() {
    local source="$1"
    local probe_url latency started finished probe_status=0
    local -a probe_command

    probe_url="$(download_source_probe_url "$source")" || return 1
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
            --max-time "$SOURCE_PROBE_TIMEOUT_SECONDS" --output /dev/null \
            --write-out '%{time_total}' "$probe_url" 2>/dev/null)"; then
            if awk -v seconds="$latency" -v limit="$SOURCE_PROBE_TIMEOUT_SECONDS" \
                'BEGIN { exit (seconds < limit ? 0 : 1) }'; then
                format_latency "$latency"
                return
            fi
            printf '%s' "$(msg 'timeout')"
            return
        else
            probe_status=$?
        fi
    elif command -v wget >/dev/null 2>&1; then
        command -v timeout >/dev/null 2>&1 || \
            die "Testing download sources with wget requires timeout to enforce the ${SOURCE_PROBE_TIMEOUT_SECONDS}-second limit."
        started="$(date +%s%3N 2>/dev/null || true)"
        probe_command=(wget -q --tries=1 --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$probe_url")
        probe_command=(timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" "${probe_command[@]}")
        if "${probe_command[@]}"; then
            finished="$(date +%s%3N 2>/dev/null || true)"
            if [[ "$started" =~ ^[0-9]+$ && "$finished" =~ ^[0-9]+$ ]]; then
                if (( finished - started < SOURCE_PROBE_TIMEOUT_SECONDS * 1000 )); then
                    printf '%d ms' "$((finished - started))"
                else
                    printf '%s' "$(msg 'timeout')"
                fi
            else
                printf '%s' "$(msg 'available')"
            fi
            return
        else
            probe_status=$?
        fi
    else
        die "Neither curl nor wget was found; download sources cannot be tested."
    fi

    if (( probe_status == 28 || probe_status == 124 )); then
        printf '%s' "$(msg 'timeout')"
    else
        printf '%s' "$(msg 'unavailable')"
    fi
}

select_download_source() {
    local source latency choice recommendation

    if [[ "$SKIP_SOURCE_PROBE" == true ]]; then
        log "Selected $(download_source_name "$DOWNLOAD_SOURCE") from the command line; skipping latency checks."
        return
    fi

    log "Testing download-source latency (timeouts at ${SOURCE_PROBE_TIMEOUT_SECONDS} seconds)..."
    for source in 1 2 3; do
        latency="$(probe_download_source "$source")"
        recommendation=""
        if [[ "$source" == "3" ]]; then
            recommendation="$(msg ' (recommended)')"
        fi
        printf '%s. %s%s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$recommendation" "$(msg 'latency')" "$latency"
    done

    while :; do
        printf '%s' "$(msg 'Choose a download source [1-3]: ')"
        if ! IFS= read -r choice; then
            die "Unable to read a download-source choice. Specify -1/--1, -2/--2, or -3/--3."
        fi
        case "$choice" in
            1|2|3)
                DOWNLOAD_SOURCE="$choice"
                return
                ;;
            *)
                log "Enter 1, 2, or 3."
                ;;
        esac
    done
}

has_packages() {
    local directory="$1"
    case "$PACKAGE_TYPE" in
        deb) compgen -G "$directory/*.deb" >/dev/null ;;
        pkg.tar.*) compgen -G "$directory/*.pkg.tar.*" >/dev/null ;;
        *) return 1 ;;
    esac
}

require_runtime_dependencies() {
    local command_name
    for command_name in awk du find mktemp realpath sha256sum sort stat tar; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "The installer requires the missing command: ${command_name}."
    done

    case "$PACKAGE_TYPE" in
        deb) command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb was not found." ;;
        pkg.tar.*) command -v pacman >/dev/null 2>&1 || die "pacman was not found." ;;
        *) die "Could not determine the GNOME package type." ;;
    esac
}

validate_archive_contents() {
    local archive_file="$1"
    local archive_size members entry

    if ! archive_size="$(stat -c '%s' "$archive_file")" || ! [[ "$archive_size" =~ ^[0-9]+$ ]]; then
        log "Unable to read the downloaded archive size."
        return 1
    fi
    if (( archive_size > MAX_ARCHIVE_BYTES )); then
        log "The downloaded archive exceeds the allowed size."
        return 1
    fi
    if ! members="$(tar -tzf "$archive_file")" || [[ -z "$members" ]]; then
        log "The downloaded archive is not a valid non-empty tar.gz file."
        return 1
    fi
    while IFS= read -r entry; do
        case "$entry" in
            /*|.|./*|..|../*|*/.|*/./*|*/..|*/../*)
                log "The downloaded archive contains an unsafe path."
                return 1
                ;;
            "anland-gnome-packages/${ARCHIVE_TARGET}/"*) ;;
            *)
                log "The downloaded archive contains files outside the target system directory."
                return 1
                ;;
        esac
    done <<< "$members"

    if ! LC_ALL=C tar -tvzf "$archive_file" | awk -v maximum="$MAX_EXTRACTED_BYTES" '
        {
            entry_type = substr($1, 1, 1)
            if (entry_type !~ /^[-d]$/ || $3 !~ /^[0-9]+$/) {
                exit 1
            }
            total += $3
            if (total > maximum) {
                exit 1
            }
        }
    '; then
        log "The downloaded archive has a disallowed entry or exceeds the extraction size limit."
        return 1
    fi
}

validate_release_asset_checksum() {
    local asset_file="$1"
    local expected_checksum="$2"
    local asset_name="$3"
    local actual_checksum

    if ! actual_checksum="$(sha256sum "$asset_file" | awk '{print $1}')" || \
        ! [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ ]] || \
        [[ "$actual_checksum" != "$expected_checksum" ]]; then
        log "Downloaded ${asset_name} failed SHA-256 verification."
        return 1
    fi
}

validate_package_architecture() {
    local -a files=()
    local file package_arch package_name mutter_count=0 xwayland_count=0 package_info

    case "$PACKAGE_TYPE" in
        deb)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(dpkg-deb -f "$file" Architecture)" || return 1
                case "$package_arch" in arm64|all) ;; *) return 1 ;; esac
            done
            ((${#files[@]} > 0))
            ;;
        pkg.tar.*)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
            for file in "${files[@]}"; do
                package_info="$(LC_ALL=C pacman -Qip "$file")" || return 1
                package_name="$(awk -F: '/^[[:space:]]*Name[[:space:]]*:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }' <<< "$package_info")"
                package_arch="$(awk -F: '/^[[:space:]]*Architecture[[:space:]]*:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }' <<< "$package_info")"
                [[ "$package_name" =~ ^[A-Za-z0-9@.+_-]+$ ]] || return 1
                case "$package_arch" in aarch64|any) ;; *) return 1 ;; esac
                case "$package_name" in
                    mutter) ((mutter_count += 1)) ;;
                    xorg-xwayland) ((xwayland_count += 1)) ;;
                    *) return 1 ;;
                esac
            done
            (( ${#files[@]} == 2 && mutter_count == 1 && xwayland_count == 1 ))
            ;;
        *) return 1 ;;
    esac
}

download_packages_once() {
    local base_url manifest_file archive_file extracted_size

    base_url="$(release_download_base)"
    manifest_file="$WORK_DIR/$MANIFEST_NAME"
    OFFICIAL_RELEASE_METADATA=""
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        resolve_official_manifest_sha256 || return 1
    fi

    log "Downloading ${TARGET} prebuilt packages from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$base_url/$MANIFEST_NAME" "$manifest_file" || return 1
    if [[ -n "$EXPECTED_MANIFEST_SHA256" ]]; then
        validate_release_asset_checksum "$manifest_file" "$EXPECTED_MANIFEST_SHA256" "$MANIFEST_NAME" || return 1
    fi
    resolve_archive_name "$manifest_file" || return 1
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        resolve_official_archive_sha256 || return 1
    fi

    archive_file="$WORK_DIR/$ARCHIVE_NAME"
    download_file "$base_url/$ARCHIVE_NAME" "$archive_file" || return 1
    if [[ -n "$EXPECTED_ARCHIVE_SHA256" ]]; then
        validate_release_asset_checksum "$archive_file" "$EXPECTED_ARCHIVE_SHA256" "$ARCHIVE_NAME" || return 1
    fi
    validate_archive_contents "$archive_file" || return 1
    if ! tar --no-same-owner --no-same-permissions -xzf "$archive_file" -C "$WORK_DIR"; then
        log "Unable to safely extract the downloaded archive."
        return 1
    fi

    PACKAGE_DIR="$WORK_DIR/anland-gnome-packages/$ARCHIVE_TARGET"
    has_packages "$PACKAGE_DIR" || {
        log "Could not obtain packages for ${TARGET}."
        return 1
    }
    if ! extracted_size="$(du -sb "$PACKAGE_DIR" | awk '{print $1}')" || ! [[ "$extracted_size" =~ ^[0-9]+$ ]] || (( extracted_size > MAX_EXTRACTED_BYTES )); then
        log "The extracted package size is invalid or exceeds the limit."
        return 1
    fi
    if ! validate_package_architecture; then
        log "The package architecture in the archive does not match this system."
        return 1
    fi
}

download_packages() {
    local attempt
    WORK_DIR="$(mktemp -d -t anland-gnome.XXXXXXXX)"

    for ((attempt = 1; attempt <= 3; attempt++)); do
        if (( attempt > 1 )); then
            rm -rf -- "$WORK_DIR"
            mkdir -m 700 -- "$WORK_DIR"
        fi
        if download_packages_once; then
            return
        fi
        if (( attempt < 3 )); then
            log "The Release is being updated or the network failed; retrying after attempt ${attempt}."
            sleep "$attempt"
        fi
    done

    die "Unable to consistently download the Release package; please retry later."
}

use_prepared_packages() {
    local prepared_work_dir prepared_package_dir

    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || \
        die "The pre-downloaded package directory is invalid."
    prepared_package_dir="$(realpath -e "$PREPARED_PACKAGE_DIR")" || \
        die "The pre-downloaded package directory is invalid."
    [[ "$prepared_work_dir" =~ ^/tmp/anland-gnome\.[A-Za-z0-9]+$ ]] || \
        die "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_dir" == "$prepared_work_dir/anland-gnome-packages/$ARCHIVE_TARGET" ]] || \
        die "The pre-downloaded package target does not match this system."
    [[ -d "$prepared_work_dir" && -d "$prepared_package_dir" ]] || \
        die "The pre-downloaded package directory no longer exists."

    WORK_DIR="$prepared_work_dir"
    PACKAGE_DIR="$prepared_package_dir"
    has_packages "$PACKAGE_DIR" || die "The pre-downloaded directory has no installable packages."
    validate_package_architecture || \
        die "The pre-downloaded package architecture does not match this system."
}

clear_stale_apt_holds() {
    local -a current_packages=("$@") previous_packages=()
    local previous current keep

    [[ -r "$APT_HOLD_STATE" ]] || return 0
    mapfile -t previous_packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
    for previous in "${previous_packages[@]}"; do
        keep=false
        for current in "${current_packages[@]}"; do
            if [[ "$previous" == "$current" ]]; then
                keep=true
                break
            fi
        done
        if [[ "$keep" == false ]]; then
            apt-mark unhold "$previous" >/dev/null 2>&1 || true
        fi
    done
}

write_apt_hold_state() {
    install -d -m 0755 "$(dirname "$APT_HOLD_STATE")"
    printf '%s\n' "$@" | sort -u > "$APT_HOLD_STATE"
}

install_deb_packages() {
    local -a files packages
    local file package

    command -v apt-get >/dev/null 2>&1 || die "apt-get was not found."
    command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
    ((${#files[@]} > 0)) || die "No installable deb packages were found."

    log "Installing ${#files[@]} deb packages and resolving dependencies..."
    apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages "${files[@]}"

    for file in "${files[@]}"; do
        package="$(dpkg-deb -f "$file" Package)"
        [[ -n "$package" ]] && packages+=("$package")
    done
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "Could not determine the deb package names."

    clear_stale_apt_holds "${packages[@]}"
    log "Applying APT holds..."
    apt-mark hold "${packages[@]}"
    write_apt_hold_state "${packages[@]}"
    printf '  hold: %s\n' "${packages[@]}"
}

append_pacman_ignore_packages() {
    local package
    for package in "$@"; do
        [[ "$package" =~ ^[A-Za-z0-9@.+_-]+$ ]] || \
            die "The Arch package name is invalid."
        if awk -v package="$package" '
            $1 == "IgnorePkg" {
                for (i = 3; i <= NF; i++) if ($i == package) found = 1
            }
            END { exit found ? 0 : 1 }
        ' /etc/pacman.conf; then
            continue
        fi
        if grep -qE '^[[:space:]]*IgnorePkg[[:space:]]*=' /etc/pacman.conf; then
            sed -i -E "0,/^[[:space:]]*IgnorePkg[[:space:]]*=/{s/^([[:space:]]*IgnorePkg[[:space:]]*=.*)$/\\1 ${package}/}" /etc/pacman.conf
        elif grep -qE '^\[options\][[:space:]]*$' /etc/pacman.conf; then
            sed -i "/^\[options\][[:space:]]*$/a IgnorePkg = ${package}" /etc/pacman.conf
        else
            die "pacman.conf has no [options] section."
        fi
    done
}

write_pacman_package_state() {
    local state_dir temporary_file
    state_dir="${PACMAN_PACKAGE_STATE%/*}"
    install -d -m 0755 "$state_dir"
    temporary_file="$(mktemp "$PACMAN_PACKAGE_STATE.tmp.XXXXXXXX")" || \
        die "Could not record the Arch Mutter/Xwayland packages."
    if ! printf '%s\n' "$@" | sort -u > "$temporary_file" || \
        ! chmod 0644 "$temporary_file" || ! mv -f -- "$temporary_file" "$PACMAN_PACKAGE_STATE"; then
        rm -f -- "$temporary_file"
        die "Could not record the Arch Mutter/Xwayland packages."
    fi
}

install_arch_packages() {
    local file package_name pacman_conf mutter_count=0 xwayland_count=0
    local -a archive_files=() files=() packages=()

    command -v pacman >/dev/null 2>&1 || die "pacman was not found."
    mapfile -t archive_files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    for file in "${archive_files[@]}"; do
        package_name="$(LC_ALL=C pacman -Qp "$file" | awk 'NR == 1 { print $1 }')" || \
            die "Could not read an Arch package name."
        case "$package_name" in
            mutter)
                files+=("$file")
                packages+=(mutter)
                ((mutter_count += 1))
                ;;
            xorg-xwayland)
                files+=("$file")
                packages+=(xorg-xwayland)
                ((xwayland_count += 1))
                ;;
            *)
                die "The Arch GNOME archive contains an unsupported package: $package_name."
                ;;
        esac
    done
    if ((${#files[@]} != 2 || mutter_count != 1 || xwayland_count != 1)); then
        die "The archive must contain one Mutter and one patched Xwayland package."
    fi

    pacman_conf="$(mktemp -t anland-gnome-pacman.XXXXXXXX)"
    cp /etc/pacman.conf "$pacman_conf"
    if grep -Eq '^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=' "$pacman_conf"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=.*/LocalFileSigLevel = Optional/' "$pacman_conf"
    elif grep -qE '^\[options\][[:space:]]*$' "$pacman_conf"; then
        sed -i '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' "$pacman_conf"
    else
        rm -f -- "$pacman_conf"
        die "pacman.conf has no [options] section."
    fi
    if ! pacman --config "$pacman_conf" -U --noconfirm "${files[@]}"; then
        rm -f -- "$pacman_conf"
        die "Failed to install the Arch Mutter/Xwayland packages."
    fi
    rm -f -- "$pacman_conf"

    if ! pacman -Q "${packages[@]}" >/dev/null; then
        die "Could not verify that the Arch Mutter/Xwayland packages were installed."
    fi
    append_pacman_ignore_packages "${packages[@]}"
    write_pacman_package_state "${packages[@]}"
    rm -f -- "$APT_HOLD_STATE"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
    printf '  IgnorePkg: %s\n' "${packages[@]}"
}

main() {
    local archive_version
    parse_arguments "$@"
    detect_target
    check_architecture
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        uninstall_gnome
        return
    fi
    require_runtime_dependencies
    resolve_release_tag
    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_PACKAGE_DIR" ]]; then
        use_prepared_packages
    else
        select_download_source
        download_packages
    fi
    require_root "$@"

    case "$PACKAGE_TYPE" in
        deb) install_deb_packages ;;
        pkg.tar.*) install_arch_packages ;;
        *) die "Could not determine the GNOME package type." ;;
    esac

    if [[ -n "$ARCHIVE_NAME" ]]; then
        archive_version="${ARCHIVE_NAME#"$ARCHIVE_PREFIX"}"
        archive_version="${archive_version%"$ARCHIVE_SUFFIX"}"
    elif [[ "$PACKAGE_TYPE" == "pkg.tar.*" ]]; then
        archive_version="$(pacman -Q mutter | awk 'NR == 1 { print $2 }')"
    fi
    record_component_version "$archive_version"
    update_desktop_config
    log "Installation complete; patched Mutter is now locked."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
