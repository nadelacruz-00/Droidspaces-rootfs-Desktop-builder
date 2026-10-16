#!/usr/bin/env bash
set -euo pipefail

# Mesa source repository: https://github.com/lfdevs/mesa-for-android-container
# Media decode source repository: https://github.com/Re-s/droidspaces-media-decode
# Distribution URL: https://github.com/Goldzxcbug/droidspaces-package/releases/tag/mesa-for-android-container
# Installs ARM64 Mesa builds for Android containers.
# Also installs the MediaCodec VA-API driver published by droidspaces-media-decode.
# Selects the Mesa archive format and package manager based on /etc/os-release.
readonly RELEASE_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly CNB_RELEASE_REPOSITORY="goldzxcbug/droidspaces-package"
readonly DISTRIBUTION_TAG="mesa-for-android-container"
readonly DISTRIBUTION_MANIFEST_NAME="mesa-distribution-manifest"
readonly MESA_API_URL="https://api.github.com/repos/${RELEASE_REPOSITORY}/releases/tags/${DISTRIBUTION_TAG}"
readonly MEDIA_DECODE_API_URL="$MESA_API_URL"
readonly MEDIA_DRIVER_NAME="msm_drm_drv_video.so"
readonly MEDIA_CHECKSUMS_NAME="SHA256SUMS"
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_PREFERENCES="/etc/apt/preferences.d/hold-anland-package"
readonly DNF_CONFIG="/etc/dnf/dnf.conf"
readonly DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly DNF_MANAGED_END="# END install-mesa package holds"
readonly PACMAN_CONFIG="/etc/pacman.conf"
readonly PACMAN_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly PACMAN_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly COMPONENT_STATE_DIR="/var/lib/droidspaces-tui/components"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly MAX_MEDIA_DRIVER_BYTES=$((16 * 1024 * 1024))
readonly MAX_MANIFEST_BYTES=$((1024 * 1024))
readonly MAX_CHECKSUMS_BYTES=$((1024 * 1024))

TARGET=""
PACKAGE_MANAGER=""
ASSET_PATTERN=""
ARCHIVE_KIND=""
WORK_DIR=""
ARCHIVE_FILE=""
ARCHIVE_NAME=""
RELEASE_TAG=""
DOWNLOAD_URL=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
CNB_MANIFEST_FILE=""
OFFICIAL_DOWNLOAD_URL=""
OFFICIAL_ARCHIVE_DIGEST=""
EXPECTED_ARCHIVE_SIZE=""
EXPECTED_ARCHIVE_SHA256=""
MEDIA_RELEASE_TAG=""
MEDIA_DRIVER_DOWNLOAD_URL=""
MEDIA_DRIVER_RELEASE_DIGEST=""
MEDIA_DRIVER_RELEASE_SIZE=""
MEDIA_CHECKSUMS_DOWNLOAD_URL=""
MEDIA_CHECKSUMS_RELEASE_DIGEST=""
MEDIA_CHECKSUMS_RELEASE_SIZE=""
MEDIA_DRIVER_FILE=""
MEDIA_CHECKSUMS_FILE=""
MEDIA_DRIVER_TEMP_FILE=""
MEDIA_DRIVER_INSTALL_DIR=""
MEDIA_DRIVER_INSTALL_PATH=""
MESA_PACKAGE_NAMES=()
UNINSTALL=false

msg() {
    printf '%s' "$1"
}

log() {
    printf '[install-mesa] %s\n' "$(msg "$1")"
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/mesa.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "Could not record the installed Mesa version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "Could not record the installed Mesa version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "Could not record the installed Mesa version."
    return 0
}

mesa_archive_version() {
    local version="${ARCHIVE_NAME#mesa-for-android-container_}"
    case "$version" in
        *_archlinux_arm64.tar) version="${version%_archlinux_arm64.tar}" ;;
        *_debian_trixie_arm64.tar.gz) version="${version%_debian_trixie_arm64.tar.gz}" ;;
        *_ubuntu_noble_arm64.tar.gz) version="${version%_ubuntu_noble_arm64.tar.gz}" ;;
        *_ubuntu_questing_arm64.tar.gz) version="${version%_ubuntu_questing_arm64.tar.gz}" ;;
        *_ubuntu_resolute_arm64.tar.gz) version="${version%_ubuntu_resolute_arm64.tar.gz}" ;;
        *_fedora_43_arm64.tar.gz) version="${version%_fedora_43_arm64.tar.gz}" ;;
        *_fedora_44_arm64.tar.gz) version="${version%_fedora_44_arm64.tar.gz}" ;;
        *) return 1 ;;
    esac
    printf '%s' "$version"
}

die() {
    printf '[install-mesa] %s: %s\n' \
        "$(msg 'Error')" "$(msg "$1")" >&2
    exit 1
}

usage() {
    cat <<EOF
$(msg 'Usage'): $0

  -1, --1       $(msg 'Use GitHub and skip latency checks.')
  -2, --2       $(msg 'Use gh-proxy.com and skip latency checks.')
  -3, --3       $(msg 'Use the CNB mirror and skip latency checks.')
  --uninstall   $(msg 'Uninstall custom drivers and restore distribution Mesa')
  -h, --help    $(msg 'Show this help.')

$(msg 'Without a source option, all three sources are probed before prompting.')
EOF
}

set_download_source_argument() {
    local source="$1"

    if [[ -n "$DOWNLOAD_SOURCE" && "$DOWNLOAD_SOURCE" != "$source" ]]; then
        die "Conflicting download-source options were provided."
    fi
    DOWNLOAD_SOURCE="$source"
    SKIP_SOURCE_PROBE=true
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        case "$argument" in
            -1|--1)
                set_download_source_argument "1"
                ;;
            -2|--2)
                set_download_source_argument "2"
                ;;
            -3|--3)
                set_download_source_argument "3"
                ;;
            --uninstall)
                UNINSTALL=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, and -3/--3."
                ;;
        esac
    done
}

uninstall_mesa_apt() {
    local package candidate backup=""
    local -a packages=(libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers)
    local -a package_specs=()
    command -v apt-cache >/dev/null 2>&1 || die "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "apt-get was not found."
    if [[ -e "$APT_HOLD_PREFERENCES" ]]; then
        [[ -f "$APT_HOLD_PREFERENCES" && ! -L "$APT_HOLD_PREFERENCES" ]] || \
            die "The Mesa hold configuration path is invalid."
        grep -Fqx '# /etc/apt/preferences.d/hold-anland-package' "$APT_HOLD_PREFERENCES" && \
            grep -Fqx 'Pin-Priority: -1' "$APT_HOLD_PREFERENCES" || \
            die \
                "The Mesa hold configuration was modified; refusing to remove it automatically."
        backup="$(mktemp -t install-mesa-apt-hold.XXXXXXXX)"
        cp -p -- "$APT_HOLD_PREFERENCES" "$backup"
        rm -f -- "$APT_HOLD_PREFERENCES"
    fi
    for package in "${packages[@]}"; do
        candidate="$(apt-cache madison "$package" | awk -F '|' 'NR == 1 {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }')"
        if [[ -z "$candidate" ]]; then
            [[ -z "$backup" ]] || install -m 0644 "$backup" "$APT_HOLD_PREFERENCES"
            rm -f -- "$backup"
            die "No distribution candidate was found for $package."
        fi
        package_specs+=("$package=$candidate")
    done
    if ! apt-get install -y --reinstall --allow-downgrades "${package_specs[@]}"; then
        [[ -z "$backup" ]] || install -m 0644 "$backup" "$APT_HOLD_PREFERENCES"
        rm -f -- "$backup"
        die "Failed to restore distribution Mesa packages."
    fi
    rm -f -- "$backup"
}

uninstall_mesa_dnf() {
    local backup stripped package
    local -a packages=()
    command -v dnf >/dev/null 2>&1 || die "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "rpm was not found."
    [[ -f "$DNF_CONFIG" ]] || die "The DNF configuration was not found."
    mapfile -t packages < <(rpm -qa --queryformat '%{NAME}\n' | awk '/^mesa/ { print }' | sort -u)
    ((${#packages[@]} > 0)) || die "No installed Mesa packages were found."
    backup="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    cp -p -- "$DNF_CONFIG" "$backup"
    WORK_DIR="$(mktemp -d -t install-mesa-uninstall.XXXXXXXX)"
    if ! rewrite_without_managed_block \
        "$DNF_CONFIG" "$stripped" "$DNF_MANAGED_BEGIN" "$DNF_MANAGED_END" || \
        ! install -m 0644 "$stripped" "$DNF_CONFIG" || \
        ! dnf distro-sync -y --exclude='systemd*' "${packages[@]}"; then
        install -m 0644 "$backup" "$DNF_CONFIG" || true
        rm -f -- "$backup" "$stripped"
        die "Failed to restore distribution Mesa packages."
    fi
    rm -f -- "$backup" "$stripped"
}

uninstall_mesa_pacman() {
    local backup stripped protected preserve_kde=false
    local -a packages=()
    command -v pacman >/dev/null 2>&1 || die "pacman was not found."
    [[ -f "$PACMAN_CONFIG" ]] || die "pacman.conf was not found."
    mapfile -t packages < <(awk -v begin="$PACMAN_MANAGED_BEGIN" -v end="$PACMAN_MANAGED_END" '
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        inside && $1 == "IgnorePkg" {
            for (i = 3; i <= NF; i++) {
                if ($i !~ /^systemd(-libs|-sysvcompat)?$/ && \
                    $i != "kwin" && $i != "xorg-xwayland") print $i
            }
        }
    ' "$PACMAN_CONFIG" | sort -u)
    ((${#packages[@]} > 0)) || packages=(mesa)
    backup="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    protected="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    cp -p -- "$PACMAN_CONFIG" "$backup"
    WORK_DIR="$(mktemp -d -t install-mesa-uninstall.XXXXXXXX)"
    if grep -Eq '^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])kwin([[:space:]]|$)' \
        "$PACMAN_CONFIG"; then
        preserve_kde=true
    fi
    if ! rewrite_without_managed_block \
        "$PACMAN_CONFIG" "$stripped" "$PACMAN_MANAGED_BEGIN" "$PACMAN_MANAGED_END"; then
        rm -f -- "$backup" "$stripped" "$protected"
        die "Failed to remove the Mesa hold configuration."
    fi
    if [[ "$preserve_kde" == true ]] && \
        ! grep -Eq '^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])kwin([[:space:]]|$)' "$stripped"; then
        awk '
            { print }
            /^\[options\][[:space:]]*$/ && !added {
                print "IgnorePkg = kwin xorg-xwayland"
                added = 1
            }
            END { if (!added) exit 1 }
        ' "$stripped" > "$protected" || {
            rm -f -- "$backup" "$stripped" "$protected"
            die "Failed to preserve the Anland KDE hold."
        }
    else
        cp -- "$stripped" "$protected"
    fi
    if ! install -m 0644 "$protected" "$PACMAN_CONFIG" || \
        ! pacman -S --noconfirm "${packages[@]}"; then
        install -m 0644 "$backup" "$PACMAN_CONFIG" || true
        rm -f -- "$backup" "$stripped" "$protected"
        die "Failed to restore distribution Mesa packages."
    fi
    rm -f -- "$backup" "$stripped" "$protected"
}

uninstall_mesa() {
    case "$PACKAGE_MANAGER" in
        apt) uninstall_mesa_apt ;;
        dnf) uninstall_mesa_dnf ;;
        pacman) uninstall_mesa_pacman ;;
    esac
    rm -f -- "$MEDIA_DRIVER_INSTALL_PATH" "$COMPONENT_STATE_DIR/mesa.version"
    command -v ldconfig >/dev/null 2>&1 && ldconfig || true
    log \
        "Custom Mesa/MediaCodec drivers were uninstalled and distribution Mesa was restored."
}

cleanup() {
    if [[ -n "$MEDIA_DRIVER_TEMP_FILE" && -e "$MEDIA_DRIVER_TEMP_FILE" ]]; then
        rm -f -- "$MEDIA_DRIVER_TEMP_FILE"
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || die \
        "Please run this script as root."
    log "Restarting the installer with sudo..."

    local script_path="${BASH_SOURCE[0]}"
    if [[ "$script_path" != /* ]]; then
        script_path="$PWD/$script_path"
    fi
    exec sudo --preserve-env=LANG,LC_ALL,LC_MESSAGES -- bash "$script_path" "$@"
}

media_driver_install_dir_for_target() {
    case "$1" in
        debian|ubuntu) printf '/usr/lib/aarch64-linux-gnu/dri' ;;
        fedora) printf '/usr/lib64/dri' ;;
        arch|archarm|archlinux) printf '/usr/lib/dri' ;;
        *) return 1 ;;
    esac
}

detect_target() {
    [[ -r /etc/os-release ]] || die \
        "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die \
        "/etc/os-release does not contain ID."

    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    TARGET=""
    PACKAGE_MANAGER=""
    ASSET_PATTERN=""
    ARCHIVE_KIND=""

    case "$distro_id" in
        arch|archarm|archlinux)
            TARGET="Arch Linux"
            PACKAGE_MANAGER="pacman"
            ARCHIVE_KIND="tar"
            ASSET_PATTERN='^mesa-for-android-container_[^/]+_archlinux_arm64\.tar$'
            ;;
        debian)
            case "$version_id" in
                13*)
                    TARGET="Debian 13"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_debian_trixie_arm64\.tar\.gz$'
                    ;;
                *)
                    die \
                        "Unsupported system: ${system_name}. Only Debian 13 is supported."
                    ;;
            esac
            ;;
        ubuntu)
            case "$version_id" in
                24.04*)
                    TARGET="Ubuntu 24.04"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_noble_arm64\.tar\.gz$'
                    ;;
                25.10*)
                    TARGET="Ubuntu 25.10"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_questing_arm64\.tar\.gz$'
                    ;;
                26.04*)
                    TARGET="Ubuntu 26.04"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_resolute_arm64\.tar\.gz$'
                    ;;
                *)
                    die \
                        "Unsupported system: ${system_name}. Only Ubuntu 24.04, 25.10, and 26.04 are supported."
                    ;;
            esac
            ;;
        fedora)
            case "$version_id" in
                43*)
                    TARGET="Fedora 43"
                    PACKAGE_MANAGER="dnf"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_fedora_43_arm64\.tar\.gz$'
                    ;;
                44*)
                    TARGET="Fedora 44"
                    PACKAGE_MANAGER="dnf"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_fedora_44_arm64\.tar\.gz$'
                    ;;
                *)
                    die \
                        "Unsupported system: ${system_name}. Only Fedora 43/44 are supported."
                    ;;
            esac
            ;;
        *)
            die "Unsupported system: ${system_name}."
            ;;
    esac

    MEDIA_DRIVER_INSTALL_DIR="$(media_driver_install_dir_for_target "$distro_id")" || die \
        "Internal error: could not determine the media decode driver directory for ${system_name}."
    MEDIA_DRIVER_INSTALL_PATH="${MEDIA_DRIVER_INSTALL_DIR}/${MEDIA_DRIVER_NAME}"

    log \
        "Detected system: ${system_name} -> ${TARGET}"
}

check_architecture() {
    local architecture

    architecture="$(uname -m)"
    case "$architecture" in
        aarch64|arm64) ;;
        *)
            die \
                "The prebuilt Mesa packages support ARM64/aarch64 only; current architecture is ${architecture}."
            ;;
    esac
}

require_commands() {
    local command_name

    for command_name in awk cat chmod cp dirname grep install mktemp mv od rm sed sha256sum sort stat tar tr uname; do
        command -v "$command_name" >/dev/null 2>&1 || die \
            "The installer requires the missing command: ${command_name}."
    done
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        command -v jq >/dev/null 2>&1 || die \
            "jq was not found; the GitHub Mesa Release cannot be parsed."
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die \
            "Neither curl nor wget was found; Mesa cannot be downloaded."
    fi

    case "$PACKAGE_MANAGER" in
        apt)
            command -v ldconfig >/dev/null 2>&1 || die \
                "ldconfig was not found."
            ;;
        dnf)
            command -v ldconfig >/dev/null 2>&1 || die \
                "ldconfig was not found."
            ;;
        pacman)
            command -v pacman >/dev/null 2>&1 || die \
                "pacman was not found."
            [[ -r "$PACMAN_CONFIG" ]] || die \
                "Unable to read ${PACMAN_CONFIG}."
            ;;
    esac
}

download_stdout() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 120 "$url"
    else
        wget -q --tries=5 --timeout=20 --waitretry=3 --retry-connrefused -O - "$url"
    fi
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 300 \
            --continue-at - "$url" -o "$destination"
    else
        wget --continue --tries=5 --timeout=20 --waitretry=3 --retry-connrefused \
            -O "$destination" "$url"
    fi
}

resolve_release_asset() {
    local metadata asset_json expected_download_url

    log "Reading the rolling Mesa distribution Release..."
    metadata="$(download_stdout "$MESA_API_URL")" || die \
        "Unable to fetch Mesa Release metadata; the GitHub API may be rate-limited."

    asset_json="$(jq -ce --arg pattern "$ASSET_PATTERN" '
        if (.draft // false) or (.prerelease // false) then
            error("distribution release is not stable")
        else
            [.assets[]? | select((.name // "") | test($pattern))]
            | if length == 1 then .[0] else error("asset match is not unique") end
        end
    ' <<< "$metadata" 2>/dev/null || true)"
    [[ -n "$asset_json" && "$asset_json" != "null" ]] || die \
        "The rolling distribution Release has no matching ARM64 Mesa package for ${TARGET}."

    RELEASE_TAG="$(jq -er '.tag_name | select(type == "string" and length > 0)' \
        <<< "$metadata" 2>/dev/null)" || die \
        "The Release returned an invalid tag."
    [[ "$RELEASE_TAG" == "$DISTRIBUTION_TAG" ]] || die \
        "The Release returned an invalid tag."
    ARCHIVE_NAME="$(jq -er '.name // empty' <<< "$asset_json" 2>/dev/null)" || die \
        "The Release returned an invalid asset name."
    OFFICIAL_DOWNLOAD_URL="$(jq -er '.browser_download_url // empty' \
        <<< "$asset_json" 2>/dev/null)" || die \
        "The Release returned an invalid download URL."
    OFFICIAL_ARCHIVE_DIGEST="$(jq -r '.digest // empty' \
        <<< "$asset_json" 2>/dev/null)" || die \
        "The Release returned an invalid SHA-256 digest."

    expected_download_url="${GITHUB_RELEASE_URL}/${RELEASE_REPOSITORY}/releases/download/${RELEASE_TAG}/${ARCHIVE_NAME}"
    [[ "$OFFICIAL_DOWNLOAD_URL" == "$expected_download_url" ]] || die \
        "The Release returned an invalid download URL."
    [[ "$ARCHIVE_NAME" =~ $ASSET_PATTERN ]] || die \
        "The Release asset name does not match the target distribution."
    log "Selected Mesa asset: ${ARCHIVE_NAME}"
}

cnb_manifest_asset_rows() {
    local manifest="$1"

    awk -F '\t' -v expected_tag="$DISTRIBUTION_TAG" '
        $0 == "format=1" { format_count += 1; next }
        $0 ~ /^format=/ { invalid = 1; next }
        $0 ~ /^release_tag=/ {
            release_tag_count += 1
            if ($0 != "release_tag=" expected_tag) invalid = 1
            next
        }
        $0 == "sha256\tsize\tasset" { header_count += 1; in_assets = 1; next }
        !in_assets && $0 == "" { next }
        !in_assets && $0 ~ /^[A-Za-z][A-Za-z0-9_]*=.*/ { next }
        in_assets && NF == 3 {
            if (length($1) != 64 || $1 !~ /^[0-9A-Fa-f]+$/ ||
                $2 !~ /^[0-9]+$/ || $2 == 0 ||
                $3 !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/ || $3 ~ /\.\./ || seen[$3]++) {
                invalid = 1
            } else {
                print tolower($1) "\t" $2 "\t" $3
                asset_count += 1
            }
            next
        }
        { invalid = 1 }
        END {
            if (format_count != 1 || release_tag_count > 1 || header_count != 1 || asset_count == 0 || invalid) {
                exit 1
            }
        }
    ' "$manifest"
}

resolve_cnb_distribution_manifest() {
    local manifest_url manifest_size rows checksum size asset archive_name canonical_base
    local archive_count=0 driver_count=0 checksums_count=0
    local archive_checksum="" archive_size=""
    local driver_checksum="" driver_size=""
    local checksums_checksum="" checksums_size=""

    CNB_MANIFEST_FILE="$WORK_DIR/$DISTRIBUTION_MANIFEST_NAME"
    manifest_url="$(distribution_manifest_url_for_source 3)" || die \
        "Could not build the CNB Mesa manifest URL."
    log "Reading the Mesa distribution manifest from CNB..."
    download_file "$manifest_url" "$CNB_MANIFEST_FILE" || die \
        "Could not download the CNB Mesa distribution manifest."
    manifest_size="$(stat -c '%s' "$CNB_MANIFEST_FILE")" || die \
        "Could not read the CNB Mesa distribution manifest size."
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -gt 0 && \
       "$manifest_size" -le "$MAX_MANIFEST_BYTES" ]] || die \
        "The CNB Mesa distribution manifest size is invalid."
    rows="$(cnb_manifest_asset_rows "$CNB_MANIFEST_FILE")" || die \
        "The CNB Mesa distribution manifest format is invalid."

    while IFS=$'\t' read -r checksum size asset; do
        [[ -n "$checksum" && -n "$size" && -n "$asset" ]] || continue
        if [[ "$asset" =~ $ASSET_PATTERN ]]; then
            archive_name="$asset"
            archive_checksum="$checksum"
            archive_size="$size"
            archive_count=$((archive_count + 1))
        fi
        case "$asset" in
            "$MEDIA_DRIVER_NAME")
                driver_checksum="$checksum"
                driver_size="$size"
                driver_count=$((driver_count + 1))
                ;;
            "$MEDIA_CHECKSUMS_NAME")
                checksums_checksum="$checksum"
                checksums_size="$size"
                checksums_count=$((checksums_count + 1))
                ;;
        esac
    done <<< "$rows"

    (( archive_count == 1 && driver_count == 1 && checksums_count == 1 )) || die \
        "The CNB Mesa distribution manifest has missing or duplicate target assets."
    (( archive_size <= MAX_ARCHIVE_BYTES && driver_size <= MAX_MEDIA_DRIVER_BYTES && \
       checksums_size <= MAX_CHECKSUMS_BYTES )) || die \
        "An asset in the CNB Mesa distribution manifest exceeds its size limit."

    ARCHIVE_NAME="$archive_name"
    [[ "$ARCHIVE_NAME" =~ $ASSET_PATTERN ]] || die \
        "The Mesa asset name in the CNB distribution manifest is invalid."
    RELEASE_TAG="$DISTRIBUTION_TAG"
    EXPECTED_ARCHIVE_SHA256="$archive_checksum"
    EXPECTED_ARCHIVE_SIZE="$archive_size"
    OFFICIAL_ARCHIVE_DIGEST="sha256:$archive_checksum"
    MEDIA_RELEASE_TAG="$DISTRIBUTION_TAG"
    MEDIA_DRIVER_RELEASE_DIGEST="sha256:$driver_checksum"
    MEDIA_DRIVER_RELEASE_SIZE="$driver_size"
    MEDIA_CHECKSUMS_RELEASE_DIGEST="sha256:$checksums_checksum"
    MEDIA_CHECKSUMS_RELEASE_SIZE="$checksums_size"
    canonical_base="$GITHUB_RELEASE_URL/$RELEASE_REPOSITORY/releases/download/$DISTRIBUTION_TAG"
    OFFICIAL_DOWNLOAD_URL="$canonical_base/$ARCHIVE_NAME"
    MEDIA_DRIVER_DOWNLOAD_URL="$canonical_base/$MEDIA_DRIVER_NAME"
    MEDIA_CHECKSUMS_DOWNLOAD_URL="$canonical_base/$MEDIA_CHECKSUMS_NAME"
    log \
        "Selected the Mesa asset from the CNB manifest: ${ARCHIVE_NAME}"
}

download_source_name() {
    case "$1" in
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'CNB' ;;
        *) return 1 ;;
    esac
}

download_url_for_source() {
    local source="$1"

    download_url_for_release_asset "$source" "$RELEASE_REPOSITORY" "$OFFICIAL_DOWNLOAD_URL"
}

distribution_manifest_url_for_source() {
    case "$1" in
        1) printf '%s/%s/releases/download/%s/%s' \
            "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" \
            "$DISTRIBUTION_TAG" "$DISTRIBUTION_MANIFEST_NAME" ;;
        2) printf '%s/%s/releases/download/%s/%s' \
            "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" \
            "$DISTRIBUTION_TAG" "$DISTRIBUTION_MANIFEST_NAME" ;;
        3) printf '%s/%s/-/releases/download/%s/%s' \
            "$CNB_RELEASE_URL" "$CNB_RELEASE_REPOSITORY" \
            "$DISTRIBUTION_TAG" "$DISTRIBUTION_MANIFEST_NAME" ;;
        *) return 1 ;;
    esac
}

download_url_for_release_asset() {
    local source="$1"
    local repository="$2"
    local official_url="$3"
    local source_url official_path asset_name

    case "$source" in
        1) source_url="$GITHUB_RELEASE_URL" ;;
        2) source_url="$GH_PROXY_RELEASE_URL" ;;
        3)
            official_path="${official_url#"$GITHUB_RELEASE_URL"}"
            [[ "$official_path" == "/${repository}/releases/download/${DISTRIBUTION_TAG}/"* ]] || return 1
            asset_name="${official_url##*/}"
            [[ "$asset_name" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
            printf '%s/%s/-/releases/download/%s/%s' \
                "$CNB_RELEASE_URL" "$CNB_RELEASE_REPOSITORY" \
                "$DISTRIBUTION_TAG" "$asset_name"
            return
            ;;
        *) return 1 ;;
    esac

    official_path="${official_url#"$GITHUB_RELEASE_URL"}"
    [[ "$official_path" == "/${repository}/releases/download/"* ]] || return 1
    printf '%s%s' "$source_url" "$official_path"
}

format_latency() {
    local seconds="$1"

    awk -v seconds="$seconds" 'BEGIN { printf "%d ms", (seconds * 1000) + 0.5 }'
}

probe_download_source() {
    local source="$1"
    local probe_url latency started finished probe_status=0
    local -a probe_command

    probe_url="$(distribution_manifest_url_for_source "$source")" || return 1
    # Only the first byte is probed; Mesa assets are much larger than the manifest used by install-anland-kde.sh.
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --range 0-0 \
            --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
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
            die \
                "Testing download sources with wget requires timeout to enforce the ${SOURCE_PROBE_TIMEOUT_SECONDS}-second limit."
        started="$(date +%s%3N 2>/dev/null || true)"
        probe_command=(wget -q --header='Range: bytes=0-0' --tries=1 \
            --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$probe_url")
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
        die \
            "Neither curl nor wget was found; download sources cannot be tested."
    fi

    if (( probe_status == 28 || probe_status == 124 )); then
        printf '%s' "$(msg 'timeout')"
    else
        printf '%s' "$(msg 'unavailable')"
    fi
}

select_download_source() {
    local source latency choice

    if [[ "$SKIP_SOURCE_PROBE" == true ]]; then
        log \
            "Selected $(download_source_name "$DOWNLOAD_SOURCE") from the command line; skipping latency checks."
        return
    fi

    log \
        "Testing download-source latency (timeouts at ${SOURCE_PROBE_TIMEOUT_SECONDS} seconds)..."
    for source in 1 2 3; do
        latency="$(probe_download_source "$source")"
        printf '%s. %s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$(msg 'latency')" "$latency"
    done

    while :; do
        printf '%s' "$(msg 'Choose a download source [1-3]: ')"
        if ! IFS= read -r choice; then
            die \
                "Unable to read a download-source choice. Specify -1/--1, -2/--2, or -3/--3."
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

resolve_expected_archive_sha256() {
    if [[ "$DOWNLOAD_SOURCE" == "3" ]]; then
        [[ "$EXPECTED_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die \
            "The CNB Mesa distribution manifest has no valid SHA-256 digest for ${ARCHIVE_NAME}."
        return
    fi

    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi

    command -v sha256sum >/dev/null 2>&1 || die \
        "Selecting a third-party mirror requires sha256sum to verify the downloaded file."
    if [[ ! "$OFFICIAL_ARCHIVE_DIGEST" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        die \
            "GitHub Release did not provide a valid SHA-256 digest for ${ARCHIVE_NAME}; refusing the third-party mirror package."
    fi
    EXPECTED_ARCHIVE_SHA256="${BASH_REMATCH[1],,}"
}

validate_release_asset_checksum() {
    local asset_file="$1"
    local actual_checksum

    if ! actual_checksum="$(sha256sum "$asset_file" | awk '{print $1}')" || \
        ! [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ ]] || \
        [[ "$actual_checksum" != "$EXPECTED_ARCHIVE_SHA256" ]]; then
        return 1
    fi
}

release_digest_sha256() {
    local digest="$1"

    [[ "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1],,}"
}

resolve_media_decode_release() {
    local metadata driver_json checksums_json expected_url

    log \
        "Reading the media decode driver from the rolling distribution Release..."
    metadata="$(download_stdout "$MEDIA_DECODE_API_URL")" || die \
        "Unable to fetch media decode driver Release metadata; the GitHub API may be rate-limited."

    if ! jq -e '
        (.draft // false) == false and
        (.prerelease // false) == false and
        (.tag_name | type == "string" and length > 0)
    ' <<< "$metadata" >/dev/null 2>&1; then
        die \
            "The rolling media decode distribution Release is invalid."
    fi
    MEDIA_RELEASE_TAG="$(jq -er '.tag_name' <<< "$metadata" 2>/dev/null)" || die \
        "The media decode driver Release returned an invalid tag."
    [[ "$MEDIA_RELEASE_TAG" == "$DISTRIBUTION_TAG" ]] || die \
        "The media decode driver Release returned an invalid tag."

    driver_json="$(jq -ce --arg name "$MEDIA_DRIVER_NAME" '
        [.assets[]? | select((.name // "") == $name)]
        | if length == 1 then .[0] else error("driver asset match is not unique") end
    ' <<< "$metadata" 2>/dev/null || true)"
    checksums_json="$(jq -ce --arg name "$MEDIA_CHECKSUMS_NAME" '
        [.assets[]? | select((.name // "") == $name)]
        | if length == 1 then .[0] else error("checksum asset match is not unique") end
    ' <<< "$metadata" 2>/dev/null || true)"
    [[ -n "$driver_json" && "$driver_json" != "null" ]] || die \
        "The media decode driver Release does not contain ${MEDIA_DRIVER_NAME}."
    [[ -n "$checksums_json" && "$checksums_json" != "null" ]] || die \
        "The media decode driver Release does not contain ${MEDIA_CHECKSUMS_NAME}."

    MEDIA_DRIVER_DOWNLOAD_URL="$(jq -er '.browser_download_url // empty' \
        <<< "$driver_json" 2>/dev/null)" || die \
        "The media decode driver Release returned an invalid driver download URL."
    MEDIA_DRIVER_RELEASE_DIGEST="$(jq -er '.digest // empty' \
        <<< "$driver_json" 2>/dev/null)" || die \
        "The media decode driver Release did not provide a driver digest."
    MEDIA_DRIVER_RELEASE_SIZE="$(jq -er '.size | select(type == "number" and . > 0 and floor == .)' \
        <<< "$driver_json" 2>/dev/null)" || die \
        "The media decode driver Release returned an invalid driver size."
    MEDIA_CHECKSUMS_DOWNLOAD_URL="$(jq -er '.browser_download_url // empty' \
        <<< "$checksums_json" 2>/dev/null)" || die \
        "The media decode driver Release returned an invalid checksum download URL."
    MEDIA_CHECKSUMS_RELEASE_DIGEST="$(jq -er '.digest // empty' \
        <<< "$checksums_json" 2>/dev/null)" || die \
        "The media decode driver Release did not provide a checksum-file digest."
    MEDIA_CHECKSUMS_RELEASE_SIZE="$(jq -er '.size | select(. > 0 and floor == .)' \
        <<< "$checksums_json" 2>/dev/null)" || die \
        "The media decode driver Release returned an invalid checksum-file size."

    expected_url="${GITHUB_RELEASE_URL}/${RELEASE_REPOSITORY}/releases/download/${MEDIA_RELEASE_TAG}/${MEDIA_DRIVER_NAME}"
    [[ "$MEDIA_DRIVER_DOWNLOAD_URL" == "$expected_url" ]] || die \
        "The media decode driver Release returned an invalid driver download URL."
    expected_url="${GITHUB_RELEASE_URL}/${RELEASE_REPOSITORY}/releases/download/${MEDIA_RELEASE_TAG}/${MEDIA_CHECKSUMS_NAME}"
    [[ "$MEDIA_CHECKSUMS_DOWNLOAD_URL" == "$expected_url" ]] || die \
        "The media decode driver Release returned an invalid checksum download URL."
    release_digest_sha256 "$MEDIA_DRIVER_RELEASE_DIGEST" >/dev/null || die \
        "The media decode driver Release returned an invalid driver SHA-256 digest."
    release_digest_sha256 "$MEDIA_CHECKSUMS_RELEASE_DIGEST" >/dev/null || die \
        "The media decode driver Release returned an invalid checksum-file SHA-256 digest."
    (( MEDIA_DRIVER_RELEASE_SIZE <= MAX_MEDIA_DRIVER_BYTES )) || die \
        "The media decode driver exceeds the allowed size."
    (( MEDIA_CHECKSUMS_RELEASE_SIZE <= MAX_CHECKSUMS_BYTES )) || die \
        "The media decode checksum file exceeds the allowed size."

    log \
        "Selected media decode driver: ${MEDIA_DRIVER_NAME} (${MEDIA_RELEASE_TAG})"
}

validate_sha256_file() {
    local file="$1"
    local expected_checksum="$2"
    local actual_checksum

    actual_checksum="$(sha256sum "$file" | awk '{print $1}')" || return 1
    [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ && "$actual_checksum" == "$expected_checksum" ]]
}

validate_aarch64_shared_object() {
    local file="$1"
    local elf_identity elf_type_and_machine

    elf_identity="$(od -An -tx1 -N6 "$file" | tr -d '[:space:]')" || return 1
    elf_type_and_machine="$(od -An -tx1 -j16 -N4 "$file" | tr -d '[:space:]')" || return 1
    [[ "$elf_identity" == "7f454c460201" && "$elf_type_and_machine" == "0300b700" ]]
}

download_media_decode_driver() {
    local driver_url checksums_url checksums_digest release_driver_digest checksums_size
    local manifest_driver_digest driver_size

    MEDIA_DRIVER_FILE="$WORK_DIR/$MEDIA_DRIVER_NAME"
    MEDIA_CHECKSUMS_FILE="$WORK_DIR/$MEDIA_CHECKSUMS_NAME"
    driver_url="$(download_url_for_release_asset \
        "$DOWNLOAD_SOURCE" "$RELEASE_REPOSITORY" "$MEDIA_DRIVER_DOWNLOAD_URL")" || die \
        "Could not build the media decode driver download URL."
    checksums_url="$(download_url_for_release_asset \
        "$DOWNLOAD_SOURCE" "$RELEASE_REPOSITORY" "$MEDIA_CHECKSUMS_DOWNLOAD_URL")" || die \
        "Could not build the media decode driver checksum download URL."

    log \
        "Downloading media decode driver ${MEDIA_RELEASE_TAG} from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$checksums_url" "$MEDIA_CHECKSUMS_FILE" || die \
        "The media decode driver checksum file download failed."
    checksums_size="$(stat -c '%s' "$MEDIA_CHECKSUMS_FILE")" || die \
        "Unable to read the media decode checksum-file size."
    [[ "$checksums_size" =~ ^[0-9]+$ && "$checksums_size" -eq "$MEDIA_CHECKSUMS_RELEASE_SIZE" ]] || die \
        "Downloaded ${MEDIA_CHECKSUMS_NAME} size does not match the Release."
    checksums_digest="$(release_digest_sha256 "$MEDIA_CHECKSUMS_RELEASE_DIGEST")" || die \
        "The media decode driver Release returned an invalid checksum-file SHA-256 digest."
    validate_sha256_file "$MEDIA_CHECKSUMS_FILE" "$checksums_digest" || die \
        "Downloaded ${MEDIA_CHECKSUMS_NAME} failed Release SHA-256 verification."

    manifest_driver_digest="$(awk -v name="$MEDIA_DRIVER_NAME" '
        $1 ~ /^[0-9A-Fa-f]{64}$/ && $2 == name { print tolower($1) }
    ' "$MEDIA_CHECKSUMS_FILE")"
    [[ "$manifest_driver_digest" =~ ^[0-9a-f]{64}$ ]] || die \
        "${MEDIA_CHECKSUMS_NAME} does not contain one valid digest for ${MEDIA_DRIVER_NAME}."
    [[ "$(awk -v name="$MEDIA_DRIVER_NAME" '$2 == name { count++ } END { print count + 0 }' \
        "$MEDIA_CHECKSUMS_FILE")" == "1" ]] || die \
        "${MEDIA_CHECKSUMS_NAME} contains multiple digests for ${MEDIA_DRIVER_NAME}."
    release_driver_digest="$(release_digest_sha256 "$MEDIA_DRIVER_RELEASE_DIGEST")" || die \
        "The media decode driver Release returned an invalid driver SHA-256 digest."
    [[ "$manifest_driver_digest" == "$release_driver_digest" ]] || die \
        "The driver digests in ${MEDIA_CHECKSUMS_NAME} and the Release do not match."

    download_file "$driver_url" "$MEDIA_DRIVER_FILE" || die \
        "The media decode driver download failed."
    [[ -f "$MEDIA_DRIVER_FILE" ]] || die \
        "The downloaded media decode driver does not exist."
    driver_size="$(stat -c '%s' "$MEDIA_DRIVER_FILE")" || die \
        "Unable to read the media decode driver size."
    [[ "$driver_size" =~ ^[0-9]+$ && "$driver_size" -eq "$MEDIA_DRIVER_RELEASE_SIZE" ]] || die \
        "The downloaded media decode driver size does not match the Release."
    validate_sha256_file "$MEDIA_DRIVER_FILE" "$manifest_driver_digest" || die \
        "Downloaded ${MEDIA_DRIVER_NAME} failed SHA-256 verification."
    validate_aarch64_shared_object "$MEDIA_DRIVER_FILE" || die \
        "Downloaded ${MEDIA_DRIVER_NAME} is not an AArch64 ELF shared object."
}

validate_archive_size() {
    local archive_size="$1"

    [[ -f "$archive_size" ]] || die \
        "The downloaded file does not exist."
    local size
    size="$(stat -c '%s' "$archive_size")" || die \
        "Unable to read the downloaded file size."
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || die \
        "The downloaded file is empty."
    (( size <= MAX_ARCHIVE_BYTES )) || die \
        "The downloaded archive exceeds the allowed size."
    if [[ -n "$EXPECTED_ARCHIVE_SIZE" && "$size" -ne "$EXPECTED_ARCHIVE_SIZE" ]]; then
        die \
            "Downloaded ${ARCHIVE_NAME} size does not match the CNB distribution manifest."
    fi
}

validate_archive_paths() {
    local archive_file="$1"
    local entry
    local total_size=0
    local entry_size
    local listing_file="$WORK_DIR/archive.list"
    local verbose_listing_file="$WORK_DIR/archive.verbose"
    local entry_sizes_file="$WORK_DIR/archive.sizes"

    if [[ "$ARCHIVE_KIND" == "tar.gz" ]]; then
        if ! tar -tzf "$archive_file" > "$listing_file"; then
            die "Unable to read the downloaded archive contents."
        fi
        [[ -s "$listing_file" ]] || die \
            "The downloaded archive contains no files."
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            case "$entry" in
                /*|.|..|../*|*/../*|*/..)
                    die \
                        "The downloaded archive contains an unsafe path: ${entry}"
                    ;;
            esac
        done < "$listing_file"

        if ! LC_ALL=C tar -tvzf "$archive_file" > "$verbose_listing_file"; then
            die "Unable to read the downloaded archive entry sizes."
        fi
        awk '$3 ~ /^[0-9]+$/ { print $3 }' \
            "$verbose_listing_file" > "$entry_sizes_file"
        [[ -s "$entry_sizes_file" ]] || die \
            "The downloaded archive has no verifiable entries."
        while IFS= read -r entry_size; do
            [[ "$entry_size" =~ ^[0-9]+$ ]] || die \
                "Unable to read an archive entry size."
            total_size=$((total_size + entry_size))
            (( total_size <= MAX_EXTRACTED_BYTES )) || die \
                "The downloaded archive exceeds the allowed extracted size."
        done < "$entry_sizes_file"
    else
        if ! tar -tf "$archive_file" > "$listing_file"; then
            die "Unable to read the Arch archive contents."
        fi
        [[ -s "$listing_file" ]] || die \
            "The Arch archive contains no files."
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            entry="${entry#./}"
            case "$entry" in
                /*|.|..|../*|*/../*|*/..)
                    die \
                        "The Arch archive contains an unsafe path: ${entry}"
                    ;;
                ""|*/)
                    ;;
                *.pkg.tar.*|*.sig)
                    [[ "$entry" != */* ]] || die \
                        "The Arch archive contains an unsafe path: ${entry}"
                    ;;
                *)
                    die \
                        "The Arch archive contains an unexpected file: ${entry}"
                    ;;
            esac
        done < "$listing_file"

        if ! LC_ALL=C tar -tvf "$archive_file" > "$verbose_listing_file"; then
            die \
                "Unable to read the Arch archive entry sizes."
        fi
        awk '$3 ~ /^[0-9]+$/ { print $3 }' \
            "$verbose_listing_file" > "$entry_sizes_file"
        [[ -s "$entry_sizes_file" ]] || die \
            "The Arch archive has no verifiable entries."
        while IFS= read -r entry_size; do
            [[ "$entry_size" =~ ^[0-9]+$ ]] || die \
                "Unable to read an Arch archive entry size."
            total_size=$((total_size + entry_size))
            (( total_size <= MAX_EXTRACTED_BYTES )) || die \
                "The Arch archive exceeds the allowed extracted size."
        done < "$entry_sizes_file"
    fi
}

configure_apt_holds() {
    local preferences_file="$APT_HOLD_PREFERENCES"

    install -d -m 0755 "$(dirname "$preferences_file")"
    cat > "$preferences_file" <<'EOF'
# /etc/apt/preferences.d/hold-anland-package

Package: libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers
Pin: release *
Pin-Priority: -1
EOF
    [[ -s "$preferences_file" ]] || die \
        "Unable to write the APT version hold configuration."
    log \
        "Wrote the APT package hold configuration: ${preferences_file}"
}

rewrite_without_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local begin_marker="$3"
    local end_marker="$4"

    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin {
            if (inside) {
                invalid = 1
            }
            begins++
            inside = 1
            next
        }
        $0 == end {
            if (!inside) {
                invalid = 1
            }
            ends++
            inside = 0
            next
        }
        !inside { print }
        END {
            if (invalid || inside || begins != ends || begins > 1) {
                exit 1
            }
        }
    ' "$input_file" > "$output_file"
}

write_dnf_config_with_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local stripped_file="$WORK_DIR/dnf.conf.stripped"
    local excluded_packages="mesa*"

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        excluded_packages+=",systemd*"
    fi

    rewrite_without_managed_block \
        "$input_file" "$stripped_file" "$DNF_MANAGED_BEGIN" "$DNF_MANAGED_END" || return 1

    # DNF binds the yum-compatible exclude alias and excludepkgs to the same append list.
    # Using different keys avoids the INI parser replacing duplicate keys while staying
    # compatible with Anland's excludepkgs rules.
    awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" \
        -v excludes="$excluded_packages" '
        function contains(value, wanted, normalized, count, tokens, i) {
            normalized = value
            gsub(/,/, " ", normalized)
            count = split(normalized, tokens, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                if (tokens[i] == wanted) {
                    return 1
                }
            }
            return 0
        }
        function merge_excludes(line, equals, value, trimmed, separator, count, wanted, i) {
            equals = index(line, "=")
            value = substr(line, equals + 1)
            trimmed = value
            sub(/[[:space:]]+$/, "", trimmed)
            separator = (trimmed == "" || trimmed ~ /,$/) ? "" : ","
            count = split(excludes, wanted, ",")
            for (i = 1; i <= count; i++) {
                if (!contains(value, wanted[i])) {
                    value = value separator wanted[i]
                    separator = ","
                }
            }
            return substr(line, 1, equals) value
        }
        function write_block() {
            print begin
            print "exclude=" excludes
            print end
        }
        /^\[main\][[:space:]]*$/ {
            in_main = 1
            saw_main = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_main && !saw_exclude) {
                write_block()
            }
            in_main = 0
            print
            next
        }
        {
            if (in_main && $0 ~ /^[[:space:]]*exclude[[:space:]]*=/) {
                print merge_excludes($0)
                saw_exclude = 1
                next
            }
            print
        }
        END {
            if (in_main && !saw_exclude) {
                write_block()
            }
            if (!saw_main) {
                print "[main]"
                write_block()
            }
        }
    ' "$stripped_file" > "$output_file"
}

configure_dnf_holds() {
    local temporary_config="$WORK_DIR/dnf.conf.locked"

    install -d -m 0755 "$(dirname "$DNF_CONFIG")"
    if [[ ! -e "$DNF_CONFIG" ]]; then
        install -m 0644 /dev/null "$DNF_CONFIG"
    fi
    [[ -f "$DNF_CONFIG" ]] || die \
        "The DNF configuration is not a regular file: ${DNF_CONFIG}."

    if ! write_dnf_config_with_managed_block "$DNF_CONFIG" "$temporary_config"; then
        die \
            "The managed markers in the DNF hold configuration are invalid."
    fi
    install -m 0644 "$temporary_config" "$DNF_CONFIG" || die \
        "Unable to write the DNF package hold configuration."
    log \
        "Wrote the DNF package hold configuration: ${DNF_CONFIG}"
}

write_pacman_config_with_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local packages_line="$3"
    local stripped_file="$WORK_DIR/pacman.conf.stripped"

    rewrite_without_managed_block \
        "$input_file" "$stripped_file" "$PACMAN_MANAGED_BEGIN" "$PACMAN_MANAGED_END" || return 1

    awk -v begin="$PACMAN_MANAGED_BEGIN" -v end="$PACMAN_MANAGED_END" \
        -v packages="$packages_line" '
        function write_block() {
            print begin
            print "IgnorePkg = " packages
            print end
        }
        /^\[options\][[:space:]]*$/ {
            in_options = 1
            saw_options = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_options && !wrote_block) {
                write_block()
                wrote_block = 1
            }
            in_options = 0
            print
            next
        }
        { print }
        END {
            if (in_options && !wrote_block) {
                write_block()
            }
            if (!saw_options) {
                exit 2
            }
        }
    ' "$stripped_file" > "$output_file"
}

configure_pacman_holds() {
    local package packages_line
    local temporary_config="$WORK_DIR/pacman.conf.locked"
    local sorted_packages_file="$WORK_DIR/pacman-holds.list"
    local -a packages=("$@")
    local -a unique_packages=()

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        packages+=(systemd systemd-libs systemd-sysvcompat)
    fi
    if ! printf '%s\n' "${packages[@]}" | sort -u > "$sorted_packages_file"; then
        die "Unable to prepare the Arch package hold list."
    fi
    mapfile -t unique_packages < "$sorted_packages_file"
    ((${#unique_packages[@]} > 0)) || die \
        "There are no Arch packages to hold."
    for package in "${unique_packages[@]}"; do
        [[ "$package" =~ ^[[:alnum:]@._+*-]+$ ]] || die \
            "Invalid Arch package name: ${package}."
    done
    printf -v packages_line '%s ' "${unique_packages[@]}"
    packages_line="${packages_line% }"

    if ! write_pacman_config_with_managed_block \
        "$PACMAN_CONFIG" "$temporary_config" "$packages_line"; then
        die \
            "pacman.conf has no [options] section, or its managed hold markers are invalid."
    fi
    install -m 0644 "$temporary_config" "$PACMAN_CONFIG" || die \
        "Unable to write the Pacman package hold configuration."
    log \
        "Wrote the Pacman package hold configuration: ${PACMAN_CONFIG}"
}

configure_package_holds() {
    case "$PACKAGE_MANAGER" in
        apt)
            configure_apt_holds
            ;;
        dnf)
            configure_dnf_holds
            ;;
        pacman)
            configure_pacman_holds "${MESA_PACKAGE_NAMES[@]}"
            ;;
        *)
            die \
                "Internal error: cannot configure package holds for ${PACKAGE_MANAGER}."
            ;;
    esac
}

install_arch_packages() {
    local pacman_config
    local entry
    local package_listing_file="$WORK_DIR/arch-package-files.list"
    local package_names_file="$WORK_DIR/arch-package-names.list"
    local -a package_files=()

    pacman_config="$WORK_DIR/pacman.conf"
    cp -p "$PACMAN_CONFIG" "$pacman_config"

    # Mesa Release packages are intentionally unsigned, so the signature policy is
    # relaxed only in this temporary Pacman configuration.
    if grep -Eq '^[[:space:]]*#?[[:space:]]*SigLevel[[:space:]]*=' "$pacman_config"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*SigLevel[[:space:]]*=.*/SigLevel = Never/' "$pacman_config"
    elif grep -qE '^\[options\][[:space:]]*$' "$pacman_config"; then
        sed -i '/^\[options\][[:space:]]*$/a SigLevel = Never' "$pacman_config"
    else
        die "pacman.conf has no [options] section."
    fi

    if ! tar -tf "$ARCHIVE_FILE" > "$package_listing_file"; then
        die "Unable to read the Arch archive contents."
    fi
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        entry="${entry#./}"
        case "$entry" in
            *.pkg.tar.*)
                package_files+=("$WORK_DIR/$entry")
                ;;
        esac
    done < "$package_listing_file"
    ((${#package_files[@]} > 0)) || die \
        "The Arch archive has no installable packages."
    if ! pacman -Qq -p "${package_files[@]}" | sort -u > "$package_names_file"; then
        die "Could not determine the Arch Mesa package names."
    fi
    [[ -s "$package_names_file" ]] || die \
        "Could not determine the Arch Mesa package names."
    mapfile -t MESA_PACKAGE_NAMES < "$package_names_file"
    ((${#MESA_PACKAGE_NAMES[@]} > 0)) || die \
        "Could not determine the Arch Mesa package names."

    log \
        "Installing LLVM 22 required for Arch GPU initialization..."
    pacman -S --noconfirm --needed llvm22

    log \
        "Installing ${#package_files[@]} Arch Mesa packages..."
    pacman --config "$pacman_config" -U --noconfirm "${package_files[@]}"
}

install_tar_gz() {
    log "Extracting the ${TARGET} Mesa driver..."
    tar --extract --gzip --file "$ARCHIVE_FILE" --directory / \
        --no-same-owner --keep-directory-symlink
    ldconfig
}

install_media_decode_driver() {
    install -d -m 0755 "$MEDIA_DRIVER_INSTALL_DIR" || die \
        "Unable to create the media decode driver directory: ${MEDIA_DRIVER_INSTALL_DIR}."
    MEDIA_DRIVER_TEMP_FILE="$(mktemp "${MEDIA_DRIVER_INSTALL_PATH}.tmp.XXXXXXXX")" || die \
        "Unable to create a temporary media decode driver in the destination directory."
    if ! install -m 0644 "$MEDIA_DRIVER_FILE" "$MEDIA_DRIVER_TEMP_FILE"; then
        rm -f -- "$MEDIA_DRIVER_TEMP_FILE"
        die "Unable to write the media decode driver."
    fi
    if ! mv -f -- "$MEDIA_DRIVER_TEMP_FILE" "$MEDIA_DRIVER_INSTALL_PATH"; then
        rm -f -- "$MEDIA_DRIVER_TEMP_FILE"
        die "Unable to install the media decode driver."
    fi
    MEDIA_DRIVER_TEMP_FILE=""
    log \
        "Installed media decode driver: ${MEDIA_DRIVER_INSTALL_PATH} (${MEDIA_RELEASE_TAG})"
}

install_mesa() {
    log \
        "Downloading and installing the latest Mesa and media decode drivers..."
    WORK_DIR="$(mktemp -d -t install-mesa.XXXXXXXX)" || die \
        "Unable to create a temporary directory."
    chmod 0700 "$WORK_DIR" || die \
        "Unable to secure the temporary directory."
    if [[ "$DOWNLOAD_SOURCE" == "3" ]]; then
        resolve_cnb_distribution_manifest
    else
        resolve_release_asset
        resolve_media_decode_release
    fi
    resolve_expected_archive_sha256
    DOWNLOAD_URL="$(download_url_for_source "$DOWNLOAD_SOURCE")" || die \
        "Could not build the selected download-source URL."
    ARCHIVE_FILE="$WORK_DIR/$ARCHIVE_NAME"

    log \
        "Downloading ${ARCHIVE_NAME} from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$DOWNLOAD_URL" "$ARCHIVE_FILE" || die \
        "The Mesa driver download failed."
    validate_archive_size "$ARCHIVE_FILE"
    if [[ -n "$EXPECTED_ARCHIVE_SHA256" ]] && \
        ! validate_release_asset_checksum "$ARCHIVE_FILE"; then
        die \
            "Downloaded ${ARCHIVE_NAME} failed SHA-256 verification."
    fi
    validate_archive_paths "$ARCHIVE_FILE"
    download_media_decode_driver

    case "$PACKAGE_MANAGER" in
        pacman)
            tar --extract --file "$ARCHIVE_FILE" --directory "$WORK_DIR" \
                --no-same-owner
            install_arch_packages
            ;;
        apt|dnf)
            install_tar_gz
            ;;
        *)
            die \
                "Internal error: unknown package manager ${PACKAGE_MANAGER}."
            ;;
    esac
    configure_package_holds
    install_media_decode_driver
    record_component_version "$(mesa_archive_version)"
}

main() {
    parse_arguments "$@"
    detect_target
    check_architecture
    require_root "$@"
    if [[ "$UNINSTALL" == true ]]; then
        uninstall_mesa
        return
    fi
    select_download_source
    require_commands
    install_mesa
    log \
        "Mesa and media decode driver installation completed; related packages are now held."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
