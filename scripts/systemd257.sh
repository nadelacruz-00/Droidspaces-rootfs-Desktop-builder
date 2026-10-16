#!/usr/bin/env bash

# Install the complete systemd 257 package family, built with the distro's native packaging rules, for old Android kernels.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

readonly SYSTEMD257_TARGET_MAJOR=257
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly DEFAULT_RELEASE_REPOSITORY="Goldzxcbug/droidspaces-package"
# Rolling compatibility Release: each install fetches the official SHA-256 of the target
# asset from the GitHub Release API and verifies the archive, so package updates need no script change.
readonly DEFAULT_RELEASE_TAG="systemd257-packages"
readonly GITHUB_API_URL="https://api.github.com"
readonly MAX_ARCHIVE_BYTES=$((128 * 1024 * 1024))

RELEASE_REPOSITORY="${SYSTEMD257_RELEASE_REPOSITORY:-$DEFAULT_RELEASE_REPOSITORY}"
RELEASE_TAG="${SYSTEMD257_RELEASE_TAG:-$DEFAULT_RELEASE_TAG}"
WORK_DIR=""
PACKAGE_DIR=""
PACKAGE_MANAGER=""
TARGET=""
ARCHIVE_NAME=""
EXPECTED_ARCHIVE_SHA256=""
ARCHIVE_CHECKSUM_SOURCE=""
CURRENT_VERSION_LINE=""
SOURCE_VERSION=""
PACKAGING_SOURCE=""
OFFICIAL_RELEASE_METADATA=""

declare -a MANIFEST_FILES=()
declare -a PACKAGE_NAMES=()
declare -a SELECTED_NAMES=()
declare -a SELECTED_FILES=()
declare -a MANAGED_NAMES=()
declare -a DNF_REPLACEMENT_NAMES=()
declare -A PACKAGE_PATH=()
declare -A PACKAGE_VERSION=()
declare -A SELECTED_SET=()
declare -A DNF_REPLACEMENT_SET=()

log() {
  printf '[systemd257] %s\n' "$*"
}

die() {
  printf '[systemd257] error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

require_root() {
  if (( EUID != 0 )); then
    die "Please run as root: sudo bash systemd257.sh"
  fi
}

systemd_version_line() {
  local candidate line

  if command -v systemctl >/dev/null 2>&1; then
    line="$(systemctl --version 2>/dev/null | sed -n '1p')"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi

  for candidate in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    if [[ -x "$candidate" ]]; then
      line="$("$candidate" --version 2>/dev/null | sed -n '1p')"
      if [[ -n "$line" ]]; then
        printf '%s\n' "$line"
        return 0
      fi
    fi
  done

  return 1
}

systemd_major_from_line() {
  printf '%s\n' "$1" | awk '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+/) {
          sub(/[^0-9].*$/, "", $i)
          print $i
          exit
        }
      }
    }
  '
}

package_version_major() {
  local version="${1#*:}"

  if [[ "$version" =~ ^([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

is_systemd_family_name() {
  local name="${1%%:*}"

  case "$PACKAGE_MANAGER" in
    apt)
      [[ "$name" == systemd || "$name" == systemd-* || "$name" == udev ||
         "$name" == libsystemd* || "$name" == libudev* ||
         "$name" == libpam-systemd || "$name" == libnss-systemd ||
         "$name" == libnss-resolve || "$name" == libnss-myhostname ||
         "$name" == libnss-mymachines ]]
      ;;
    dnf|pacman)
      [[ "$name" == systemd || "$name" == systemd-* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

list_installed_family_packages() {
  local name version status

  case "$PACKAGE_MANAGER" in
    apt)
      while IFS=$'\t' read -r name version status; do
        name="${name%%:*}"
        if [[ "$status" == ii* ]] && is_systemd_family_name "$name"; then
          printf '%s\t%s\n' "$name" "$version"
        fi
      done < <(dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null)
      ;;
    dnf)
      while IFS=$'\t' read -r name version; do
        if is_systemd_family_name "$name"; then
          printf '%s\t%s\n' "$name" "$version"
        fi
      done < <(rpm -qa --queryformat '%{NAME}\t%{VERSION}-%{RELEASE}\n')
      ;;
    pacman)
      while IFS=' ' read -r name version; do
        if is_systemd_family_name "$name"; then
          printf '%s\t%s\n' "$name" "$version"
        fi
      done < <(pacman -Q)
      ;;
  esac
}

has_mismatched_family_packages() {
  local name version major

  while IFS=$'\t' read -r name version; do
    major="$(package_version_major "$version" || true)"
    if [[ "$major" != "$SYSTEMD257_TARGET_MAJOR" ]]; then
      log "detected a non-257 package: $name $version"
      return 0
    fi
  done < <(list_installed_family_packages)
  return 1
}

detect_target() {
  local distro_id version_id

  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  source /etc/os-release
  distro_id="${ID,,}"
  version_id="${VERSION_ID:-}"

  TARGET=""
  PACKAGE_MANAGER=""
  ARCHIVE_NAME=""

  case "$distro_id:$version_id" in
    ubuntu:26.04*)
      TARGET="ubuntu2604"
      PACKAGE_MANAGER="apt"
      ARCHIVE_NAME="systemd257-ubuntu2604-arm64.tar.gz"
      ;;
    fedora:43*)
      TARGET="fedora43"
      PACKAGE_MANAGER="dnf"
      ARCHIVE_NAME="systemd257-fedora43-arm64.tar.gz"
      ;;
    fedora:44*)
      TARGET="fedora44"
      PACKAGE_MANAGER="dnf"
      ARCHIVE_NAME="systemd257-fedora44-arm64.tar.gz"
      ;;
    arch:|archarm:|archlinux:)
      TARGET="arch"
      PACKAGE_MANAGER="pacman"
      ARCHIVE_NAME="systemd257-arch-arm64.tar.gz"
      ;;
    *)
      return 1
      ;;
  esac
}

verify_target_tools_and_architecture() {
  local architecture

  command -v curl >/dev/null 2>&1 || die "curl is missing, cannot download the prebuilt package family"
  if [[ -z "${SYSTEMD257_ARCHIVE_SHA256:-}" ]]; then
    command -v jq >/dev/null 2>&1 || die "jq is missing, cannot read the GitHub Release checksum"
  fi
  command -v tar >/dev/null 2>&1 || die "tar is missing, cannot extract the prebuilt package family"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is missing, cannot verify the prebuilt package family"

  case "$PACKAGE_MANAGER" in
    apt)
      command -v apt-get >/dev/null 2>&1 || die "the Ubuntu target is missing apt-get"
      command -v dpkg-query >/dev/null 2>&1 || die "the Ubuntu target is missing dpkg-query"
      command -v dpkg-deb >/dev/null 2>&1 || die "the Ubuntu target is missing dpkg-deb"
      architecture="$(dpkg --print-architecture)"
      [[ "$architecture" == arm64 ]] || die "the Ubuntu package family only supports arm64, current is $architecture"
      ;;
    dnf)
      command -v dnf >/dev/null 2>&1 || die "the Fedora target is missing dnf"
      command -v rpm >/dev/null 2>&1 || die "the Fedora target is missing rpm"
      architecture="$(rpm --eval '%{_arch}')"
      [[ "$architecture" == aarch64 ]] || die "the Fedora package family only supports aarch64, current is $architecture"
      ;;
    pacman)
      command -v pacman >/dev/null 2>&1 || die "the Arch target is missing pacman"
      command -v bsdtar >/dev/null 2>&1 || die "the Arch target is missing bsdtar"
      architecture="$(uname -m)"
      [[ "$architecture" == aarch64 || "$architecture" == arm64 ]] ||
        die "the Arch package family only supports aarch64, current is $architecture"
      ;;
  esac
}

fetch_official_release_metadata() {
  local api_url

  api_url="${GITHUB_API_URL}/repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}"
  if ! OFFICIAL_RELEASE_METADATA="$(curl --proto '=https' --tlsv1.2 -fsSL \
    --retry 5 --retry-all-errors --connect-timeout 30 "$api_url")"; then
    die "cannot read GitHub Release metadata: ${RELEASE_REPOSITORY}@${RELEASE_TAG}"
  fi
}

release_asset_sha256() {
  local digest

  # The dedicated package tag may be marked prerelease so that it does not occupy the repository's Latest release; drafts are still unusable.
  if ! digest="$(jq -er --arg name "$ARCHIVE_NAME" --arg tag "$RELEASE_TAG" '
    if .tag_name != $tag then
      error("release tag mismatch")
    elif (.draft // false) then
      error("release is still a draft")
    else
      [.assets[]? | select((.name // "") == $name) | .digest]
      | if length == 1 then .[0] else error("asset digest is not unique") end
    end
  ' <<< "$OFFICIAL_RELEASE_METADATA" 2>/dev/null)"; then
    die "GitHub Release did not provide a unique SHA-256 checksum for ${ARCHIVE_NAME}"
  fi
  [[ "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]] ||
    die "GitHub Release returned an invalid SHA-256 checksum for ${ARCHIVE_NAME}"

  printf '%s\n' "${BASH_REMATCH[1],,}"
}

resolve_archive_checksum() {
  [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "SYSTEMD257_RELEASE_REPOSITORY is not a valid GitHub owner/repository: $RELEASE_REPOSITORY"
  [[ "$RELEASE_TAG" =~ ^[A-Za-z0-9._+-]+$ ]] ||
    die "SYSTEMD257_RELEASE_TAG contains unsupported characters: $RELEASE_TAG"

  if [[ -n "${SYSTEMD257_ARCHIVE_SHA256:-}" ]]; then
    EXPECTED_ARCHIVE_SHA256="$SYSTEMD257_ARCHIVE_SHA256"
    ARCHIVE_CHECKSUM_SOURCE="SYSTEMD257_ARCHIVE_SHA256"
  else
    fetch_official_release_metadata
    EXPECTED_ARCHIVE_SHA256="$(release_asset_sha256)"
    ARCHIVE_CHECKSUM_SOURCE="github-release-api"
  fi
  [[ "$EXPECTED_ARCHIVE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "SYSTEMD257_ARCHIVE_SHA256 is not a valid SHA-256"
  EXPECTED_ARCHIVE_SHA256="${EXPECTED_ARCHIVE_SHA256,,}"
  log "obtained the SHA-256 for ${ARCHIVE_NAME} from ${ARCHIVE_CHECKSUM_SOURCE}"
}

download_archive() {
  local archive_file="$WORK_DIR/$ARCHIVE_NAME"
  local download_url archive_bytes

  if [[ -n "${SYSTEMD257_ARCHIVE_FILE:-}" ]]; then
    [[ -f "$SYSTEMD257_ARCHIVE_FILE" ]] ||
      die "local archive does not exist: $SYSTEMD257_ARCHIVE_FILE"
    log "using local archive: $SYSTEMD257_ARCHIVE_FILE"
    cp -- "$SYSTEMD257_ARCHIVE_FILE" "$archive_file"
  else
    download_url="https://github.com/${RELEASE_REPOSITORY}/releases/download/${RELEASE_TAG}/${ARCHIVE_NAME}"
    log "downloading $download_url"
    curl --proto '=https' --tlsv1.2 -fL --retry 5 --retry-all-errors \
      --connect-timeout 30 "$download_url" -o "$archive_file"
  fi

  [[ -s "$archive_file" ]] || die "the downloaded archive is empty: $ARCHIVE_NAME"
  archive_bytes="$(stat -c '%s' "$archive_file")"
  (( archive_bytes <= MAX_ARCHIVE_BYTES )) ||
    die "archive exceeds the ${MAX_ARCHIVE_BYTES}-byte limit: $archive_bytes"
  printf '%s  %s\n' "$EXPECTED_ARCHIVE_SHA256" "$archive_file" | sha256sum -c -
}

extract_and_verify_archive() {
  local archive_file="$WORK_DIR/$ARCHIVE_NAME"
  local entry checksum_name
  local -a actual_package_files=()

  PACKAGE_DIR="$WORK_DIR/packages"
  mkdir -p "$PACKAGE_DIR"

  while IFS= read -r entry; do
    [[ "$entry" == ./ ]] && continue
    entry="${entry#./}"
    [[ "$entry" =~ ^[A-Za-z0-9][A-Za-z0-9._+~:-]*$ ]] ||
      die "archive contains an unsafe or unexpected path: $entry"
  done < <(tar -tzf "$archive_file")

  tar -xzf "$archive_file" --no-same-owner --no-same-permissions -C "$PACKAGE_DIR"
  [[ -f "$PACKAGE_DIR/manifest.env" ]] || die "archive is missing manifest.env"
  [[ -f "$PACKAGE_DIR/SHA256SUMS" ]] || die "archive is missing the internal SHA256SUMS"

  while read -r _ checksum_name; do
    checksum_name="${checksum_name#\*}"
    [[ "$checksum_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+~:-]*$ ]] ||
      die "internal SHA256SUMS contains an unsafe path: $checksum_name"
  done < "$PACKAGE_DIR/SHA256SUMS"
  (cd "$PACKAGE_DIR" && sha256sum --check --strict SHA256SUMS)

  verify_manifest

  case "$PACKAGE_MANAGER" in
    apt)
      mapfile -t actual_package_files < <(
        find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort
      )
      ;;
    dnf)
      mapfile -t actual_package_files < <(
        find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -printf '%f\n' | sort
      )
      ;;
    pacman)
      mapfile -t actual_package_files < <(
        find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -printf '%f\n' | sort
      )
      ;;
  esac

  if (( ${#actual_package_files[@]} != ${#MANIFEST_FILES[@]} )); then
    die "manifest package count does not match the archive: manifest=${#MANIFEST_FILES[@]} archive=${#actual_package_files[@]}"
  fi
  if [[ "$(printf '%s\n' "${MANIFEST_FILES[@]}" | sort)" != \
        "$(printf '%s\n' "${actual_package_files[@]}" | sort)" ]]; then
    die "manifest package list does not match the archive contents"
  fi
}

manifest_value() {
  local key="$1"

  awk -F= -v wanted="$key" '
    $1 == wanted {
      count++
      print substr($0, index($0, "=") + 1)
    }
    END { if (count != 1) exit 1 }
  ' "$PACKAGE_DIR/manifest.env"
}

verify_manifest() {
  local format manifest_target architecture compat_patch package_count

  format="$(manifest_value format)" || die "invalid format field in manifest.env"
  manifest_target="$(manifest_value target)" || die "invalid target field in manifest.env"
  architecture="$(manifest_value architecture)" || die "invalid architecture field in manifest.env"
  SOURCE_VERSION="$(manifest_value systemd_source_version)" ||
    die "invalid systemd_source_version field in manifest.env"
  PACKAGING_SOURCE="$(manifest_value packaging_source)" ||
    die "invalid packaging_source field in manifest.env"
  compat_patch="$(manifest_value compat_patch)" || die "invalid compat_patch field in manifest.env"
  package_count="$(manifest_value package_count)" || die "invalid package_count field in manifest.env"

  [[ "$format" == 1 ]] || die "unsupported manifest format: $format"
  [[ "$manifest_target" == "$TARGET" ]] ||
    die "archive target mismatch: expected $TARGET, got $manifest_target"
  [[ "$architecture" == aarch64 ]] || die "archive architecture is not aarch64: $architecture"
  [[ "$(package_version_major "$SOURCE_VERSION" || true)" == "$SYSTEMD257_TARGET_MAJOR" ]] ||
    die "archive source version is not systemd 257: $SOURCE_VERSION"
  [[ "$compat_patch" == 0001-droidspaces-old-kernel-compat.patch ]] ||
    die "archive does not declare the Droidspaces old-kernel compatibility patch"
  [[ "$package_count" =~ ^[1-9][0-9]*$ ]] || die "invalid manifest package count: $package_count"
  mapfile -t MANIFEST_FILES < <(sed -n 's/^package=//p' "$PACKAGE_DIR/manifest.env")
  (( ${#MANIFEST_FILES[@]} == package_count )) ||
    die "manifest package_count does not match the number of package entries"

  local package_file
  for package_file in "${MANIFEST_FILES[@]}"; do
    [[ "$package_file" =~ ^[A-Za-z0-9][A-Za-z0-9._+~:-]*$ ]] ||
      die "unsafe manifest package file name: $package_file"
    [[ -f "$PACKAGE_DIR/$package_file" ]] || die "package specified by the manifest does not exist: $package_file"
  done
}

register_package() {
  local name="$1"
  local version="$2"
  local architecture="$3"
  local path="$4"
  local major

  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || die "invalid package name: $name"
  is_systemd_family_name "$name" || die "archive contains a non-systemd-family member: $name"
  [[ -z "${PACKAGE_PATH[$name]+present}" ]] || die "archive contains a duplicate package: $name"

  major="$(package_version_major "$version" || true)"
  [[ "$major" == "$SYSTEMD257_TARGET_MAJOR" ]] ||
    die "package $name version is not 257: $version"

  case "$PACKAGE_MANAGER:$architecture" in
    apt:arm64|apt:all|dnf:aarch64|dnf:noarch|pacman:aarch64|pacman:any) ;;
    *) die "package $name architecture mismatch: $architecture" ;;
  esac

  PACKAGE_NAMES+=("$name")
  PACKAGE_PATH["$name"]="$path"
  PACKAGE_VERSION["$name"]="$version"
}

load_package_metadata() {
  local package_file path name version architecture

  for package_file in "${MANIFEST_FILES[@]}"; do
    path="$PACKAGE_DIR/$package_file"
    case "$PACKAGE_MANAGER" in
      apt)
        [[ "$package_file" == *.deb ]] || die "the Ubuntu archive contains a non-DEB file: $package_file"
        name="$(dpkg-deb -f "$path" Package)"
        version="$(dpkg-deb -f "$path" Version)"
        architecture="$(dpkg-deb -f "$path" Architecture)"
        ;;
      dnf)
        [[ "$package_file" == *.rpm ]] || die "the Fedora archive contains a non-RPM file: $package_file"
        name="$(rpm -qp --queryformat '%{NAME}' "$path")"
        version="$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$path")"
        architecture="$(rpm -qp --queryformat '%{ARCH}' "$path")"
        ;;
      pacman)
        [[ "$package_file" == *.pkg.tar.* && "$package_file" != *.sig ]] ||
          die "the Arch archive contains a non-pacman package: $package_file"
        name="$(bsdtar -xOf "$path" .PKGINFO | sed -n 's/^pkgname = //p')"
        version="$(bsdtar -xOf "$path" .PKGINFO | sed -n 's/^pkgver = //p')"
        architecture="$(bsdtar -xOf "$path" .PKGINFO | sed -n 's/^arch = //p')"
        ;;
    esac
    [[ -n "$name" && -n "$version" && -n "$architecture" ]] ||
      die "cannot read package metadata: $package_file"
    register_package "$name" "$version" "$architecture" "$path"
  done
}

package_is_installed() {
  local name="$1"

  case "$PACKAGE_MANAGER" in
    apt)
      [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$name" 2>/dev/null || true)" == ii* ]]
      ;;
    dnf)
      rpm -q "$name" >/dev/null 2>&1
      ;;
    pacman)
      pacman -Qq "$name" >/dev/null 2>&1
      ;;
  esac
}

installed_package_version() {
  local name="$1"

  case "$PACKAGE_MANAGER" in
    apt) dpkg-query -W -f='${Version}' "$name" ;;
    dnf) rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$name" ;;
    pacman) pacman -Q "$name" | awk 'NR == 1 { print $2 }' ;;
  esac
}

ensure_no_uncovered_mismatched_packages() {
  local name version major

  while IFS=$'\t' read -r name version; do
    major="$(package_version_major "$version" || true)"
    if [[ "$major" != "$SYSTEMD257_TARGET_MAJOR" ]] &&
       [[ -z "${PACKAGE_PATH[$name]+present}" ]]; then
      die "installed $name ($version) has no corresponding 257 package, refusing to create a hybrid runtime"
    fi
  done < <(list_installed_family_packages)
}

collect_dnf_replacement_candidates() {
  local name

  [[ "$PACKAGE_MANAGER" == dnf ]] || return 0

  DNF_REPLACEMENT_NAMES=()
  DNF_REPLACEMENT_SET=()
  for name in "${PACKAGE_NAMES[@]}"; do
    [[ "$name" == systemd-standalone-* ]] || continue
    if package_is_installed "$name"; then
      DNF_REPLACEMENT_NAMES+=("$name")
      DNF_REPLACEMENT_SET["$name"]=1
      log "DNF will replace the conflicting package with the complete systemd main package: $name"
    fi
  done
}

add_selected_package() {
  local name="$1"

  [[ -n "${PACKAGE_PATH[$name]+present}" ]] || die "archive is missing a core package: $name"
  if [[ -z "${SELECTED_SET[$name]+present}" ]]; then
    SELECTED_SET["$name"]=1
    SELECTED_NAMES+=("$name")
    SELECTED_FILES+=("${PACKAGE_PATH[$name]}")
  fi
}

select_packages() {
  local name
  local -a core_names=()

  for name in "${PACKAGE_NAMES[@]}"; do
    if [[ "$name" == systemd-standalone-* ]]; then
      continue
    fi
    if package_is_installed "$name"; then
      add_selected_package "$name"
    fi
  done

  case "$PACKAGE_MANAGER" in
    apt)
      core_names=(
        libsystemd0 libsystemd-shared libudev1 libpam-systemd libnss-systemd
        systemd udev systemd-sysv systemd-timesyncd systemd-resolved
      )
      ;;
    dnf)
      core_names=(
        systemd systemd-libs systemd-shared systemd-pam systemd-udev
        systemd-networkd systemd-resolved systemd-sysusers
      )
      ;;
    pacman)
      core_names=(systemd-libs systemd systemd-sysvcompat)
      ;;
  esac

  for name in "${core_names[@]}"; do
    add_selected_package "$name"
  done

  (( ${#SELECTED_FILES[@]} > 0 )) || die "no installable packages were selected"
  log "installing ${#SELECTED_FILES[@]} 257 packages: ${SELECTED_NAMES[*]}"
}

snapshot_dnf_package_names() {
  local output_file="$1"

  rpm -qa --queryformat '%{NAME}\n' | LC_ALL=C sort -u > "$output_file"
}

verify_controlled_dnf_removals() {
  local before_file="$1"
  local after_file="$2"
  local name
  local -a unexpected_removals=()
  local -A installed_after=()

  while IFS= read -r name; do
    [[ -n "$name" ]] && installed_after["$name"]=1
  done < "$after_file"

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -z "${installed_after[$name]+present}" &&
          -z "${DNF_REPLACEMENT_SET[$name]+present}" ]]; then
      unexpected_removals+=("$name")
    fi
  done < "$before_file"

  if (( ${#unexpected_removals[@]} > 0 )); then
    die "the DNF transaction unexpectedly removed unauthorized packages: ${unexpected_removals[*]}"
  fi

  for name in "${DNF_REPLACEMENT_NAMES[@]}"; do
    [[ -z "${installed_after[$name]+present}" ]] ||
      die "DNF failed to replace the conflicting package with the complete systemd main package: $name"
  done
}

prepare_pacman_transaction_config() {
  local output_file="$1"
  local selected_packages

  printf -v selected_packages '%s ' "${SELECTED_NAMES[@]}"
  selected_packages="${selected_packages% }"

  awk -v selected="$selected_packages" '
    BEGIN {
      count = split(selected, names, /[[:space:]]+/)
      for (i = 1; i <= count; i++) remove[names[i]] = 1
      remove["systemd*"] = 1
    }
    function write_filtered_ignore(line, equals, value, token_count, tokens, i, output) {
      equals = index(line, "=")
      value = substr(line, equals + 1)
      token_count = split(value, tokens, /[[:space:]]+/)
      output = ""
      for (i = 1; i <= token_count; i++) {
        if (tokens[i] != "" && !remove[tokens[i]]) {
          output = output (output == "" ? "" : " ") tokens[i]
        }
      }
      if (output != "") print "IgnorePkg = " output
    }
    /^\[options\][[:space:]]*$/ {
      in_options = 1
      saw_options = 1
      print
      next
    }
    /^\[[^]]+\][[:space:]]*$/ {
      if (in_options && !wrote_local_siglevel) {
        print "LocalFileSigLevel = Optional"
        wrote_local_siglevel = 1
      }
      in_options = 0
      print
      next
    }
    in_options && /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
      write_filtered_ignore($0)
      next
    }
    in_options && /^[[:space:]]*LocalFileSigLevel[[:space:]]*=/ {
      if (!wrote_local_siglevel) {
        print "LocalFileSigLevel = Optional"
        wrote_local_siglevel = 1
      }
      next
    }
    { print }
    END {
      if (in_options && !wrote_local_siglevel) {
        print "LocalFileSigLevel = Optional"
      }
      if (!saw_options) exit 1
    }
  ' /etc/pacman.conf > "$output_file"
}

install_selected_packages() {
  local dnf_before="$WORK_DIR/dnf-packages.before"
  local dnf_after="$WORK_DIR/dnf-packages.after"
  local -a dnf_global_options=(
    --setopt=excludepkgs=
    --setopt=install_weak_deps=False
  )
  local -a dnf_install_options=(
    --allow-downgrade
  )

  log "installing the complete systemd 257 runtime through $PACKAGE_MANAGER"

  case "$PACKAGE_MANAGER" in
    apt)
      apt-get -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        install -y --no-install-recommends --allow-downgrades \
        --allow-change-held-packages --no-remove "${SELECTED_FILES[@]}"
      apt-get check
      ;;
    dnf)
      snapshot_dnf_package_names "$dnf_before"
      if (( ${#DNF_REPLACEMENT_NAMES[@]} > 0 )); then
        dnf_install_options+=(--allowerasing)
      fi
      dnf "${dnf_global_options[@]}" install -y \
        "${dnf_install_options[@]}" "${SELECTED_FILES[@]}"
      snapshot_dnf_package_names "$dnf_after"
      verify_controlled_dnf_removals "$dnf_before" "$dnf_after"
      dnf check
      ;;
    pacman)
      local transaction_config="$WORK_DIR/pacman.conf"
      prepare_pacman_transaction_config "$transaction_config" ||
        die "/etc/pacman.conf is missing a valid [options] section"
      pacman --config "$transaction_config" -U --noconfirm "${SELECTED_FILES[@]}"
      pacman -Dk
      ;;
  esac
}

package_owner() {
  local path="$1"
  local result owner

  case "$PACKAGE_MANAGER" in
    apt)
      result="$(dpkg-query -S "$path" 2>/dev/null | sed -n '1p' || true)"
      owner="${result%%: *}"
      owner="${owner%%:*}"
      ;;
    dnf)
      owner="$(rpm -qf --queryformat '%{NAME}' "$path" 2>/dev/null || true)"
      ;;
    pacman)
      owner="$(LC_ALL=C pacman -Qoq "$path" 2>/dev/null | sed -n '1p' || true)"
      ;;
  esac
  printf '%s\n' "$owner"
}

verify_installed_family() {
  local name expected actual major daemon="" ldd_output installed_version_line installed_major

  MANAGED_NAMES=()
  for name in "${PACKAGE_NAMES[@]}"; do
    if package_is_installed "$name"; then
      expected="${PACKAGE_VERSION[$name]}"
      actual="$(installed_package_version "$name")"
      [[ "$actual" == "$expected" ]] ||
        die "mixed package versions detected: $name has $actual installed, the archive requires $expected"
      MANAGED_NAMES+=("$name")
    fi
  done

  while IFS=$'\t' read -r name actual; do
    major="$(package_version_major "$actual" || true)"
    [[ "$major" == "$SYSTEMD257_TARGET_MAJOR" ]] ||
      die "non-257 systemd family members still present after install: $name $actual"
  done < <(list_installed_family_packages)

  for expected in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    if [[ -x "$expected" ]]; then
      daemon="$expected"
      break
    fi
  done
  [[ -n "$daemon" ]] || die "systemd PID 1 not found after install"
  [[ "$(package_owner "$daemon")" == systemd ]] ||
    die "systemd PID 1 is not registered to the systemd main package: $daemon"

  if command -v ldd >/dev/null 2>&1; then
    ldd_output="$(ldd "$daemon" 2>&1 || true)"
    if grep -q 'not found' <<< "$ldd_output"; then
      printf '%s\n' "$ldd_output" >&2
      die "systemd 257 PID 1 has missing shared libraries"
    fi
  fi

  installed_version_line="$(systemd_version_line || true)"
  installed_major="$(systemd_major_from_line "$installed_version_line")"
  [[ "$installed_major" == "$SYSTEMD257_TARGET_MAJOR" ]] ||
    die "runtime version verification failed: ${installed_version_line:-unknown}"
  CURRENT_VERSION_LINE="$installed_version_line"
}

configure_apt_holds() {
  if (( ${#MANAGED_NAMES[@]} > 0 )); then
    apt-mark hold "${MANAGED_NAMES[@]}"
  fi
}

write_dnf_config_with_systemd_hold() {
  local input_file="$1"
  local output_file="$2"

  # Do not use sed's 0,/pattern/ range substitution: that range would hit [main] and every line
  # in between, appending systemd* after the section header. Read the whole config first and write the hold only into the [main] section.
  awk '
    function option_name(line) {
      if (line ~ /^[[:space:]]*exclude[[:space:]]*=/) {
        return "exclude"
      }
      if (line ~ /^[[:space:]]*excludepkgs[[:space:]]*=/) {
        return "excludepkgs"
      }
      return ""
    }
    function has_systemd_pattern(line, equals, value, normalized, count, tokens, i) {
      equals = index(line, "=")
      value = substr(line, equals + 1)
      normalized = value
      gsub(/,/, " ", normalized)
      count = split(normalized, tokens, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (tokens[i] == "systemd*") {
          return 1
        }
      }
      return 0
    }
    function append_systemd_pattern(line, equals, value, trimmed, separator) {
      equals = index(line, "=")
      value = substr(line, equals + 1)
      trimmed = value
      sub(/[[:space:]]+$/, "", trimmed)
      separator = (trimmed == "" || trimmed ~ /,$/) ? "" : ","
      return substr(line, 1, equals) value separator "systemd*"
    }
    {
      lines[++line_count] = $0
    }
    END {
      in_main = 0
      for (i = 1; i <= line_count; i++) {
        line = lines[i]
        if (line ~ /^[[:space:]]*\[main\][[:space:]]*$/) {
          in_main = 1
          saw_main = 1
          continue
        }
        if (line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
          in_main = 0
          continue
        }
        if (!in_main) {
          continue
        }
        option = option_name(line)
        if (option == "") {
          continue
        }
        if (option == "exclude") {
          saw_exclude = 1
        } else {
          saw_excludepkgs = 1
        }
        if (has_systemd_pattern(line)) {
          has_systemd = 1
        }
      }

      # DNF treats exclude and excludepkgs as the same appended list. As with Anland/Mesa,
      # use a different key when the other one already exists, to avoid duplicate keys or disturbing other managed blocks.
      if (saw_exclude && !saw_excludepkgs) {
        target_option = "excludepkgs"
      } else if (!saw_exclude && saw_excludepkgs) {
        target_option = "exclude"
      } else {
        target_option = "exclude"
      }
      update_existing = saw_exclude && saw_excludepkgs

      in_main = 0
      for (i = 1; i <= line_count; i++) {
        line = lines[i]
        if (line ~ /^[[:space:]]*\[main\][[:space:]]*$/) {
          if (in_main && !has_systemd && !wrote_hold) {
            print target_option "=systemd*"
            wrote_hold = 1
          }
          in_main = 1
          print line
          continue
        }
        if (line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
          if (in_main && !has_systemd && !wrote_hold) {
            print target_option "=systemd*"
            wrote_hold = 1
          }
          in_main = 0
          print line
          continue
        }
        if (in_main && !has_systemd && update_existing && !wrote_hold &&
            option_name(line) == target_option) {
          print append_systemd_pattern(line)
          wrote_hold = 1
          continue
        }
        print line
      }

      if (in_main && !has_systemd && !wrote_hold) {
        print target_option "=systemd*"
        wrote_hold = 1
      }
      if (!saw_main && !has_systemd) {
        print "[main]"
        print "exclude=systemd*"
      }
    }
  ' "$input_file" > "$output_file"
}

configure_dnf_holds() {
  local dnf_config="/etc/dnf/dnf.conf"
  local temporary_config="$WORK_DIR/dnf.conf.systemd257"
  local backup_config="$WORK_DIR/dnf.conf.systemd257.backup"

  install -d -m 0755 "$(dirname "$dnf_config")"
  if [[ ! -e "$dnf_config" ]]; then
    install -m 0644 /dev/null "$dnf_config"
  fi
  [[ -f "$dnf_config" ]] || die "the DNF configuration is not a regular file: $dnf_config"

  if ! write_dnf_config_with_systemd_hold "$dnf_config" "$temporary_config"; then
    die "unable to generate the DNF systemd 257 hold configuration"
  fi
  cp -p "$dnf_config" "$backup_config"
  install -m 0644 "$temporary_config" "$dnf_config"
  # Have DNF parse the final configuration immediately, so that config corruption is not only exposed in a later Dockerfile layer.
  if ! dnf check; then
    install -m 0644 "$backup_config" "$dnf_config" ||
      die "DNF hold configuration validation failed, and the original configuration could not be restored: $dnf_config"
    die "DNF rejected the systemd 257 hold configuration; the original configuration was restored"
  fi
}

configure_pacman_holds() {
  local name current_ignored packages_line

  printf -v packages_line '%s ' "${MANAGED_NAMES[@]}"
  packages_line="${packages_line% }"
  [[ -n "$packages_line" ]] || return 0

  if grep -q '^[[:space:]]*IgnorePkg[[:space:]]*=' /etc/pacman.conf; then
    current_ignored="$(
      sed -n 's/^[[:space:]]*IgnorePkg[[:space:]]*=[[:space:]]*//p' /etc/pacman.conf | head -n1
    )"
    for name in "${MANAGED_NAMES[@]}"; do
      case " $current_ignored " in
        *" $name "*) ;;
        *)
          sed -i "/^[[:space:]]*IgnorePkg[[:space:]]*=/{s/$/ $name/;}" /etc/pacman.conf
          current_ignored="$current_ignored $name"
          ;;
      esac
    done
  else
    grep -q '^\[options\][[:space:]]*$' /etc/pacman.conf ||
      die "/etc/pacman.conf is missing the [options] section, cannot hold the 257 package family"
    sed -i "/^\[options\][[:space:]]*$/a IgnorePkg = $packages_line" /etc/pacman.conf
  fi
}

configure_package_holds() {
  case "$PACKAGE_MANAGER" in
    apt) configure_apt_holds ;;
    dnf) configure_dnf_holds ;;
    pacman) configure_pacman_holds ;;
  esac
}

write_state_file() {
  local state_temp="$WORK_DIR/droidspaces-systemd257"
  local managed_packages_csv main_version

  printf -v managed_packages_csv '%s,' "${MANAGED_NAMES[@]}"
  managed_packages_csv="${managed_packages_csv%,}"
  main_version="${PACKAGE_VERSION[systemd]}"

  cat > "$state_temp" <<EOF
previous_version=$PREVIOUS_VERSION_LINE
installed_version=$CURRENT_VERSION_LINE
source_version=$SOURCE_VERSION
source_ref=v$SOURCE_VERSION
source_commit=not-recorded
package_manager=$PACKAGE_MANAGER
managed_package=systemd
managed_package_version=$main_version
install_mode=package-family
release_repository=$RELEASE_REPOSITORY
release_tag=$RELEASE_TAG
release_asset=$ARCHIVE_NAME
archive_sha256=$EXPECTED_ARCHIVE_SHA256
archive_checksum_source=$ARCHIVE_CHECKSUM_SOURCE
packaging_source=$PACKAGING_SOURCE
managed_packages=$managed_packages_csv
EOF
  install -m 0644 "$state_temp" "$SYSTEMD257_STATE"
}

main() {
  local current_major

  require_root
  CURRENT_VERSION_LINE="$(systemd_version_line || true)"
  [[ -n "$CURRENT_VERSION_LINE" ]] || die "unable to detect the current systemd version"
  current_major="$(systemd_major_from_line "$CURRENT_VERSION_LINE")"
  [[ "$current_major" =~ ^[0-9]+$ ]] ||
    die "unable to extract the major version from the version info: $CURRENT_VERSION_LINE"
  readonly PREVIOUS_VERSION_LINE="$CURRENT_VERSION_LINE"

  log "current version: $CURRENT_VERSION_LINE"
  if (( current_major < SYSTEMD257_TARGET_MAJOR )); then
    log "systemd $current_major is lower than 257, skipping installation"
    return 0
  fi

  if ! detect_target; then
    if (( current_major == SYSTEMD257_TARGET_MAJOR )); then
      log "the current distribution already runs systemd 257, no prebuilt package family needed"
      return 0
    fi
    die "the current distribution has no prebuilt 257 package family; only Ubuntu 26.04, Fedora 43/44 and Arch Linux ARM are supported"
  fi

  verify_target_tools_and_architecture
  if (( current_major == SYSTEMD257_TARGET_MAJOR )) && ! has_mismatched_family_packages; then
    log "the runtime and the installed systemd package family are both 257, no need to reinstall"
    return 0
  fi

  resolve_archive_checksum
  WORK_DIR="$(mktemp -d -t systemd257.XXXXXXXX)"
  download_archive
  extract_and_verify_archive
  load_package_metadata
  collect_dnf_replacement_candidates
  ensure_no_uncovered_mismatched_packages
  select_packages
  install_selected_packages
  verify_installed_family
  configure_package_holds
  write_state_file

  log "done: $CURRENT_VERSION_LINE (${#MANAGED_NAMES[@]} packages managed by $PACKAGE_MANAGER)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
