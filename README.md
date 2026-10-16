# Droidspaces RootFS Builder — GNOME fork

Build ARM64 Linux RootFS images for **Droidspaces** on Android with GitHub Actions.
This fork is set up to produce **GNOME desktop** images on **Debian 13** and **Ubuntu 26.04**,
running on the **Anland Wayland** backend with Snapdragon GPU acceleration.

![Debian 13 KDE running with Anland Wayland](docs/images/debian-kde-wayland.jpg)

**Quick start:** open `Actions` → run **Build and Release Droidspaces RootFS** →
leave the defaults → download the RootFS from `Releases`.

## Defaults in this fork

| Input | Default | Meaning |
| --- | --- | --- |
| `build_target` | `gnome-debian-ubuntu` | Builds **both** `Debian-13` and `Ubuntu-26` in one run |
| `desktop` | `GNOME` | GNOME desktop |
| `display_backend` | `anland-wayland` | Hardware-accelerated Wayland via Anland |
| `enable_mesa` | `true` | Snapdragon / Adreno GPU driver support |
| `enable_yj` | `true` | NAT and Android hardware recognition |
| `nosnap` | `true` | Removes Snap from Ubuntu images |
| `enable_zip` | `true` | Compression tools |
| `enable_zh_tz` | `false` | English locale, no timezone change |

Pressing **Run workflow** with the defaults produces two `.tar.xz` archives:

- `Debian-13-GNOME-rootfs` — GNOME 48 (mutter 48.7)
- `Ubuntu-26-GNOME-rootfs` — GNOME 50 (mutter 50.1)

## What it provides

- **GNOME on Anland Wayland**, hardware accelerated through the Snapdragon GPU.
- **Droidspaces goodies** kept intact: Termux:X11 support, Adreno Mesa drivers,
  PulseAudio/PipeWire audio, USB Manager, firmware downloader, Docker, binfmt,
  ARM64 Chrome, and the in-container TUI.
- Automatic GitHub Release publishing with a draft-then-publish flow.
- Desktop session auto-start via `desktop-session.service`.

## GNOME support matrix

GNOME requires the Anland Wayland backend (GNOME 49 and later dropped the X11 session
upstream). The prebuilt Anland Mutter packages exist for these targets only:

| Target | GNOME | Notes |
| --- | --- | --- |
| `Debian-13` | ✅ | GNOME 48 / mutter 48.7 |
| `Ubuntu-26` | ✅ | GNOME 50 / mutter 50.1 |
| `Arch` | ✅ | GNOME 50 / mutter 50.5 |
| `Fedora-43`, `Fedora-44` | ❌ | No Fedora Mutter build published; KDE and Anland Next work |
| `Ubuntu-24`, `Ubuntu-25` | ❌ | X11 only, no Anland backend |

## Documentation

- [Documentation index and desktop screenshots](docs/en/README.md)
- [Build with Actions and import into Droidspaces](docs/en/quick-start.md)
- [Supported distributions and build options](docs/en/build-options.md)
- [Desktop startup and Anland Wayland setup](docs/en/desktop-and-anland.md)
- [TUI, USB, firmware, and local builds](docs/en/advanced-usage.md)
- [Script maintenance guide](scripts/README.md)

## Acknowledgements

Forked from [Goldzxcbug/Droidspaces-rootfs-Desktop-builder](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder)
(MIT). All credit for the build system, desktop profiles and Anland packaging goes to the original author.

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/): runtime foundation.
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container): Snapdragon GPU driver support.
- [droidspaces-media-decode](https://github.com/Re-s/droidspaces-media-decode): Android MediaCodec hardware decoding for containers.
- [Anland](https://github.com/superturtlee/anland): Wayland display backend and related work.
- [Droidspaces USB Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager): USB storage and ADB device management.
- [ObsidianArc](https://github.com/OnyxAxisOwO/ObsidianArc): self-hosted multi-model chat gateway.

---

[All desktop screenshots](docs/en/README.md#screenshots)
