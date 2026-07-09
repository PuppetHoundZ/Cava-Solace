# Cava Solace — Therapeutic Sonic Visualizer

A self-contained manager script that builds [`cava`](https://github.com/karlstav/cava) from source and installs **Cava Solace**, a GTK3 touch GUI for Cava that generates science-based calming colour palettes and launches the visualizer — designed for Raspberry Pi OS.

Cava Solace pairs naturally with [AirPlay Solace](https://github.com/PuppetHoundZ/shairport-solace) — both fit side-by-side on an 800×480 touchscreen simultaneously.

---

## 🛠️ Features

* **Zero External Assets:** The single script generates everything it needs — the Python GUI, an SVG icon, desktop shortcut, and an isolated lxterminal profile for cava launches.
* **Therapeutic Palette Generator:** Randomizes 8-stop HSL colour gradients using peer-reviewed calming colour research (Manchester Color Wheel). Controls vibrancy (muted / balanced / vivid), bar geometry, smoothness, and mirror symmetry.
* **RAM-First Config:** All palette writes go to `/dev/shm` during a session — the SD card is only written once when the GUI closes. Zero wear during use.
* **Live Reload:** Applies palette changes to a running cava instance instantly via `SIGUSR1` — no restart needed.
* **Save / Load Palettes:** Plain-text `.cava` files in the community catppuccin/cava format — shareable and hand-editable.
* **Isolated Terminal Profile:** Launches cava via a dedicated `lxterminal --profile=cava-solace` profile that hides the menu bar and scrollbar without touching the user's default lxterminal settings.
* **Touch-Friendly UI:** Solace dark theme, 44px minimum touch targets, optimized for 800×480 touchscreen displays.
* **Fault-Tolerant Installer:** Rollback/crash recovery via state files — auto-restores previous state on power loss or interrupted install.
* **Safe Uninstall:** Removes all installed files cleanly; build dependencies are retained to avoid breaking other Pi OS packages.

---

## 📂 Key Path Architecture

| Asset Type | File Path |
| :--- | :--- |
| **cava binary** | `~/.local/bin/cava` |
| **Cava Solace GUI** | `~/.local/bin/cava-solace` |
| **Desktop Launcher** | `~/.local/share/applications/cava-solace.desktop` |
| **Scalable Vector Icon** | `~/.local/share/icons/hicolor/scalable/apps/cava-solace.svg` |
| **cava config** | `~/.config/cava/config` |
| **lxterminal profile** | `~/.config/lxterminal/lxterminal-cava-solace.conf` |
| **Rollback State Dir** | `~/.local/share/cava-manager/` |

---

## 📋 Requirements

* **OS:** Raspberry Pi OS Trixie (Debian 13) arm64
* **Audio:** PipeWire (default on Trixie — never replaced or disabled by this script)
* **Network:** Internet connection required for initial source build
* **Storage:** ~50 MB free disk space

The manager automatically checks and installs missing build dependencies (`autoconf`, `automake`, `libtool`, `libfftw3-dev`, `libpipewire-0.3-dev`, and others). All are retained on uninstall.

---

## 🚀 Installation & Usage

1. Download or copy the manager script to your system.
2. Make it executable:
   ```bash
   chmod +x cava-manager.sh
   ```
3. Run it as your **normal user** (do **NOT** use `sudo` or run as root):
   ```bash
   ./cava-manager.sh
   ```

### Terminal Menu Options

| Option | Action |
| :--- | :--- |
| **1** | Install cava (builds from source) |
| **2** | Update cava (rebuilds from latest source) |
| **3** | Open Cava Solace (therapeutic GUI) |
| **4** | Check / fix terminal colour support |
| **5** | Edit cava config manually |
| **6** | Uninstall cava |
| **7** | Exit |

---

## 🎨 Therapeutic Palette Generator

The randomizer generates palettes grounded in peer-reviewed calming colour research:

* **Vibrancy modes:** Muted (wide bars, low saturation) / Balanced / Vivid (narrow bars, zero spacing)
* **Smoothness:** `noise_reduction` randomized 60–95
* **Waveform:** Auto-selected based on palette lightness — oscilloscope for bright palettes, spectrum for dark
* **Mirror symmetry:** 30% probability reverse enabled
* **Gradient inversion:** 30% probability

All values are written as real cava config keys — not GUI-only state.

---

## 🔗 Cross-App Integration

Cava Solace integrates with **AirPlay Solace** ([shairport-solace](https://github.com/PuppetHoundZ/shairport-solace)):

* AirPlay Solace detects Cava Solace via `~/.local/share/applications/cava-solace.desktop`
* Launches it via `~/.local/bin/cava-solace`
* Both GUIs fit side-by-side on an 800×480 touchscreen — confirmed on real hardware

---

## References

* [cava source](https://github.com/karlstav/cava)
* [cava config reference](https://github.com/karlstav/cava/blob/master/example_files/config)
* [PipeWire](https://pipewire.org)
* [Raspberry Pi OS documentation](https://www.raspberrypi.com/documentation/)

## Disclaimer

Provided as-is, free of charge, for Raspberry Pi users. Not affiliated with the cava project or Raspberry Pi Ltd. Use at your own risk.
