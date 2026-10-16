#!/bin/bash

# Keep apt from showing interactive configuration prompts; intended for unattended builds.
export DEBIAN_FRONTEND=noninteractive

# Stopping services, unmounting mount points, and changing apt configuration all require root.
if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash nosnap.sh"
  exit 1
fi

echo "[nosnap] Stopping snapd services"
# Some minimal RootFS images have no systemctl, so check that the command exists first.
# stop terminates the current processes; disable keeps snapd from starting again on the next boot.
if command -v systemctl >/dev/null 2>&1; then
  for unit in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service; do
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done
fi

echo "[nosnap] Unmounting Snap mount points"
# Unmount snapd's loop/bind mounts before deleting its files so the directories are not busy.
# sort -r unmounts deeper sub-mounts first; -l/-f handle leftover mounts inside containers.
if command -v mount >/dev/null 2>&1 && command -v umount >/dev/null 2>&1; then
  for mountpoint in $(mount | awk '$3 ~ "^/snap" || $3 ~ "^/var/snap" || $3 ~ "^/var/lib/snapd" { print $3 }' | sort -r); do
    umount -lf "$mountpoint" >/dev/null 2>&1 || true
  done
fi

echo "[nosnap] Purging snapd packages"
# Only handle packages that are installed, so apt does not abort the build when a purge target is missing.
# Also remove the Snap backends used by desktop environments such as GNOME Software and Discover.
if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
  for package in snapd gnome-software-plugin-snap snapd-desktop-integration plasma-discover-backend-snap; do
    if dpkg -s "$package" >/dev/null 2>&1; then
      apt-get purge -y "$package" >/dev/null 2>&1 || true
    fi
  done
  apt-get autoremove -y --purge >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
fi

echo "[nosnap] Cleaning up leftover Snap files"
# Clean up mount directories, caches, user data, and systemd units that may survive package removal.
rm -rf \
  /snap \
  /var/snap \
  /var/lib/snapd \
  /var/cache/snapd \
  /usr/lib/snapd \
  /etc/systemd/system/snapd* \
  /etc/apt/apt.conf.d/*snap* \
  "$HOME/snap" \
  /home/*/snap

echo "[nosnap] Blocking APT from reinstalling snapd"
# A negative priority keeps later dependency resolution from pulling snapd and its desktop integration back in.
# Ubuntu's chromium-browser is a transitional package that pulls in the Chromium Snap, so block it too.
mkdir -p /etc/apt/preferences.d
cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
Package: snapd snapd-desktop-integration gnome-software-plugin-snap plasma-discover-backend-snap
Pin: release a=*
Pin-Priority: -10

Package: chromium-browser
Pin: release o=Ubuntu
Pin-Priority: -10
EOF

# Verify that the pin file was written; without it later apt operations would reintroduce Snap.
if [ ! -f /etc/apt/preferences.d/nosnap.pref ]; then
  echo "[nosnap] Failed to write the APT pin configuration"
  exit 1
fi

echo "[nosnap] Adding ppa:xtradeb/apps"
# XtraDeb provides classic deb packages for some Ubuntu software, replacing sources that only offer Snap/transitional packages.
# Prefer UBUNTU_CODENAME while staying compatible with systems that only set VERSION_CODENAME.
xtradeb_codename=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  xtradeb_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
fi

# Download text to stdout for API queries and repository availability probes.
download_stdout() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    return 1
  fi
}

# Download content to a file, preferring curl and falling back to wget in minimal environments.
download_file() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" > "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    return 1
  fi
}

# Read the repository Release file to decide whether the PPA has published the given Ubuntu codename.
release_exists() {
  download_stdout "$1" >/dev/null 2>&1
}

if [ -n "$xtradeb_codename" ]; then
  xtradeb_key=""
  xtradeb_source_codename=""
  xtradeb_api="https://api.launchpad.net/1.0/~xtradeb/+archive/ubuntu/apps"
  xtradeb_candidates="$xtradeb_codename"

  # A freshly released Ubuntu version may not have a matching PPA repository yet,
  # so fall back through compatible codenames from newest to oldest instead of failing the whole RootFS build.
  case "$xtradeb_codename" in
    resolute)
      xtradeb_candidates="$xtradeb_codename questing plucky noble"
      ;;
    questing)
      xtradeb_candidates="$xtradeb_codename plucky noble"
      ;;
    plucky|oracular)
      xtradeb_candidates="$xtradeb_codename noble"
      ;;
  esac

  # Fetch the signing key fingerprint from the Launchpad API so a rotating key is never hardcoded in the script.
  xtradeb_key="$(download_stdout "$xtradeb_api" 2>/dev/null | awk -F'"' '/signing_key_fingerprint/ { print $4; exit }')"

  # Pick the first codename in the candidate list that really has Release metadata.
  for candidate in $xtradeb_candidates; do
    xtradeb_release="https://ppa.launchpadcontent.net/xtradeb/apps/ubuntu/dists/${candidate}/Release"
    if release_exists "$xtradeb_release"; then
      xtradeb_source_codename="$candidate"
      break
    fi
  done

  if [ -n "$xtradeb_source_codename" ] && [ -n "$xtradeb_key" ]; then
    mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
    # Delete the empty file right away if the key download fails, so apt does not mistake it for a valid keyring.
    download_file "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${xtradeb_key}" /etc/apt/keyrings/xtradeb-apps.asc 2>/dev/null || rm -f /etc/apt/keyrings/xtradeb-apps.asc

    if [ -s /etc/apt/keyrings/xtradeb-apps.asc ]; then
      chmod 0644 /etc/apt/keyrings/xtradeb-apps.asc
      # signed-by limits the trust of this repository to the dedicated key file.
      echo "deb [signed-by=/etc/apt/keyrings/xtradeb-apps.asc] https://ppa.launchpadcontent.net/xtradeb/apps/ubuntu ${xtradeb_source_codename} main" > /etc/apt/sources.list.d/xtradeb-apps.list
      if [ "$xtradeb_source_codename" != "$xtradeb_codename" ]; then
        echo "[nosnap] ppa:xtradeb/apps has not published ${xtradeb_codename}; using ${xtradeb_source_codename} instead"
      fi
    else
      echo "[nosnap] Failed to fetch the XtraDeb signing key; skipping ppa:xtradeb/apps"
    fi
  else
    echo "[nosnap] ppa:xtradeb/apps does not support ${xtradeb_codename} or the network is unavailable; skipping"
  fi
else
  echo "[nosnap] Unable to detect the Ubuntu codename; skipping ppa:xtradeb/apps"
fi

echo "[nosnap] Done"
