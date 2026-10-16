#!/usr/bin/env bash

anland_package_family() {
    local desktop="${1:-}"
    local backend="${2:-}"

    [[ "$backend" == anland-wayland ]] || return 1
    case "$desktop" in
        kde|kde-mobile) printf '%s\n' kde ;;
        gnome) printf '%s\n' gnome ;;
        # The release is anland-session-packages / anland-session-manifest,
        # exactly the anland-${family}-packages / anland-${family}-manifest shape.
        anland-next) printf '%s\n' session ;;
        niri) printf '%s\n' niri ;;
        *) return 1 ;;
    esac
}

anland_prepare_release() {
    local family="${1:-}"
    local repository="${2:-}"
    local revision="${3:-}"
    local manifest release_manifest

    case "$family" in kde|gnome|session|niri) ;; *) return 1 ;; esac
    [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
        echo "Error: the Wayland package repository must use the owner/repository format." >&2
        return 1
    }

    ANLAND_RESOLVED_RELEASE_TAG="anland-${family}-packages"
    ANLAND_RESOLVED_REVISION="$revision"
    if [[ -n "$ANLAND_RESOLVED_REVISION" ]]; then
        [[ "$ANLAND_RESOLVED_REVISION" =~ ^[A-Za-z0-9._-]+$ ]] || {
            echo "Error: invalid Anland package revision format." >&2
            return 1
        }
        return
    fi

    command -v curl >/dev/null 2>&1 || {
        echo "Error: curl is required to read the package release manifest when Anland is enabled." >&2
        return 1
    }
    manifest="anland-${family}-manifest"
    if ! release_manifest="$(curl -fsSL --retry 3 --connect-timeout 20 \
        "https://github.com/${repository}/releases/download/${ANLAND_RESOLVED_RELEASE_TAG}/${manifest}")"; then
        echo "Error: unable to download the Anland ${family^^} package release manifest." >&2
        return 1
    fi

    ANLAND_RESOLVED_REVISION="$(printf '%s\n' "$release_manifest" | awk -F= '
        $1 == "format" { format = substr($0, index($0, "=") + 1) }
        $1 == "revision" { revision = substr($0, index($0, "=") + 1); revisions++ }
        END {
            if (format == "1" && revisions == 1 && revision ~ /^[A-Za-z0-9._-]+$/) {
                print revision
            }
        }
    ')"
    [[ -n "$ANLAND_RESOLVED_REVISION" ]] || {
        echo "Error: the release manifest has no valid revision." >&2
        return 1
    }
}
