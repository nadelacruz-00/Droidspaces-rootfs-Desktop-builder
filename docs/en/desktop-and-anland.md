[Documentation index](README.md) · [Project home](../../README.md)

# Desktop Startup and Anland Wayland

## Desktop auto-start

When `desktop_autostart` is enabled, the RootFS installs `desktop-session.service`. It runs the session as UID 1000 and reads `/etc/droidspaces-desktop.conf` to select the desktop.

| Desktop and backend | Manual command |
| --- | --- |
| KDE + X11 | `DISPLAY=:5 startplasma-x11` |
| KDE + Anland Wayland | `startplasma-wayland` |
| KDE Mobile + Anland Wayland | `startplasmamobile` |
| GNOME + Anland Wayland | `gnome-session --session=gnome` |
| Anland Next | `/usr/bin/anland-session` |
| Niri | `/usr/bin/niri-anland` |

After an unexpected exit, systemd retries after 2 seconds. More than 5 failures within 60 seconds pauses retries. A normal exit does not restart the session.

### X11

X11 uses `DISPLAY=:5`; install and start Termux:X11 on Android. If auto-start is disabled, run this in the container:

```bash
startplasma-x11
```

### Anland Wayland host setup

Anland Wayland supports Debian 13, Ubuntu 26, Fedora 43/44, and Arch. KDE uses patched KWin/Xwayland; GNOME uses patched Mutter. GNOME packages for Debian, Ubuntu, and Arch are published by [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) and installed from its Release during RootFS creation. The Arch Niri session uses `niri-anland` and the patched Xwayland from the same Release, with `xdg-desktop-portal-gtk` and Alacritty for portals and a terminal.

The Niri profile writes the session and Anland/Mesa environment to `/etc/environment`, like the other desktop profiles. The shared desktop launcher runs `/usr/bin/niri-anland` directly without `--session`.

Prepare the Android device:

1. Install the Anland host APK `anland-v5.apk` from [Anland Releases](https://github.com/SuperTurtleDev/anland/releases/latest). On Droidspaces the APK is all you need — do **not** install the separate `anland-daemon` module, because Droidspaces starts its own daemon for every container with Anland enabled.
2. Use a Droidspaces build that includes the per-container **Anland Display** switch.
3. Enable **GPU Access** in the container settings, and **Hardware Access** too if your device or RootFS explicitly needs full hardware mapping.
4. Enable **Anland Display**. This is the switch that starts the built-in per-container daemon.
5. **Disable** Configure Termux:X11. Anland and Termux:X11 use separate display paths, and configuring both can cause environment-variable or service conflicts.
6. Keep **Configure PulseAudio** disabled. The Anland producer reaches Anland's audio path through PipeWire, so Droidspaces does not need to configure PulseAudio separately. If the container previously used PulseAudio, remove the existing `PULSE_SERVER` variable as well.
7. Keep SELinux **enforcing**. Droidspaces' Anland integration ships the required policy; only switch to permissive after confirming that an AVC denial is actually Anland-related.
8. Set `nocaps` / `noseccomp` according to what your RootFS and Droidspaces version require.

Do **not** add a manual bind mount for `/data/local/tmp/display_daemon.sock`. That mapping belongs to the chroot method. Droidspaces creates a separate socket per container (for example `anland-<UUID>.sock`) and automatically bind-mounts it at `/run/display.sock` inside the container.

Start the container, then confirm the socket and the GPU node exist inside it:

```sh
test -S /run/display.sock
test -e /dev/dri/renderD128
```

Log in as the normal user. For KDE run `startplasma-wayland`; KDE Mobile uses `startplasmamobile`; GNOME uses `gnome-session --session=gnome`. Then, on the Android side, use Droidspaces' **Launch Anland** action on the running-container card or details page — not the Anland launcher icon, which uses the global default socket rather than the container's.

### Install or update Anland desktop packages

The build fetches matching packages automatically. To install them separately in a running ARM64 RootFS, run from the repository root:

```bash
sudo ./scripts/tui/install-anland-kde.sh
```

The GNOME installer runs on Debian 13, Ubuntu 26, and Arch Linux ARM:

```bash
sudo ./scripts/tui/install-anland-gnome.sh
```

The in-container installer supports Arch pacman packages and reads the Arch target from the `anland-gnome-packages` Release manifest.

See the [script guide](../../scripts/README.md#anland-kde-installer) for installer options, download sources, and verification.
