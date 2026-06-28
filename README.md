Cava Solace — Therapeutic Sonic Visualizer — Manager Script
Status: confirmed on real Pi OS touchscreen,
side-by-side with AirPlay Solace with room to spare

Self-contained — generates all required files on Install:
• cava-solace  (GTK3 Python GUI)       → ~/.local/bin/cava-solace
• Desktop shortcut + SVG icon          → ~/.local/share/

No companion files required. Distribute and run this single script.

cava — Cross-platform Audio Visualizer
Source: [https://github.com/karlstav/cava](https://github.com/karlstav/cava)

Features:
• Builds cava from source (autotools — fast compile on Pi 4)
• Installs to ~/.local/bin (fully userland, no root beyond apt)
• Installs Cava Solace GUI — therapeutic palette generator + visualizer launcher
• Uninstall cleanly removes all installed files
• Rollback on failure — restores previous state on error or power loss

Requirements:

* Raspberry Pi OS Trixie (Debian 13) arm64
* PipeWire audio (default on Trixie)
* Internet connection for initial build
* ~50 MB free disk space

Usage:
chmod +x cava-manager.sh
./cava-manager.sh

Do NOT run as root.

Disclaimer:
Provided as-is, free of charge, for Raspberry Pi users. Not affiliated
with the cava project or Raspberry Pi Ltd. Use at your own risk.
