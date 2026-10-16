#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${HANGOVER_WINE_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
readonly RELEASE_TAG="${HANGOVER_WINE_RELEASE_TAG:-hangover-wine-packages}"
readonly MANIFEST_NAME="hangover-wine-manifest"
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly MAX_ARCHIVE_BYTES=$((2 * 1024 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((6 * 1024 * 1024 * 1024))
readonly DOWNLOAD_CACHE_DIR="/var/cache/hangover-wine"
readonly COMPONENT_STATE_DIR="/var/lib/droidspaces-tui/components"

DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
TARGET=""
TARGET_LABEL=""
PACKAGE_KIND=""
ARCHIVE_SUFFIX=""
ARCHIVE_NAME=""
EXPECTED_ARCHIVE_SHA256=""
PACKAGE_DIR=""
WORK_DIR=""
RELEASE_METADATA=""
APT_TEMPORARY_HOLDS=()
BOOTSTRAP_PACKAGES=()
UNINSTALL=false

msg() {
    printf '%s' "$1"
}

log() {
    printf '[hangover-wine] %s\n' "$(msg "$1")"
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/hangover.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "Could not record the installed Hangover Wine version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "Could not record the installed Hangover Wine version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "Could not record the installed Hangover Wine version."
    return 0
}

die() {
    printf '[hangover-wine] %s: %s\n' "$(msg 'Error')" "$(msg "$1")" >&2
    exit 1
}

usage() {
    cat <<EOF
$(msg 'Usage'): $0 [--1|--2|--3]

  $(msg 'No option: test all three sources, then choose interactively')
  --1, -1  GitHub
  --2, -2  gh-proxy.com
  --3, -3  CNB
  --uninstall  $(msg 'Uninstall the Hangover Wine packages')
EOF
}

parse_arguments() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            -1|--1)
                DOWNLOAD_SOURCE=1
                SKIP_SOURCE_PROBE=true
                ;;
            -2|--2)
                DOWNLOAD_SOURCE=2
                SKIP_SOURCE_PROBE=true
                ;;
            -3|--3)
                DOWNLOAD_SOURCE=3
                SKIP_SOURCE_PROBE=true
                ;;
            --uninstall)
                UNINSTALL=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unsupported argument: $argument. Use --1, --2, or --3."
                ;;
        esac
    done
}

uninstall_hangover() {
    local package
    local -a candidates=(hangover-libarm64ecfex hangover-libwow64fex hangover-wine hangover-wowbox64)
    local -a installed=()

    case "$PACKAGE_KIND" in
        deb)
            command -v dpkg-query >/dev/null 2>&1 || die "Missing command: dpkg-query."
            command -v apt-get >/dev/null 2>&1 || die "Missing command: apt-get."
            for package in "${candidates[@]}"; do
                if dpkg-query -W -f='${db:Status-Abbrev}\n' "$package" 2>/dev/null | grep -qE '^.i $'; then
                    installed+=("$package")
                fi
            done
            ((${#installed[@]} == 0)) || \
                apt-get remove -y --allow-change-held-packages "${installed[@]}"
            ;;
        rpm)
            command -v rpm >/dev/null 2>&1 || die "Missing command: rpm."
            command -v dnf >/dev/null 2>&1 || die "Missing command: dnf."
            if rpm -q hangover-wine >/dev/null 2>&1; then
                dnf remove -y hangover-wine
            fi
            ;;
        arch)
            command -v pacman >/dev/null 2>&1 || die "Missing command: pacman."
            if pacman -Q hangover-wine >/dev/null 2>&1; then
                pacman -R --noconfirm hangover-wine
            fi
            ;;
    esac
    rm -f -- "$COMPONENT_STATE_DIR/hangover.version"
    log "Hangover Wine was uninstalled."
}

cleanup() {
    if ((${#APT_TEMPORARY_HOLDS[@]} > 0)) && command -v apt-mark >/dev/null 2>&1; then
        apt-mark unhold "${APT_TEMPORARY_HOLDS[@]}" >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

validate_release_settings() {
    [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
        die "The Release repository must use owner/repository format."
    [[ "$RELEASE_TAG" == hangover-wine-packages ]] || \
        die "The Release tag must be hangover-wine-packages."
}

detect_target() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
    # shellcheck disable=SC1091
    source /etc/os-release
    local distro_id="${ID:-}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-${distro_id} ${version_id}}"
    distro_id="${distro_id,,}"

    case "$distro_id" in
        arch|archarm)
            TARGET=arch
            TARGET_LABEL='Arch Linux'
            PACKAGE_KIND=arch
            ARCHIVE_SUFFIX='-aarch64.tar.gz'
            ;;
        ubuntu)
            case "$version_id" in
                24.04*) TARGET=ubuntu2404; TARGET_LABEL='Ubuntu 24.04' ;;
                25.10*) TARGET=ubuntu2510; TARGET_LABEL='Ubuntu 25.10' ;;
                26.04*) TARGET=ubuntu2604; TARGET_LABEL='Ubuntu 26.04' ;;
                *)
                    die "Unsupported system: $system_name."
                    ;;
            esac
            PACKAGE_KIND=deb
            ARCHIVE_SUFFIX='-arm64.tar.gz'
            ;;
        debian)
            case "$version_id" in
                13*) ;;
                *)
                    die "Unsupported system: $system_name."
                    ;;
            esac
            TARGET=debian13
            TARGET_LABEL='Debian 13'
            PACKAGE_KIND=deb
            ARCHIVE_SUFFIX='-arm64.tar.gz'
            ;;
        fedora)
            case "$version_id" in
                43*) TARGET=fedora43; TARGET_LABEL='Fedora 43' ;;
                44*) TARGET=fedora44; TARGET_LABEL='Fedora 44' ;;
                *)
                    die "Unsupported system: $system_name."
                    ;;
            esac
            PACKAGE_KIND=rpm
            ARCHIVE_SUFFIX='-aarch64.tar.gz'
            ;;
        *)
            die "Unsupported system: $system_name. Supported systems: Ubuntu 24.04/25.10/26.04, Debian 13, Fedora 43/44, and Arch Linux."
            ;;
    esac

    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            die "Prebuilt packages support ARM64/aarch64 only; current architecture is $(uname -m)."
            ;;
    esac
    log "Detected $TARGET_LABEL ($TARGET)"
}

require_root() {
    (( EUID == 0 )) && return
    command -v sudo >/dev/null 2>&1 || \
        die "Run as root or install sudo first."

    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    [[ -r "$script_path" ]] || \
        die "The installer cannot be reread through sudo; download it to a file first."
    log "Restarting the installer through sudo..."
    exec sudo env \
        "HANGOVER_WINE_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "HANGOVER_WINE_RELEASE_TAG=$RELEASE_TAG" \
        bash "$script_path" "$@"
}

protect_deb_system_packages() {
    local package
    local -a installed=() held=()
    local -A was_held=()

    command -v apt-mark >/dev/null 2>&1 || \
        die "Required command is missing: apt-mark."
    command -v dpkg-query >/dev/null 2>&1 || \
        die "Required command is missing: dpkg-query."

    mapfile -t installed < <(
        dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' \
            'systemd' 'systemd-*' 'libsystemd*' 'libudev*' 'udev' 2>/dev/null |
            awk -F '\t' '$1 ~ /^.i $/ { print $2 }' |
            sort -u
    )
    ((${#installed[@]} > 0)) || \
        die "No installed systemd packages were found; refusing to modify the container."

    mapfile -t held < <(apt-mark showhold 2>/dev/null || true)
    for package in "${held[@]}"; do
        was_held["${package%%:*}"]=1
    done
    for package in "${installed[@]}"; do
        [[ -n "${was_held[$package]:-}" ]] || APT_TEMPORARY_HOLDS+=("$package")
    done

    if ((${#APT_TEMPORARY_HOLDS[@]} > 0)); then
        log "Temporarily holding systemd/udev packages for this installation..."
        if ! apt-mark hold "${APT_TEMPORARY_HOLDS[@]}" >/dev/null; then
            apt-mark unhold "${APT_TEMPORARY_HOLDS[@]}" >/dev/null 2>&1 || true
            APT_TEMPORARY_HOLDS=()
            die "Could not hold the systemd/udev packages; refusing to continue."
        fi
    fi
}

protect_system_packages() {
    # DNF and Pacman are constrained per transaction below.
    case "$PACKAGE_KIND" in
        deb) protect_deb_system_packages ;;
        rpm|arch) ;;
    esac
}

append_bootstrap_package() {
    local package="$1"
    local existing

    for existing in "${BOOTSTRAP_PACKAGES[@]}"; do
        [[ "$existing" == "$package" ]] && return
    done
    BOOTSTRAP_PACKAGES+=("$package")
}

require_command_package() {
    command -v "$1" >/dev/null 2>&1 || append_bootstrap_package "$2"
}

collect_bootstrap_packages() {
    BOOTSTRAP_PACKAGES=()

    [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt ]] || \
        append_bootstrap_package ca-certificates
    require_command_package curl curl
    if [[ "$DOWNLOAD_SOURCE" != 3 ]]; then
        require_command_package jq jq
    fi
    require_command_package sha256sum coreutils
    require_command_package stat coreutils
    require_command_package sort coreutils
    require_command_package tar tar
    require_command_package find findutils
    require_command_package sed sed
    require_command_package gzip gzip

    case "$PACKAGE_KIND" in
        deb)
            require_command_package awk mawk
            require_command_package dpkg-deb dpkg
            ;;
        rpm)
            require_command_package awk gawk
            require_command_package rpm rpm
            ;;
        arch)
            require_command_package awk gawk
            require_command_package pacman pacman
            ;;
    esac
}

bootstrap_dependencies() {
    collect_bootstrap_packages
    if ((${#BOOTSTRAP_PACKAGES[@]} == 0)); then
        log "Download and verification tools are already available; skipping the package-manager transaction."
        return
    fi

    log "Preparing download and verification tools..."
    case "$PACKAGE_KIND" in
        deb)
            if ! apt-get update; then
                [[ "$TARGET" == ubuntu2510 ]] || \
                    die "Failed to update the APT repositories."
                local source_file
                log "The current Ubuntu 25.10 repositories are unavailable; falling back to old-releases..."
                for source_file in \
                    /etc/apt/sources.list \
                    /etc/apt/sources.list.d/*.list \
                    /etc/apt/sources.list.d/*.sources; do
                    [[ -f "$source_file" ]] || continue
                    sed -i \
                        -e 's|http://ports.ubuntu.com/ubuntu-ports|http://old-releases.ubuntu.com/ubuntu|g' \
                        -e 's|http://archive.ubuntu.com/ubuntu|http://old-releases.ubuntu.com/ubuntu|g' \
                        -e 's|http://security.ubuntu.com/ubuntu|http://old-releases.ubuntu.com/ubuntu|g' \
                        "$source_file"
                done
                apt-get update
            fi
            apt-get install -y --no-install-recommends "${BOOTSTRAP_PACKAGES[@]}"
            ;;
        rpm)
            dnf install -y --setopt=install_weak_deps=False --exclude='systemd*' \
                "${BOOTSTRAP_PACKAGES[@]}"
            ;;
        arch)
            # A full upgrade would replace Droidspaces' patched systemd and break networking.
            pacman -S --noconfirm --needed \
                --ignore systemd,systemd-libs,systemd-sysvcompat \
                "${BOOTSTRAP_PACKAGES[@]}"
            ;;
    esac

    collect_bootstrap_packages
    ((${#BOOTSTRAP_PACKAGES[@]} == 0)) || \
        die "Required packages are still unavailable: ${BOOTSTRAP_PACKAGES[*]}."
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
                "$GITHUB_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        2)
            printf '%s/%s/releases/download/%s/%s' \
                "$GH_PROXY_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
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
    local probe_url latency status=0

    probe_url="$(download_source_probe_url "$source")" || return 1
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
        status=$?
    fi

    if (( status == 28 )); then
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

release_download_base() {
    case "$DOWNLOAD_SOURCE" in
        1) printf '%s/%s/releases/download/%s' "$GITHUB_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        2) printf '%s/%s/releases/download/%s' "$GH_PROXY_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        3) printf '%s/%s/-/releases/download/%s' "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        *) return 1 ;;
    esac
}

download_file() {
    local url="$1"
    local destination="$2"

    if [[ -s "$destination" ]]; then
        log "Found an incomplete download; resuming: $(basename "$destination")"
        if curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 1800 \
            --continue-at - "$url" -o "$destination"; then
            return 0
        fi
        log "The server rejected resume or the existing file is invalid; restarting: $(basename "$destination")"
        rm -f -- "$destination"
    fi

    curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 1800 \
        "$url" -o "$destination"
}

fetch_release_metadata() {
    local url="$GITHUB_API_URL/repos/$RELEASE_REPOSITORY/releases/tags/$RELEASE_TAG"
    log "Reading official GitHub Release verification metadata..."
    if ! RELEASE_METADATA="$(curl -fsSL --retry 3 --retry-all-errors \
        --connect-timeout 20 --max-time 120 "$url")"; then
        log "Could not read GitHub Release metadata."
        return 1
    fi
    if ! jq -e --arg tag "$RELEASE_TAG" '.tag_name == $tag and .draft == false' \
        <<< "$RELEASE_METADATA" >/dev/null; then
        log "The GitHub Release state or tag is invalid."
        return 1
    fi
}

asset_metadata() {
    local name="$1"
    jq -er --arg name "$name" '
        [.assets[] | select(.name == $name)] |
        if length != 1 then error("asset is not unique")
        elif .[0].digest == null then error("asset digest is unavailable")
        else [.[0].digest, .[0].size] | @tsv
        end
    ' <<< "$RELEASE_METADATA"
}

verify_asset() {
    local file="$1"
    local name="$2"
    local maximum_size="$3"
    local metadata digest expected_sha expected_size actual_sha actual_size

    if ! metadata="$(asset_metadata "$name")"; then
        log "GitHub Release does not provide unique SHA-256 metadata for $name."
        return 1
    fi
    IFS=$'\t' read -r digest expected_size <<< "$metadata"
    if [[ ! "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        log "The SHA-256 format for $name is invalid."
        return 1
    fi
    expected_sha="${BASH_REMATCH[1],,}"
    if [[ ! "$expected_size" =~ ^[0-9]+$ ]]; then
        log "The Release size for $name is invalid."
        return 1
    fi
    if (( expected_size > maximum_size )); then
        log "$name exceeds the permitted download size."
        return 1
    fi

    actual_size="$(stat -c '%s' "$file")"
    if [[ "$actual_size" != "$expected_size" ]]; then
        log "The downloaded size of $name does not match GitHub Release metadata."
        return 1
    fi
    actual_sha="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        log "$name failed the official GitHub SHA-256 verification."
        return 1
    fi
}

resolve_archive_name() {
    local manifest="$1"
    local format manifest_tag selected checksum_key checksum_count checksum
    format="$(awk -F= '$1 == "format" {print substr($0, index($0, "=") + 1)}' "$manifest")"
    manifest_tag="$(awk -F= '$1 == "release_tag" {print substr($0, index($0, "=") + 1)}' "$manifest")"
    selected="$(awk -F= -v key="$TARGET" '$1 == key {print substr($0, index($0, "=") + 1)}' "$manifest")"

    [[ "$format" == 1 && "$manifest_tag" == "$RELEASE_TAG" ]] || \
        die "The Release manifest is invalid."
    case "$selected" in
        "hangover-wine-${TARGET}-"*"${ARCHIVE_SUFFIX}") ;;
        *)
            die "The Release manifest has no ARM64 package for $TARGET_LABEL."
            ;;
    esac
    [[ "$selected" =~ ^[A-Za-z0-9._+~_-]+$ && "$selected" != *..* ]] || \
        die "The asset name in the Release manifest is invalid."
    ARCHIVE_NAME="$selected"
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        checksum_key="${TARGET}_sha256"
        checksum_count="$(awk -F= -v key="$checksum_key" '$1 == key { count += 1 } END { print count + 0 }' "$manifest")" || return 1
        case "$checksum_count" in
            0)
                log "The legacy CNB Release manifest has no SHA-256 for ${ARCHIVE_NAME}; only archive structure and package metadata will be verified."
                ;;
            1)
                checksum="$(awk -F= -v key="$checksum_key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest")" || return 1
                [[ "$checksum" =~ ^[0-9A-Fa-f]{64}$ ]] || \
                    die "The CNB Release manifest has an invalid SHA-256 for ${ARCHIVE_NAME}."
                EXPECTED_ARCHIVE_SHA256="${checksum,,}"
                ;;
            *)
                die "The CNB Release manifest has multiple SHA-256 entries for ${ARCHIVE_NAME}."
                ;;
        esac
    fi
}

verify_cnb_archive() {
    local archive="$1" actual_checksum

    [[ -n "$EXPECTED_ARCHIVE_SHA256" ]] || return 0
    actual_checksum="$(sha256sum "$archive" | awk '{print $1}')" || return 1
    [[ "$actual_checksum" == "$EXPECTED_ARCHIVE_SHA256" ]]
}

validate_archive() {
    local archive="$1"
    local members entry archive_size
    archive_size="$(stat -c '%s' "$archive")" || \
        die "Unable to read the downloaded archive size."
    [[ "$archive_size" =~ ^[0-9]+$ && "$archive_size" -gt 0 && \
       "$archive_size" -le "$MAX_ARCHIVE_BYTES" ]] || \
        die "The downloaded archive size is invalid or exceeds the limit."
    members="$(tar -tzf "$archive")" || \
        die "The downloaded file is not a valid tar.gz archive."
    [[ -n "$members" ]] || die "The downloaded archive is empty."

    while IFS= read -r entry; do
        case "$entry" in
            /*|.|./*|..|../*|*/.|*/./*|*/..|*/../*)
                die "The archive contains an unsafe path."
                ;;
            "hangover-wine-packages/$TARGET"|"hangover-wine-packages/$TARGET/"*) ;;
            *)
                die "The archive contains files outside the selected target directory."
                ;;
        esac
    done <<< "$members"

    LC_ALL=C tar -tvzf "$archive" | awk -v maximum="$MAX_EXTRACTED_BYTES" '
        {
            type = substr($1, 1, 1)
            if (type !~ /^[-d]$/ || $3 !~ /^[0-9]+$/) exit 1
            total += $3
            if (total > maximum) exit 1
        }
    ' || die "The archive contains links, special files, or exceeds the extracted-size limit."
}

validate_packages() {
    local file architecture package
    local -a files=() names=()

    case "$PACKAGE_KIND" in
        deb)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
            ((${#files[@]} == 4)) || die "The deb package family is incomplete."
            for file in "${files[@]}"; do
                architecture="$(dpkg-deb -f "$file" Architecture)"
                [[ "$architecture" == arm64 || "$architecture" == all ]] || \
                    die "Deb architecture mismatch: ${file##*/}."
                names+=("$(dpkg-deb -f "$file" Package)")
            done
            mapfile -t names < <(printf '%s\n' "${names[@]}" | sort -u)
            [[ "${names[*]}" == 'hangover-libarm64ecfex hangover-libwow64fex hangover-wine hangover-wowbox64' ]] || \
                die "The deb family is missing Hangover runtime packages."
            ;;
        rpm)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
            ((${#files[@]} == 1)) || die "The RPM package count is invalid."
            package="$(rpm -qp --queryformat '%{NAME} %{ARCH}' "${files[0]}")"
            [[ "$package" == 'hangover-wine aarch64' ]] || \
                die "The RPM name or architecture is invalid."
            ;;
        arch)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
            ((${#files[@]} == 1)) || die "The Arch package count is invalid."
            package="$(pacman -Qp "${files[0]}" | awk 'NR == 1 {print $1}')"
            [[ "$package" == hangover-wine ]] || \
                die "The Arch package name is invalid."
            architecture="$(LC_ALL=C pacman -Qip "${files[0]}" | \
                sed -n 's/^[[:space:]]*Architecture[[:space:]]*:[[:space:]]*//p')"
            [[ "$architecture" == aarch64 || "$architecture" == any ]] || \
                die "The Arch package architecture is invalid."
            ;;
    esac
}

download_and_extract() {
    local base manifest archive attempt
    WORK_DIR="$(mktemp -d -t hangover-wine.XXXXXXXX)"
    install -d -m 0700 "$DOWNLOAD_CACHE_DIR"
    chmod 0700 "$DOWNLOAD_CACHE_DIR"
    base="$(release_download_base)"
    manifest="$DOWNLOAD_CACHE_DIR/$MANIFEST_NAME"

    for attempt in 1 2 3; do
        log "Downloading the Release manifest from $(download_source_name "$DOWNLOAD_SOURCE")..."
        if ! download_file "$base/$MANIFEST_NAME" "$manifest" || \
            { [[ "$DOWNLOAD_SOURCE" != 3 ]] && \
              { ! fetch_release_metadata || ! verify_asset "$manifest" "$MANIFEST_NAME" $((1024 * 1024)); }; }; then
            log "The Release is updating or the network failed; retrying ($attempt/3)."
            continue
        fi
        resolve_archive_name "$manifest"

        archive="$DOWNLOAD_CACHE_DIR/$ARCHIVE_NAME"
        log "Downloading $TARGET_LABEL packages: $ARCHIVE_NAME"
        if ! download_file "$base/$ARCHIVE_NAME" "$archive" || \
            { [[ "$DOWNLOAD_SOURCE" == 3 ]] && ! verify_cnb_archive "$archive"; } || \
            { [[ "$DOWNLOAD_SOURCE" != 3 ]] && \
              { ! fetch_release_metadata || ! verify_asset "$archive" "$ARCHIVE_NAME" "$MAX_ARCHIVE_BYTES"; }; }; then
            log "The Release is updating or the network failed; retrying ($attempt/3)."
            continue
        fi

        validate_archive "$archive"
        tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$WORK_DIR"
        PACKAGE_DIR="$WORK_DIR/hangover-wine-packages/$TARGET"
        [[ -d "$PACKAGE_DIR" ]] || die "No package directory was extracted."
        validate_packages
        return
    done

    die "Could not obtain a consistent Release package after three attempts; try again later."
}

install_packages() {
    local -a files=()
    local pacman_conf

    case "$PACKAGE_KIND" in
        deb)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
            log "Installing ${#files[@]} packages through APT and resolving dependencies..."
            apt-get install -y --reinstall --no-install-recommends --allow-downgrades "${files[@]}"
            ;;
        rpm)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
            log "Installing Hangover Wine through DNF..."
            dnf install -y --allowerasing --exclude='systemd*' "${files[@]}"
            ;;
        arch)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
            log "Installing Hangover Wine through Pacman..."
            log "Packages passed verification from the selected download source; unsigned local packages are allowed only for this transaction."

            pacman_conf="$WORK_DIR/pacman.conf"
            [[ -r /etc/pacman.conf ]] || die "Cannot read /etc/pacman.conf."
            cp /etc/pacman.conf "$pacman_conf"
            if grep -Eq '^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=' "$pacman_conf"; then
                sed -i -E 's/^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=.*/LocalFileSigLevel = Optional/' "$pacman_conf"
            elif grep -qE '^\[options\][[:space:]]*$' "$pacman_conf"; then
                sed -i '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' "$pacman_conf"
            else
                die "pacman.conf has no [options] section."
            fi

            if ! pacman --config "$pacman_conf" -U --noconfirm \
                --ignore systemd,systemd-libs,systemd-sysvcompat "${files[@]}"; then
                die "Arch package installation failed."
            fi
            ;;
    esac
}

main() {
    local wine_version archive_version

    parse_arguments "$@"
    validate_release_settings
    detect_target
    require_root "$@"
    if [[ "$UNINSTALL" == true ]]; then
        uninstall_hangover
        return
    fi
    protect_system_packages
    bootstrap_dependencies
    select_download_source
    log "Download source: $(download_source_name "$DOWNLOAD_SOURCE")"
    download_and_extract
    install_packages

    if ! command -v wine >/dev/null 2>&1; then
        die "The package transaction completed, but the wine command was not found."
    fi
    if ! wine_version="$(wine --version 2>&1)"; then
        die "The wine command exists, but startup validation failed: $wine_version"
    fi
    archive_version="${ARCHIVE_NAME#"hangover-wine-${TARGET}-"}"
    archive_version="${archive_version%"$ARCHIVE_SUFFIX"}"
    record_component_version "$archive_version"
    log "Installation complete: $wine_version"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
