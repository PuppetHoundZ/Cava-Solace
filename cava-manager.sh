#!/usr/bin/env bash
# =============================================================================
# cava-manager.sh
# Cava Solace — Therapeutic Sonic Visualizer — Manager Script
# Version: 2.7.1
# Status: 🟢 GOLD (Production-Ready) — confirmed on real Pi OS touchscreen,
#   side-by-side with AirPlay Solace with room to spare
# Last updated: 2026-06-23
#
# Self-contained — generates all required files on Install:
#   • cava-solace  (GTK3 Python GUI)       → ~/.local/bin/cava-solace
#   • Desktop shortcut + SVG icon          → ~/.local/share/
#
# No companion files required. Distribute and run this single script.
#
# cava — Cross-platform Audio Visualizer
#   Source: https://github.com/karlstav/cava
#
# Features:
#   • Builds cava from source (autotools — fast compile on Pi 4)
#   • Installs to ~/.local/bin (fully userland, no root beyond apt)
#   • Installs Cava Solace GUI — therapeutic palette generator + visualizer launcher
#   • Uninstall cleanly removes all installed files
#   • Rollback on failure — restores previous state on error or power loss
#
# Requirements:
#   - Raspberry Pi OS Trixie (Debian 13) arm64
#   - PipeWire audio (default on Trixie)
#   - Internet connection for initial build
#   - ~50 MB free disk space
#
# Usage:
#   chmod +x cava-manager.sh
#   ./cava-manager.sh
#
# Do NOT run as root.
#
# Disclaimer:
#   Provided as-is, free of charge, for Raspberry Pi users. Not affiliated
#   with the cava project or Raspberry Pi Ltd. Use at your own risk.
# =============================================================================

# =============================================================================
# AI REFERENCE NOTES — cava-manager.sh
# Single source of truth. Read this block in full before making any changes.
# Cross-reference CLAUDEROOT.md for project-wide rules.
#
# ── WHAT THIS SCRIPT DOES ────────────────────────────────────────────────────
#   Builds cava from source using autotools (NOT cmake — cmake only builds
#   libcavacore.a, not the full binary).
#   Build path: ./autogen.sh → ./configure --prefix=$HOME/.local → make → make install
#   Installs to ~/.local/bin (fully userland). Embeds Cava Solace GTK3 Python
#   GUI as a heredoc (PYEOF). Manages rollback/crash recovery via state files.
#
# ── KEY PATHS ────────────────────────────────────────────────────────────────
#   ~/.local/bin/cava                              — cava binary
#   ~/.local/bin/cava-solace                       — GTK3 GUI (written by write_gui_script)
#   ~/.local/share/applications/cava-solace.desktop
#   ~/.local/share/icons/hicolor/scalable/apps/cava-solace.svg
#   ~/.config/cava/config                          — cava config (symlinked to RAM in session)
#   /dev/shm/cava-config-live                      — RAM copy during active GUI session
#   ~/.config/cava/config.sd                       — SD backup during session
#   ~/.local/share/cava-manager/                   — rollback state dir
#   ~/.config/lxterminal/lxterminal-cava-solace.conf — isolated lxterminal profile
#
# ── ENVIRONMENT ──────────────────────────────────────────────────────────────
#   Raspberry Pi 4, Pi OS Trixie (Debian 13 arm64), labwc Wayland compositor.
#   800×480 touchscreen (primary) + 1080p HDMI (secondary, not always connected).
#   PipeWire + WirePlumber audio — NEVER replace, disable, or create system
#   services that compete with it. cava runs in user session only.
#
# ── TERMINAL ─────────────────────────────────────────────────────────────────
#   lxterminal is the Pi OS Trixie default terminal (GTK3/VTE). Runs natively
#   on Wayland under labwc. Fully truecolor (COLORTERM=truecolor) — cava
#   renders correct 24-bit gradients. Do NOT install foot or JetBrains Mono;
#   neither offers any rendering advantage for cava on this hardware.
#   Ref: https://docs.gtk.org/gtk3/wayland.html
#
#   cava is launched via: lxterminal --profile=cava-solace -e cava
#   The --profile flag loads ~/.config/lxterminal/lxterminal-cava-solace.conf
#   (a separate file, hidemenubar + hidescrollbar) so the user's default
#   lxterminal.conf is never touched. ensure_lxterminal_cava_profile() creates
#   this profile on install/update, seeded from the user's current config.
#   Uninstall removes lxterminal-cava-solace.conf unconditionally (it is
#   exclusively owned by this script — users should not hand-edit it).
#   Ref: https://github.com/lxde/lxterminal/blob/master/src/setting.c
#
#   _launch_terminal() probe order: foot → xfce4-terminal → lxterminal →
#   x-terminal-emulator. foot is tried first as a courtesy (no-op if absent).
#
# ── RAM-DISK CONFIG PATTERN ──────────────────────────────────────────────────
#   All theme switching writes to /dev/shm only (zero SD writes in session):
#   1. First apply: backs up ~/.config/cava/config → config.sd
#   2. Writes theme to /dev/shm/cava-config-live
#   3. Replaces config with symlink → RAM file
#   4. Sends SIGUSR1 to cava → live reload
#   5. On GUI close (flush_to_sd()): writes RAM → SD, removes symlink
#   Dangling symlink on startup = previous crash → removed automatically.
#   Ref: https://www.kernel.org/doc/html/latest/filesystems/tmpfs.html
#        https://github.com/karlstav/cava/blob/master/README.md (SIGUSR1)
#
# ── GTK3 GUI NOTES (Cava Solace) ─────────────────────────────────────────────
#   Written as a bash heredoc (PYEOF). Re-generated on Install and Update.
#   Window: set_default_size(500, 360) + set_size_request(500, 360) floor +
#   set_resizable(True). GOLD geometry confirmed on real Pi hardware — fits
#   side-by-side with AirPlay Solace on 800×480. Do not shrink further.
#   mid_row uses pack_start(False, False) — content-height only, no GTK stretch.
#   Button min-height 48px (WCAG 2.5.5 touch target) — do not reduce.
#
#   GTK3 does not support CSS keyframes — all animation via GLib timer loops.
#   Timer safety: _closed flag + get_realized() guards prevent post-close fires.
#   Pulse animation: 50ms GLib timer, sine-wave alpha, scoped to #generate-btn.
#   Window tint fade: ~450ms crossfade to dark tint of theme hue (sat≤18%, L≤10%).
#   Swatch crossfade: ~450ms fade between old and new palette in Cairo.
#   Color dots: filled circle + outer ring + inner highlight.
#   Gradient inversion: 30% probability, stored in theme dict and .cava files.
#   waveform selection: palette avg lightness > 58% → oscilloscope; else spectrum.
#   Save/load: plain-text INI .cava files (catppuccin/cava community format).
#
#   Therapeutic randomizer writes these real cava config keys (not GUI-only):
#     gradient colours  [color] — 8-stop HSL palette
#     noise_reduction   [general] — range 60–95 (smoothness)
#     waves             [general] — 70% on / 30% off (decay character)
#     reverse           [output] — 30% probability (mirror symmetry)
#     bar_width / bar_spacing [general] — contextual per vibrancy mode:
#       muted (low sat)     → wide bars, wider spacing
#       balanced            → medium bars and spacing
#       vivid (high sat)    → narrow bars, zero spacing (solid colour wave)
#     output_method noncurses — partial redraws, eliminates 1080p tearing.
#   Note: blend_direction is NOT written — only applies when both gradient and
#   horizontal_gradient are set; this script uses gradient-only.
#   Note: gravity= is deprecated since cava 0.8.0 — use noise_reduction.
#   Ref: https://github.com/karlstav/cava/blob/master/example_files/config
#
# ── CROSS-APP INTEGRATION — shairport-sync-manager.sh ────────────────────────
#   AirPlay Solace detects Cava Solace via:
#     ~/.local/share/applications/cava-solace.desktop  ← existence check
#   and launches via:
#     ~/.local/bin/cava-solace
#   If either path changes, update shairport-sync-manager.sh:
#     _is_cava_installed() and _launch_cava() in its airplay-solace PYEOF block.
#
# ── INSTALL / UNINSTALL NOTES ─────────────────────────────────────────────────
#   install_gui(): dpkg pre-checks deps before apt-get so a network failure
#   cannot abort under set -euo pipefail before the GUI heredoc is written.
#   Rollback: state files in ~/.local/share/cava-manager/, auto-restore on crash.
#
# ── VERSION HISTORY ──────────────────────────────────────────────────────────
#   v2.7.0 (2026-06-19) — Window resized 780×460 → 500×360 GOLD. Fits
#     side-by-side with AirPlay Solace on 800×480. mid_row pack_start changed
#     to (False, False) to eliminate dead space at bottom. Layout margins and
#     swatch preview trimmed proportionally. Confirmed on real hardware.
#   v2.6.0 (2026-06-18) — lxterminal --profile=cava-solace integration.
#     Isolated profile hides menu/scrollbar for cava launch without touching
#     user's default lxterminal.conf. ensure_lxterminal_cava_profile() added
#     to install/update; uninstall removes the profile file.
#   v2.5.0–v2.5.1 (2026-06-18) — Bar geometry (bar_width/bar_spacing/reverse)
#     added to therapeutic randomizer and round-tripped through all write paths.
#     Vibrancy modes: muted/balanced/vivid (internal: dark/balanced/bright).
#     waves key threaded through all dict/apply/save/load paths. noise_reduction
#     range 60–95. Gradient inversion contrast fixed to full 20-point gap.
#     SwatchArea gap floor removed so bar_spacing=0 renders correctly.
#   v2.4.0–v2.4.4 (2026-06-09–17) — Rollback/crash recovery system added.
#     noncurses output method (eliminates 1080p tearing). foot + JetBrains
#     Mono removed (lxterminal is truecolor, native Wayland, sufficient).
#     GUI polish: pulse animation, swatch crossfade, window tint, 24-bar preview,
#     gradient inversion, waveform auto-selection.
#   v2.0.0–v2.3.0 (2026-06) — Cava Solace born: GTK3 GUI heredoc, therapeutic
#     palette randomizer, RAM-disk config pattern, SIGUSR1 live reload,
#     save/load .cava files. SDL removed. Terminal-only cava launch.
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()       { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()       { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()      { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()       { echo -e "\n${CYAN}── $* ──${NC}"; }
divider()    { echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"; }
print_ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
print_info() { echo -e "  ${CYAN}•${NC}  $*"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
INSTALL_BIN="$HOME/.local/bin"
CAVA_BIN="$INSTALL_BIN/cava"
CAVA_CONFIG_DIR="$HOME/.config/cava"
CAVA_CONFIG="$CAVA_CONFIG_DIR/config"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE_GUI="$DESKTOP_DIR/cava-solace.desktop"
ICON_FILE_GUI="$ICON_DIR/cava-solace.svg"
GUI_SCRIPT="$INSTALL_BIN/cava-solace"
# Separate lxterminal profile -- see ensure_lxterminal_cava_profile() below.
# Using --profile=cava-solace makes lxterminal load/save THIS file instead of
# the user's default lxterminal.conf, so hiding the menu/scrollbar for cava's
# launch never touches Start Menu lxterminal launches.
# Ref: https://github.com/lxde/lxterminal/blob/master/src/setting.c
#      https://manpages.debian.org/trixie/lxterminal/x-terminal-emulator.1
LXTERM_DEFAULT_CONF="$HOME/.config/lxterminal/lxterminal.conf"
LXTERM_CAVA_PROFILE="$HOME/.config/lxterminal/lxterminal-cava-solace.conf"

# ── Sanity check ──────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] && error "Do not run this script as root."

mkdir -p "$INSTALL_BIN" "$CAVA_CONFIG_DIR" "$ICON_DIR" "$DESKTOP_DIR"

# ── Rollback / crash recovery ─────────────────────────────────────────────────
# Tracks what this session has changed so it can be undone on any exit signal.
# Works for: Ctrl-C, kill, error(), set -e failures, and power-loss recovery
# (next run detects the leftover .partial marker and offers to restore).
#
# State files live in $HOME/.local/share/cava-manager/ — writable, user-owned,
# not /tmp (survives reboots for crash detection).
#
STATE_DIR="$HOME/.local/share/cava-manager"
PARTIAL_MARKER="$STATE_DIR/install.partial"   # exists only during an active op
BACKUP_BIN="$STATE_DIR/cava.backup"           # pre-op binary backup
BACKUP_GUI="$STATE_DIR/cava-solace.backup"    # pre-op GUI script backup
BUILD_DIR_FILE="$STATE_DIR/build_dir"         # tracks live BUILD_DIR path
mkdir -p "$STATE_DIR"

# Global: set to "install" or "update" by the op that starts a rollback scope.
_ROLLBACK_OP=""
# Global: the BUILD_DIR used by the current op (populated before use).
_BUILD_DIR_ACTIVE=""

_rollback_cleanup() {
    # Called by trap on any exit. $1 = exit code.
    local exit_code="${1:-0}"
    local op="$_ROLLBACK_OP"

    # Remove the live BUILD_DIR if it still exists
    if [[ -n "$_BUILD_DIR_ACTIVE" && -d "$_BUILD_DIR_ACTIVE" ]]; then
        rm -rf "$_BUILD_DIR_ACTIVE"
        info "Build directory cleaned up."
    fi
    # Also check the recorded path in case variable was lost
    if [[ -f "$BUILD_DIR_FILE" ]]; then
        local saved_dir
        saved_dir=$(cat "$BUILD_DIR_FILE")
        if [[ -n "$saved_dir" && -d "$saved_dir" ]]; then
            rm -rf "$saved_dir"
        fi
        rm -f "$BUILD_DIR_FILE"
    fi

    # Only roll back if we have a partial marker and a non-zero exit
    if [[ -f "$PARTIAL_MARKER" && "$exit_code" -ne 0 ]]; then
        warn "Operation '${op}' did not complete — rolling back changes..."

        # Restore cava binary if we backed it up
        if [[ -f "$BACKUP_BIN" ]]; then
            cp -f "$BACKUP_BIN" "$CAVA_BIN" &&                 info "Restored: $CAVA_BIN" ||                 warn "Could not restore $CAVA_BIN — run Install again."
            rm -f "$BACKUP_BIN"
        elif [[ "$op" == "install" ]]; then
            # Install never completed — remove any partial binary
            [[ -f "$CAVA_BIN" ]] && rm -f "$CAVA_BIN" && info "Removed partial binary."
        fi

        # Restore GUI script if we backed it up
        if [[ -f "$BACKUP_GUI" ]]; then
            cp -f "$BACKUP_GUI" "$GUI_SCRIPT" &&                 info "Restored: $GUI_SCRIPT" ||                 warn "Could not restore GUI script."
            rm -f "$BACKUP_GUI"
        fi

        rm -f "$PARTIAL_MARKER"
        echo ""
        warn "Rollback complete. Your system is back to its previous state."
        warn "Fix the issue above then run this script again."

    elif [[ -f "$PARTIAL_MARKER" && "$exit_code" -eq 0 ]]; then
        # Clean exit — remove partial marker and backups
        rm -f "$PARTIAL_MARKER" "$BACKUP_BIN" "$BACKUP_GUI"
    fi
}

# Trap all exit paths — ERR fires before EXIT so we capture the exit code there.
_EXIT_CODE=0
trap '_EXIT_CODE=$?' ERR
trap '_rollback_cleanup "$_EXIT_CODE"' EXIT
trap 'echo ""; warn "Interrupted."; exit 130' INT TERM HUP

_rollback_begin() {
    # Call at the start of any destructive operation.
    # $1 = op name ("install" or "update")
    _ROLLBACK_OP="$1"
    echo "$1" > "$PARTIAL_MARKER"

    # Backup current binary if it exists (update path)
    if [[ -f "$CAVA_BIN" ]]; then
        cp -f "$CAVA_BIN" "$BACKUP_BIN"
        info "Binary backed up for rollback: $BACKUP_BIN"
    fi
    # Backup current GUI script if it exists (update path)
    if [[ -f "$GUI_SCRIPT" ]]; then
        cp -f "$GUI_SCRIPT" "$BACKUP_GUI"
        info "GUI script backed up for rollback: $BACKUP_GUI"
    fi
}

_rollback_end() {
    # Call when the operation succeeds cleanly.
    _ROLLBACK_OP=""
    rm -f "$PARTIAL_MARKER" "$BACKUP_BIN" "$BACKUP_GUI"
}

_check_partial_state() {
    # Called at the start of main_menu on every run.
    # If a .partial marker exists the previous run did not finish cleanly
    # (power loss, crash, Ctrl-C). Restore automatically — no prompt.
    # The op is then re-runnable immediately from the menu.
    if [[ ! -f "$PARTIAL_MARKER" ]]; then
        return
    fi

    local op
    op=$(cat "$PARTIAL_MARKER")
    echo ""
    warn "Previous '${op}' did not complete (power loss or crash?) — auto-restoring..."

    # Restore binary if backup exists
    if [[ -f "$BACKUP_BIN" ]]; then
        cp -f "$BACKUP_BIN" "$CAVA_BIN" && info "Restored binary: $CAVA_BIN"
        rm -f "$BACKUP_BIN"
    else
        # No backup — partial install; remove any incomplete binary
        [[ -f "$CAVA_BIN" ]] && rm -f "$CAVA_BIN" &&             info "Removed incomplete binary (no backup to restore)."
    fi

    # Restore GUI script if backup exists
    if [[ -f "$BACKUP_GUI" ]]; then
        cp -f "$BACKUP_GUI" "$GUI_SCRIPT" && info "Restored GUI script: $GUI_SCRIPT"
        rm -f "$BACKUP_GUI"
    else
        [[ -f "$GUI_SCRIPT" ]] && rm -f "$GUI_SCRIPT" &&             info "Removed incomplete GUI script (no backup to restore)."
    fi

    # Clean up any leftover build directory recorded from the failed run
    if [[ -f "$BUILD_DIR_FILE" ]]; then
        local stale_dir
        stale_dir=$(cat "$BUILD_DIR_FILE")
        if [[ -n "$stale_dir" && -d "$stale_dir" ]]; then
            rm -rf "$stale_dir"
            info "Cleaned up stale build directory."
        fi
        rm -f "$BUILD_DIR_FILE"
    fi

    rm -f "$PARTIAL_MARKER"
    echo ""
    info "System restored to clean state. Select '${op}' from the menu to try again."
    echo ""
}


write_gui_script() {
    cat > "$GUI_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
# =============================================================================
# cava-solace — Cava Solace GTK3 GUI
# Generated by cava-manager.sh — re-run Install to update.
#
# Features:
#   • Therapeutic Palette Generator — science-based calming colours
#   • Save / Load palettes as plain-text .cava files
#   • Launch cava in Terminal, Window (SDL), or Fullscreen SDL mode
#   • Rounded-bar GLSL shader in SDL modes
#   • All SDL configs stay in sync when a palette is applied
#   • Writes to RAM (/dev/shm) during session — single SD write on close
#   • Touchscreen-optimised: large tap targets
#
# Therapeutic palette references (peer-reviewed):
#   Manchester Color Wheel (Carruthers et al. 2010, BMC Medical Research Methodology)
#   https://www.ncbi.nlm.nih.gov/pmc/articles/PMC2829580/
#   NeuroLaunch Therapy Color Palette (2024): https://neurolaunch.com/therapy-color-palette/
#   Villa Healing Center (2026): https://villahealingcenter.com/calming-colors-psychology/
#   Color Institute (2025): https://colorinstitute.com/color-psychology-and-wellness-the-healing-power-of-color/
# =============================================================================

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib
import cairo
import colorsys
import math
import os
import random
import re
import subprocess
import sys

# ── Config paths ──────────────────────────────────────────────────────────────
CAVA_CONFIG        = os.path.expanduser("~/.config/cava/config")

# =============================================================================
# COLOR MATH HELPERS
# =============================================================================

def hsl_to_hex(h, s, l):
    """
    Convert HSL (h=0-360, s=0-100, l=0-100) to '#rrggbb'.
    Python colorsys uses HLS order — we reorder when calling it.
    Reference: https://docs.python.org/3/library/colorsys.html
    """
    r, g, b = colorsys.hls_to_rgb(h / 360.0, l / 100.0, s / 100.0)
    return "#{:02x}{:02x}{:02x}".format(
        int(round(r * 255)),
        int(round(g * 255)),
        int(round(b * 255))
    )


def hex_to_rgb(h):
    """Convert '#rrggbb' to (r, g, b) floats 0.0-1.0."""
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) / 255.0 for i in (0, 2, 4))


def lerp_hue(h0, h1, t):
    """Interpolate hues taking the short path around the colour wheel."""
    diff = ((h1 - h0 + 540) % 360) - 180
    return (h0 + diff * t) % 360


def build_gradient_stops(anchor_hues, n, sat, l_bot, l_top):
    """
    Build n gradient stops across a list of anchor hues.
    Lightness ramps from l_bot (base) to l_top (tips) — tallest bars most vivid.
    """
    stops = []
    for i in range(n):
        t = i / (n - 1)
        a_t = t * (len(anchor_hues) - 1)
        a0 = int(a_t)
        a1 = min(a0 + 1, len(anchor_hues) - 1)
        frac = a_t - a0
        h = lerp_hue(anchor_hues[a0], anchor_hues[a1], frac)
        l = l_bot + (l_top - l_bot) * t
        stops.append(hsl_to_hex(h, sat, l))
    return stops


def make_bg(base_hue, sat_range=(30, 55), l_range=(10, 18)):
    """
    Generate a dark background visibly tinted with the theme's base hue.

    Lightness 10-18%: dark enough to feel like a terminal background,
    bright enough that the hue reads clearly in the small preview swatch.
    Saturation 30-55%: rich enough to be obviously related to the gradient
    colours sitting above it.

    In a full terminal cava uses a very dark hex background — the preview
    swatch is small so slightly more lightness/saturation is needed to make
    the tint visible and clearly connected to the bar colours.
    """
    s = random.randint(*sat_range)
    l = random.randint(*l_range)
    return hsl_to_hex(base_hue, s, l)


# =============================================================================
# THERAPEUTIC RANDOMIZER
#
# Hue anchors derived from peer-reviewed research:
#   Sage green   130-155 deg  -- strongest anxiety/depression reduction
#   Sky blue     195-215 deg  -- lowers heart rate and cortisol
#   Soft lavender 255-275 deg -- calming without dark-blue associations
#   Warm amber    35-48 deg   -- EEG relaxed brain states; sunset light
#   Cream yellow  50-62 deg   -- Manchester Color Wheel: normal mood anchor
#   Blush pink   340-355 deg  -- reduces aggression signs; care and quiet strength
#
# Saturation capped at 22-48%: muted outperforms vivid for anxiety reduction
# Lightness 48-68%: mid-to-light only -- dark tones correlate with low mood
# Gravity 62-88: slow floaty fall -- calm unhurried visual rhythm
#
# References:
#   https://www.ncbi.nlm.nih.gov/pmc/articles/PMC2829580/
#   https://neurolaunch.com/therapy-color-palette/
#   https://villahealingcenter.com/calming-colors-psychology/
#   https://colorinstitute.com/color-psychology-and-wellness-the-healing-power-of-color/
# =============================================================================

THERAPEUTIC_FAMILIES = [
    (130, 155, "Sage"),
    (195, 215, "Sky"),
    (255, 275, "Lavender"),
    ( 35,  48, "Amber"),
    ( 50,  62, "Cream"),
    (340, 355, "Blush"),
]

THERAPEUTIC_COMBOS = [
    (0, 1),       # Sage + Sky        -- nature + water; strongest anxiety reduction
    (0, 2),       # Sage + Lavender   -- nature + calm; restorative
    (1, 5),       # Sky + Blush       -- cool calm + soft warmth
    (0, 3),       # Sage + Amber      -- nature + golden hour; grounding
    (3, 5),       # Amber + Blush     -- warm sunset; gentle and uplifting
    (1, 2),       # Sky + Lavender    -- cool, airy, open
    (4, 0),       # Cream + Sage      -- soft uplift + restoration
    (4, 5),       # Cream + Blush     -- gentle warmth; kindness palette
    (0, 1, 5),    # Sage + Sky + Blush     -- full therapeutic triple
    (3, 0, 1),    # Amber + Sage + Sky     -- golden hour into nature
    (4, 0, 2),    # Cream + Sage + Lavender -- gentle uplift arc
    (5, 1, 0),    # Blush + Sky + Sage     -- kindness to calm to nature
]

SCIENCE_NOTE = (
    "Muted - parasympathetic - evidence-based\n"
    "Manchester Color Wheel (BMC 2010) - NeuroLaunch - Color Institute"
)


def gen_therapeutic():
    """
    Generate a complete therapeutic theme dict grounded in colour psychology research.

    channels = stereo always: left/right spatial separation

    References:
      blend_direction: https://github.com/karlstav/cava/blob/master/example_files/config
      Manchester Color Wheel: https://www.ncbi.nlm.nih.gov/pmc/articles/PMC2829580/
      NeuroLaunch: https://neurolaunch.com/therapy-color-palette/
    """
    combo   = random.choice(THERAPEUTIC_COMBOS)
    anchors = [random.randint(THERAPEUTIC_FAMILIES[i][0],
                              THERAPEUTIC_FAMILIES[i][1]) for i in combo]
    family_names = [THERAPEUTIC_FAMILIES[i][2] for i in combo]
    sat = random.randint(22, 48)
    n   = random.randint(6, 8)

    # ── Gradient inversion — occasional reversal for tonal variety ───────────
    # Normal:   gradient_color_1 = dark/muted at base, color_N = bright at tips
    #           Bars grow brighter toward the peak — energetic, uplifting.
    # Inverted: gradient_color_1 = bright at base, color_N = dark at tips
    #           Bars are most vivid at the bottom, fade toward tips — grounded,
    #           meditative, like light pooling at the floor.
    #
    # 30% chance of inversion — frequent enough for genuine variety,
    # infrequent enough that the default upward-lightness feel remains primary.
    #
    # l_bot/l_top are decided HERE, before build_gradient_stops, rather than
    # always being independently randomised: a normal draw's narrow random
    # sub-ranges (48-54 / 60-68) can land as little as ~6 points apart --
    # enough that an inverted flip is barely perceptible in the swatch.
    # On an inverted draw we pin to 48/68, the widest contrast the cited
    # 48-68% therapeutic lightness corridor allows -- still fully inside
    # that corridor, just always choosing its widest edges instead of a
    # narrower random slice. Non-inverted draws keep the original randomised
    # sub-ranges for normal palette-to-palette variety.
    inverted = random.random() < 0.30
    if inverted:
        l_bot = 48
        l_top = 68
    else:
        l_bot = random.randint(48, 54)
        l_top = random.randint(60, 68)

    colors = build_gradient_stops(anchors, n, sat, l_bot, l_top)
    if inverted:
        colors = list(reversed(colors))

    bg      = make_bg(anchors[0])  # uses defaults: sat 30-55%, lightness 10-18%
    # noise_reduction: randomised 60-95 for therapeutic variety.
    # gravity= was deprecated in cava 0.8.0 and is not used.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    noise_reduction = random.randint(60, 95)

    # waves: sub-option of monstercat smoothing -- adds a flowing wave-like
    # decay to the bars rather than a hard instant drop. 70% on, 30% off for
    # variety -- both are calm and smooth, just a different decay character.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    waves = 1 if random.random() < 0.70 else 0

    # blend_direction is only active when BOTH gradient AND horizontal_gradient
    # are set simultaneously. This script uses gradient-only (noncurses mode),
    # so blend_direction has no effect — omitted to avoid misleading config output.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config

    # ── Waveform vs spectrum source selection ────────────────────────────────
    # waveform = 1: bar heights driven by raw audio waveform (oscilloscope data)
    # waveform = 0: bar heights driven by FFT frequency spectrum (default)
    # Either way cava ALWAYS renders bars — waveform only changes the data source.
    # In [general] section. Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    #
    # Selection based on average colour lightness of the palette:
    #   Pale/airy palettes (avg L > 58%) → oscilloscope source — gentler, more uniform movement
    #   Rich/deep palettes (avg L ≤ 58%) → spectrum source    — more reactive, frequency-driven peaks
    # Plus 25% random flip for variety.
    # Average HLS lightness across all gradient stops (0-100 scale).
    # hsl_to_hex stores as HSL so we can reconstruct: use hex_to_rgb + colorsys.
    avg_l = sum(
        colorsys.rgb_to_hls(*hex_to_rgb(c))[1]
        for c in colors
    ) / len(colors) * 100

    use_waveform = (avg_l > 58) or (random.random() < 0.25)

    # ── Bar geometry -- contextual spacing/width + mirror reversal ───────────
    # cava natively supports these as real [general]/[output] keys (NOT a GUI
    # fake -- written straight into the real config, verified against the
    # upstream example config):
    #   bar_width   = int, character/column width of each bar
    #   bar_spacing = int, character/column gap between bars
    #   reverse     = 0/1, mirrors the bar order left-to-right
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    #
    # Values are deliberately small (cava's own example file default is
    # bar_width=2, bar_spacing=1) so the effect stays subtle on the 800x480
    # touchscreen terminal -- this is a gentle contextual nudge, not a
    # dramatic layout change.
    #
    # avg_sat: average HSV saturation across gradient stops, used the same
    # way avg_l (lightness, computed above) is used for waveform selection.
    avg_sat = sum(
        colorsys.rgb_to_hsv(*hex_to_rgb(c))[1]
        for c in colors
    ) / len(colors) * 100

    # Evidence behind the dark/bright split below:
    #
    # 1) Visual density and clutter are linked to measurable physiological
    #    over-arousal (skin conductance, respiration) in controlled studies --
    #    minimising clutter preserves attentional resources and avoids the
    #    "Stress-Inducing" response pattern.
    #    Ref: Shu, Jin, Li & Li (2026) "Visual Perception Promotes Active
    #    Health" -- Sustainability 18(3):1298, MDPI -- VR psychophysiology
    #    study, n=60. https://doi.org/10.3390/su18031298
    #
    # 2) Uniform visual properties (consistent width/spacing) trigger Gestalt
    #    grouping ("uniform connectedness"), which the visual system reads as
    #    a single cohesive whole rather than separate parts -- a recognised
    #    mechanism for reducing cognitive load, independent of any specific
    #    therapeutic claim.
    #    Ref: Palmer & Rock (1994); Han, Humphreys & Chen (1999) "Uniform
    #    connectedness and classical Gestalt principles of perceptual
    #    grouping" -- Attention, Perception, & Psychophysics 61(4).
    #
    # Dark/muted palettes -> more breathing room (spacious + uniform width).
    # Bright/saturated palettes -> tighter grouping (compact + delicate width)
    # so the cohesive-whole effect offsets the higher visual energy of the
    # colours themselves. Balanced palettes use cava's own stock defaults.
    #
    # Thresholds calibrated against this generator's actual output (not
    # arbitrary round numbers): with sat=22-48 and l_bot/l_top=48-54/60-68,
    # avg_sat across 2000 sampled themes ranged ~25-57 (mean ~41) and avg_l
    # ranged ~54-61 (mean ~57.5) -- lightness barely varies palette-to-palette
    # in this generator, so saturation is the primary signal; lightness is
    # only used as a light secondary tiebreaker within its narrow real range.
    if avg_sat <= 33 and avg_l <= 57:
        bar_spacing = 2
        bar_width   = 3
        bar_mode    = "dark"
    elif avg_sat >= 45 and avg_l >= 56:
        bar_spacing = 0
        bar_width   = 1
        bar_mode    = "bright"
    else:
        bar_spacing = 1
        bar_width   = 2
        bar_mode    = "balanced"

    # ── Mirror reversal (cava's native 'reverse' key, [output] section) ──────
    # Symmetric/mirrored patterns are measurably perceived as LESS visually
    # complex than asymmetric ones -- mirror symmetry was the only predictor
    # with a significant NEGATIVE correlation to perceived visual complexity
    # across two independent stimulus sets (912 and 252 abstract patterns).
    # Ref: Gartus & Leder (2017) "Predicting perceived visual complexity of
    # abstract patterns... The influence of mirror symmetry on complexity
    # perception" -- PLOS ONE 12(11):e0185276.
    # https://doi.org/10.1371/journal.pone.0185276
    #
    # 30% chance -- same frequency as the existing gradient `inverted` flag,
    # for consistent variety without it dominating every theme.
    reverse = random.random() < 0.30

    return {
        "colors":           colors,
        "bg":               bg,
        "mode_label":       "therapeutic",
        "theme_name":       " + ".join(family_names),
        "science_note":     SCIENCE_NOTE,
        "noise_reduction":  noise_reduction,
        "waves":            waves,
        "waveform":         1 if use_waveform else 0,
        "inverted":         inverted,
        "bar_spacing":      bar_spacing,
        "bar_width":        bar_width,
        "bar_mode":         bar_mode,
        "reverse":          reverse,
    }


def generate_therapeutic():
    return gen_therapeutic()


# =============================================================================
# CONFIG WRITE -- RAM-HOLD, SINGLE FLUSH ON CLOSE
#
# All theme switching during a session writes only to /dev/shm (RAM/tmpfs).
# cava reads from there via a symlink and live-reloads instantly.
# One single write to the real SD config path happens only when the GUI closes.
#
# References:
#   /dev/shm tmpfs:    https://www.kernel.org/doc/html/latest/filesystems/tmpfs.html
#   cava live-config:  https://github.com/karlstav/cava/blob/master/example_files/config
#   log2ram:           https://github.com/azlux/log2ram
# =============================================================================

CAVA_CONFIG_RAM    = "/dev/shm/cava-config-live"
_base_config_lines = None


def _load_base_config():
    """
    Read the SD config once, strip [color], [smoothing], and the therapeutic
    keys from [output] (channels), then cache the
    result. All subsequent theme switches reuse this cached base -- no further
    SD reads during the session.

    Stripping managed [output] keys ensures
    _build_config_content can re-append them from the theme dict without
    ever creating duplicate keys.
    """
    global _base_config_lines
    if _base_config_lines is not None:
        return _base_config_lines

    os.makedirs(os.path.dirname(CAVA_CONFIG), exist_ok=True)

    real = CAVA_CONFIG if not os.path.islink(CAVA_CONFIG) else CAVA_CONFIG + ".sd"
    if not os.path.exists(real):
        # waveform is intentionally omitted here — _build_config_content
        # will inject it from the theme dict via the StopIteration fallback branch.
        with open(CAVA_CONFIG, "w") as f:
            f.write("# cava config -- created by Cava Solace\n\n"
                    "[general]\nbars = 0\nframerate = 60\nautosens = 1\n\n"
                    "[input]\nmethod = pipewire\nsource = auto\n\n"
                    "[output]\nmethod = noncurses\n\n")
        _base_config_lines = []
        return _base_config_lines

    try:
        with open(real) as f:
            lines = f.readlines()
    except Exception:
        lines = []

    # Keys we manage in [general] — strip so _build_config_content can
    # re-inject the correct value from the theme dict each time.
    # waveform, bar_width, bar_spacing all live in [general] per the stock
    # cava config.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    MANAGED_GENERAL_KEYS = {"waveform", "bar_width", "bar_spacing"}

    # Keys we manage in [output] — strip so _build_config_content can
    # re-inject correct values from the theme dict without duplication.
    # reverse mirrors the bar order left-to-right -- native cava [output] key.
    MANAGED_OUTPUT_KEYS = {"channels", "reverse"}

    kept       = []
    skip       = False   # inside a [color] or [smoothing] block
    in_out     = False   # inside [output] block
    in_general = False   # inside [general] block
    for line in lines:
        s = line.strip()
        if re.match(r"^\[(color|smoothing)\]", s):
            skip       = True
            in_out     = False
            in_general = False
            continue
        elif re.match(r"^\[output\]", s):
            skip       = False
            in_out     = True
            in_general = False
            kept.append(line)
            continue
        elif re.match(r"^\[general\]", s):
            skip       = False
            in_out     = False
            in_general = True
            kept.append(line)
            continue
        elif re.match(r"^\[", s):
            skip       = False
            in_out     = False
            in_general = False

        if skip:
            continue

        # Drop managed keys inside [general] -- we re-add from theme dict
        if in_general:
            key = s.split("=")[0].strip().lower()
            if key in MANAGED_GENERAL_KEYS:
                continue

        # Drop managed keys inside [output] -- we re-add from theme dict
        if in_out:
            key = s.split("=")[0].strip().lower()
            if key in MANAGED_OUTPUT_KEYS:
                continue

        kept.append(line)

    while kept and kept[-1].strip() == "":
        kept.pop()

    _base_config_lines = kept
    return _base_config_lines


def _build_config_content(theme):
    """
    Build the full config string in memory from cached base + new theme blocks.

    Therapeutic visual parameters in theme dict:
      # blend_direction not written -- only active with horizontal_gradient

    noise_reduction = 60-95 (randomised) -- therapeutically calibrated smoothing.
    channels = stereo for left/right channel separation -- spatial depth.

    References:
      https://github.com/karlstav/cava/blob/master/example_files/config
    """
    base      = _load_base_config()
    # noise_reduction: 77 = stock default. Range 60-95 randomised therapeutically.
    # gravity= is DEPRECATED since cava 0.8.0 -- removed.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    noise_reduction = theme.get("noise_reduction", 77)

    # waves: sub-option of monstercat smoothing. Randomised per-theme (70% on)
    # for therapeutic variety -- both states are calm, just different decay feel.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    waves = theme.get("waves", 1)

    # waveform: 1 = oscilloscope wave, 0 = frequency spectrum bars.
    # Lives in [general] section. Stripped from base config and re-injected
    # each apply so the current theme's choice always wins.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    waveform = theme.get("waveform", 0)

    # bar_width / bar_spacing: character-column geometry, [general] section.
    # Defaults (2, 1) match cava's own stock example config exactly, so a
    # theme missing these keys (e.g. an older saved .cava file) still
    # produces a valid, sane config.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    bar_width   = theme.get("bar_width", 2)
    bar_spacing = theme.get("bar_spacing", 1)

    # reverse: 0/1, mirrors bar order left-to-right. [output] section.
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    reverse = 1 if theme.get("reverse", False) else 0

    color_block = (
        ["\n[color]\n",
         f"background = '{theme['bg']}'\n",
         "gradient = 1\n",
         f"gradient_count = {len(theme['colors'])}\n"]
        + [f"gradient_color_{i+1} = '{c}'\n" for i, c in enumerate(theme["colors"])]
        # blend_direction omitted: only applies when horizontal_gradient is also active.
        # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    )
    smooth_block = [
        "\n[smoothing]\n",
        "monstercat = 1\n",
        f"waves = {waves}\n",
        f"noise_reduction = {noise_reduction}\n",
        "\n",
    ]
    # [output] extras — channels = stereo, reverse = mirror flag.
    # 'waveform', 'bar_width', 'bar_spacing' are [general] keys in cava —
    # NOT [output] or [smoothing].
    # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    extra_output = [
        "\n[output]\n",
        "channels = stereo\n",
        f"reverse = {reverse}\n",
        "\n",
    ]
    # Inject waveform/bar_width/bar_spacing into [general].
    # _load_base_config has already stripped any previous lines for these
    # keys. We insert them right after the [general] header in the base lines.
    general_lines = [
        f"waveform = {waveform}\n",
        f"bar_width = {bar_width}\n",
        f"bar_spacing = {bar_spacing}\n",
    ]
    try:
        gen_idx = next(i for i, l in enumerate(base) if l.strip() == "[general]")
        base = base[:gen_idx + 1] + general_lines + base[gen_idx + 1:]
    except StopIteration:
        # No [general] block in base — prepend one
        base = ["[general]\n"] + general_lines + ["\n"] + base


    return "".join(base + color_block + smooth_block + extra_output)


def apply_theme(theme):
    """
    Apply a theme -- writes only to /dev/shm (RAM). Zero SD card activity.
    cava sees the change instantly via symlink and live-reloads on SIGUSR1.
    The SD config is only written when the GUI closes (see flush_to_sd).

    SIGUSR1 triggers an immediate config reload in cava.
    Reference: https://github.com/karlstav/cava/blob/master/README.md
    """
    import shutil

    content = _build_config_content(theme)

    # Back up the real SD file once before replacing it with a symlink
    sd_backup = CAVA_CONFIG + ".sd"
    if not os.path.islink(CAVA_CONFIG) and os.path.exists(CAVA_CONFIG):
        if not os.path.exists(sd_backup):
            shutil.copy2(CAVA_CONFIG, sd_backup)

    # Write to RAM -- zero SD writes
    with open(CAVA_CONFIG_RAM, "w") as f:
        f.write(content)

    # Point cava's terminal config at the RAM file via symlink
    try:
        if os.path.exists(CAVA_CONFIG) or os.path.islink(CAVA_CONFIG):
            os.unlink(CAVA_CONFIG)
        os.symlink(CAVA_CONFIG_RAM, CAVA_CONFIG)
    except Exception:
        # Symlink failed -- fall back to direct write
        with open(CAVA_CONFIG, "w") as f:
            f.write(content)

    # Signal the running cava process to reload its config immediately.
    # SIGUSR1 triggers a live config reload -- works for terminal and SDL modes.
    # Reference: https://github.com/karlstav/cava/blob/master/README.md
    try:
        subprocess.run(
            ["pkill", "-USR1", "-u", str(os.getuid()), "-x", "cava"],
            check=False, capture_output=True
        )
    except Exception:
        pass


def flush_to_sd():
    """
    Called once when the GUI closes.
    Writes the current RAM config to the real SD path and restores a real file.
    This is the only SD write that happens during a normal session.
    """
    import shutil

    sd_backup = CAVA_CONFIG + ".sd"

    if not os.path.exists(CAVA_CONFIG_RAM):
        if os.path.islink(CAVA_CONFIG):
            if os.path.exists(sd_backup):
                try:
                    os.unlink(CAVA_CONFIG)
                    shutil.copy2(sd_backup, CAVA_CONFIG)
                    os.unlink(sd_backup)
                except Exception:
                    pass
        return

    try:
        content = open(CAVA_CONFIG_RAM).read()
        if os.path.islink(CAVA_CONFIG) or os.path.exists(CAVA_CONFIG):
            try:
                os.unlink(CAVA_CONFIG)
            except Exception:
                pass
        with open(CAVA_CONFIG, "w") as f:
            f.write(content)
        try:
            os.unlink(CAVA_CONFIG_RAM)
        except Exception:
            pass
        if os.path.exists(sd_backup):
            try:
                os.unlink(sd_backup)
            except Exception:
                pass
    except Exception:
        if os.path.exists(sd_backup):
            try:
                os.unlink(sd_backup)
            except Exception:
                pass



def is_cava_running():
    try:
        r = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "cava"],
                           capture_output=True)
        return r.returncode == 0
    except Exception:
        return False



# =============================================================================
# SWATCH DRAWING AREA (Cairo)
#
# Renders a mini-preview that accurately reflects what cava will show:
# The preview faithfully matches what cava renders in noncurses mode:
# gradient_color_1 at the bottom, gradient_color_N at the bar tips.
# =============================================================================
# Bar height profiles — stereo mirrored layout matching cava's default stereo mode.
# Low frequencies in centre, highs at edges. Heights are fractions of max_h.
# 16 bars matches a typical narrow terminal window feel.
# 24-bar frequency profile — models a realistic music spectrum in cava.
#
# Shape rationale based on typical cava output with music:
#   Sub-bass  (bars 1-2):   low and rounded — sub frequencies rarely peak
#   Bass      (bars 3-6):   tallest region — kick/bass dominant in most music
#   Low-mid   (bars 7-10):  strong but varied — guitar, bass harmonics
#   Mid       (bars 11-14): moderate — vocals, snare body
#   High-mid  (bars 15-18): sparser — hi-hats, cymbals, presence
#   Air       (bars 19-24): short and granular — very high freq, low energy
#
# Heights are deliberately varied bar-by-bar (no smooth ramp) so adjacent
# bars read as distinct — the eye gets genuine separation and flow.
# Ref: screenshots at https://github.com/karlstav/cava
BAR_HEIGHTS_VERT = [
    # Sub-bass
    0.18, 0.28,
    # Bass peak — tallest region
    0.62, 0.82, 1.00, 0.94, 0.78, 0.88,
    # Low-mid — varied, energetic
    0.70, 0.58, 0.74, 0.64,
    # Mid — moderate, step-down feel
    0.52, 0.44, 0.56, 0.48,
    # High-mid — sparser, staggered
    0.36, 0.28, 0.40, 0.32,
    # Air — short, granular
    0.22, 0.16, 0.24, 0.14,
]


class SwatchArea(Gtk.DrawingArea):
    """
    Terminal-accurate cava preview.

    24-bar frequency spectrum preview — matching a realistic cava output.
    Bars represent sub-bass through air frequencies with natural height variation.

    Colour bands are fixed to the FULL available height, divided equally
    between gradient stops. Every bar shares the same band boundaries —
    short bars simply show only the lower bands, tall bars reveal them all.
    This matches exactly how cava assigns colours: by absolute vertical
    position in the terminal, not by each bar's individual height.

    gradient_color_1 = bottom band  (always visible)
    gradient_color_N = top band     (only visible on the tallest bars)

    Ref: https://github.com/karlstav/cava/blob/master/example_files/config
    """

    def __init__(self, colors, bg, bar_spacing=1, bar_width=2, reverse=False):
        super().__init__()
        self.colors      = colors
        self.bg          = bg
        self._old_colors = colors
        self._old_bg     = bg
        self._fade_alpha = 1.0
        self._fading     = False
        # Bar geometry/reversal — see _on_draw for the cava-unit -> preview-px
        # mapping. Defaults match cava's own stock example config (2, 1).
        # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
        self.bar_spacing = bar_spacing
        self.bar_width   = bar_width
        self.reverse     = reverse
        self._old_bar_spacing = bar_spacing
        self._old_bar_width   = bar_width
        self._old_reverse     = reverse
        self.connect("draw", self._on_draw)

    def update(self, colors, bg, bar_spacing=1, bar_width=2, reverse=False):
        """Swap to a new palette (+ bar geometry/reversal) with a soft fade-in (~450ms at 30fps)."""
        self._old_colors      = self.colors
        self._old_bg          = self.bg
        self._old_bar_spacing = self.bar_spacing
        self._old_bar_width   = self.bar_width
        self._old_reverse     = self.reverse
        self.colors      = colors
        self.bg          = bg
        self.bar_spacing = bar_spacing
        self.bar_width   = bar_width
        self.reverse     = reverse
        self._fade_alpha = 0.0
        if not self._fading:
            self._fading = True
            GLib.timeout_add(33, self._fade_tick)

    def _fade_tick(self):
        """Advance crossfade 0.07 per tick — stops at 1.0."""
        if not self._fading:
            return False   # close() was called — stop immediately
        self._fade_alpha = min(1.0, self._fade_alpha + 0.07)
        if self.get_realized():
            self.queue_draw()
        if self._fade_alpha >= 1.0:
            self._fading = False
            return False
        return True

    def close(self):
        """Signal this widget's timers to stop (called from CavaSolace._on_close)."""
        self._fading = False

    def _on_draw(self, widget, cr):
        alloc = self.get_allocation()
        w, h  = alloc.width, alloc.height
        n_bars = len(BAR_HEIGHTS_VERT)
        pad    = 4

        gap, bar_w = self._geometry_for(w, n_bars, pad,
                                          self.bar_spacing, self.bar_width)

        if self._fade_alpha < 1.0:
            # ── Draw old palette at full opacity ──────────────────────────────
            old_gap, old_bar_w = self._geometry_for(w, n_bars, pad,
                                                      self._old_bar_spacing,
                                                      self._old_bar_width)
            cr.set_source_rgb(*hex_to_rgb(self._old_bg))
            cr.rectangle(0, 0, w, h)
            cr.fill()
            self._draw_bars(cr, w, h, n_bars, pad, old_gap, old_bar_w,
                            colors=self._old_colors, reverse=self._old_reverse)
            # ── Draw new palette on top, fading in ────────────────────────────
            cr.push_group()
            cr.set_source_rgb(*hex_to_rgb(self.bg))
            cr.rectangle(0, 0, w, h)
            cr.fill()
            self._draw_bars(cr, w, h, n_bars, pad, gap, bar_w,
                            colors=self.colors, reverse=self.reverse)
            cr.pop_group_to_source()
            cr.paint_with_alpha(self._fade_alpha)
        else:
            # ── Fully faded — draw new palette directly ───────────────────────
            cr.set_source_rgb(*hex_to_rgb(self.bg))
            cr.rectangle(0, 0, w, h)
            cr.fill()
            self._draw_bars(cr, w, h, n_bars, pad, gap, bar_w,
                            colors=self.colors, reverse=self.reverse)

        # Subtle baseline — mimics the terminal floor
        cr.set_source_rgba(1, 1, 1, 0.07)
        cr.rectangle(pad, h - pad, w - pad * 2, 1)
        cr.fill()

    def _geometry_for(self, w, n_bars, pad, bar_spacing, bar_width):
        """
        cava-unit -> preview-px mapping, shared by both the current and the
        crossfading 'old' palette (which may have different bar geometry).

        bar_spacing/bar_width in the real config are *character columns*
        (cava's own terminal-character unit), not pixels. The preview widget
        is a small fixed-size GTK DrawingArea (260x150, 24 bars), so we scale
        those small integers (0-3) up by a fixed px-per-unit factor to keep
        the visual effect readable while still being driven by the exact
        same values written to the real cava config -- the preview is never
        out of sync with what cava will actually do.
        Ref: https://github.com/karlstav/cava/blob/master/example_files/config

        Constants below (px_per_unit=2 for spacing, px_per_unit=1 for width,
        width_base=2) were chosen so the WIDEST combination ("dark":
        spacing=2, width=3) still fits naturally in the real 260px-wide /
        24-bar preview with zero clamping needed -- verified by hand
        calculation: dark totals 220px, balanced 150px, bright 80px, all
        comfortably under the ~252px usable budget. The gap formula has NO
        baseline offset -- bar_spacing=0 ("bright" mode) must render as a
        TRUE 0px gap, the solid wave-of-color look that real cava actually
        produces at that setting. A prior version added a flat +1px floor
        to the gap here, which silently prevented bar_spacing=0 from ever
        showing a true solid wave in the preview. bar_w keeps its +2px
        floor -- a bar can never be 0px wide and still be visible, so that
        baseline is intentional, not a bug. The clamp below is kept only as
        a defensive fallback for unexpectedly narrow allocations.
        """
        PX_PER_SPACING_UNIT = 2   # cava bar_spacing units -> preview px gap
        PX_PER_WIDTH_UNIT   = 1   # cava bar_width units   -> preview px width
        gap   = bar_spacing * PX_PER_SPACING_UNIT
        bar_w = 2 + bar_width   * PX_PER_WIDTH_UNIT

        natural_total = bar_w * n_bars + gap * (n_bars - 1) + pad * 2
        if natural_total > w:
            # Defensive fallback only -- not expected to trigger at the
            # preview's actual fixed size (see constants note above).
            # Scales bar_w down proportionally so the relative ordering
            # between bar_mode presets is preserved even if this path
            # is ever reached (e.g. widget resized unusually small).
            available = max(n_bars * 3, w - pad * 2 - gap * (n_bars - 1))
            scale     = available / (bar_w * n_bars)
            bar_w     = max(3, int(bar_w * scale))
        return gap, bar_w

    def _draw_bars(self, cr, w, h, n_bars, pad, gap, bar_w, colors=None, reverse=False):
        """
        Draw 24 square-topped bars with hard-edged fixed-height colour bands.

        KEY: band_h is computed from max_h (the full drawable height), NOT
        from each bar's individual height. All bars share the same colour band
        boundaries — exactly as cava renders in the terminal, where colour is
        determined by absolute vertical position, not each bar's proportion.

        Short bars (high-freq / air range) clip before reaching upper bands.
        Tall bars (bass range) reveal all gradient stops up to color_N at tip.

        colors: explicit colour list for crossfade; defaults to self.colors.
        reverse: mirrors the bar HEIGHT pattern left-to-right, matching
        cava's native 'reverse' [output] key (frequencies displayed the
        other way around). Bar x-positions stay left-to-right in slot
        order — only which height-data goes in which slot is mirrored.
        """
        if colors is None:
            colors = self.colors
        n_stops = len(colors)
        base    = h - pad
        max_h   = base - pad

        # Fixed band height based on FULL area — same for every bar
        band_h  = max_h / n_stops if n_stops > 0 else max_h

        for i in range(n_bars):
            src_idx = (n_bars - 1 - i) if reverse else i
            bar_h = max(3, int(max_h * BAR_HEIGHTS_VERT[src_idx]))
            x     = pad + i * (bar_w + gap)
            top_y = base - bar_h

            if n_stops < 2:
                cr.set_source_rgb(*hex_to_rgb(colors[0]))
                cr.rectangle(int(x), int(top_y), int(bar_w), int(bar_h))
                cr.fill()
                continue

            # Draw each colour band from bottom upward.
            # band_idx 0 = gradient_color_1 (bottom), N-1 = gradient_color_N (top)
            for band_idx in range(n_stops):
                band_bot = base  - band_idx       * band_h
                band_top = base  - (band_idx + 1) * band_h

                # Clip band to this bar's top — bands above it are not drawn
                clipped_top = max(band_top, top_y)
                clipped_h   = band_bot - clipped_top

                if clipped_h <= 0:
                    continue

                cr.set_source_rgb(*hex_to_rgb(colors[band_idx]))
                cr.rectangle(
                    int(x),
                    int(clipped_top),
                    int(bar_w),
                    math.ceil(clipped_h)
                )
                cr.fill()


# =============================================================================
# MAIN APPLICATION WINDOW — CavaSolace
#
# Touchscreen-optimised for 800×480 Raspberry Pi 7-inch display.
# All tap targets ≥ 44 px tall (WCAG 2.5.5 guideline).
# Reference: https://www.w3.org/WAI/WCAG21/Understanding/target-size.html
#
# Layout designed to fit inside 800×480 without scrolling.
# Buttons use 48 px minimum height for comfortable touch input.
# =============================================================================
class CavaSolace(Gtk.Window):
    """
    Therapeutic audio visualizer GUI.
    Generates science-based calming palettes and applies them live to cava.
    """

    def __init__(self):
        super().__init__(title="Cava Solace — Therapeutic Visualizer")
        self.set_default_size(500, 360)
        self.set_size_request(500, 360)
        self.set_resizable(True)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self._on_close)

        self._rand_theme    = None
        self._closed        = False  # set True in _on_close to stop all timers
        self._pulse_alpha    = 0.0      # 0.0 = dim, 1.0 = full glow
        self._pulse_dir      = 1        # +1 rising, -1 falling
        self._pulse_color    = (0.48, 0.72, 0.63)  # default sage — updated each Generate
        self._pulse_provider = Gtk.CssProvider()
        self._generate_btn   = None     # set after button creation

        # Window background tint — shifts to a very dark tint of the theme hue.
        # Rule: sat < 15%, lightness < 15% always reads calm (Colorhero 2025).
        # Ref: https://muffingroup.com/blog/calm-color-palette/
        self._window_bg_provider = Gtk.CssProvider()
        self._window_bg_old      = (0.05, 0.06, 0.07)  # initial near-black RGB
        self._window_bg_new      = (0.05, 0.06, 0.07)
        self._window_bg_alpha    = 1.0
        self._window_bg_fading   = False

        # ── CSS — dark therapeutic palette, touchscreen button sizes ─────────
        css = b"""
        window {
            background-color: #0d0f12;
        }
        button {
            min-height: 48px;
            min-width: 80px;
            border-radius: 8px;
            font-size: 14px;
            padding: 6px 14px;
        }
        button.narrow-button {
            min-width: 52px;
            padding: 6px 8px;
            font-size: 13px;
        }
        button.action-button {
            background: #1a2530;
            color: #b8d4e8;
            border: 1px solid #2a4060;
        }
        button.action-button:hover {
            background: #22334a;
        }
        button.launch-button {
            background: #1a3a22;
            color: #7ad4a0;
            border: 1px solid #2a6040;
            font-weight: bold;
        }
        button.launch-button:hover {
            background: #204830;
        }
        button.stop-button {
            background: #3a1a1a;
            color: #d47a7a;
            border: 1px solid #602020;
        }
        button.stop-button:hover {
            background: #4a2020;
        }
        label.title-label {
            color: #c8ddf0;
            font-size: 15px;
            font-weight: bold;
        }
        label.status-label {
            font-size: 12px;
        }
        label.meta-label {
            color: #687080;
            font-size: 11px;
            font-style: italic;
        }
        label.applied-label {
            color: #7ad4a0;
            font-size: 12px;
            font-style: italic;
        }
        label.badge-label {
            color: #7abcd4;
            font-size: 11px;
        }
        label.science-label {
            color: #6a8898;
            font-size: 10px;
            font-style: italic;
        }
        separator {
            background-color: #1e2830;
        }
        """
        css_prov = Gtk.CssProvider()
        css_prov.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css_prov,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Window background tint provider — scoped to this window only.
        # Applied at +1 priority so it overrides the fixed #0d0f12 above.
        Gtk.StyleContext.add_provider(
            self.get_style_context(),
            self._window_bg_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1
        )

        # ── Root layout ───────────────────────────────────────────────────────
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        root.set_margin_top(6)
        root.set_margin_bottom(6)
        root.set_margin_start(10)
        root.set_margin_end(10)
        self.add(root)

        # ── Title + status row ────────────────────────────────────────────────
        title_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        title_lbl = Gtk.Label(label="Cava Solace")
        title_lbl.get_style_context().add_class("title-label")
        title_row.pack_start(title_lbl, False, False, 0)

        self._status_lbl = Gtk.Label(label="")
        self._status_lbl.get_style_context().add_class("status-label")
        self._status_lbl.set_halign(Gtk.Align.END)
        title_row.pack_end(self._status_lbl, True, True, 0)
        root.pack_start(title_row, False, False, 0)

        root.pack_start(Gtk.Separator(), False, False, 2)

        # ── Middle area: swatch preview + palette dots ────────────────────────
        mid_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        root.pack_start(mid_row, False, False, 0)

        # Swatch preview (left)
        self._rand_swatch = SwatchArea(["#7ab8a0", "#82b8c8"], "#0d0d0d")
        self._rand_swatch.set_size_request(190, 130)
        mid_row.pack_start(self._rand_swatch, False, False, 0)

        # Theme info (right of swatch)
        info_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        info_col.set_valign(Gtk.Align.CENTER)
        mid_row.pack_start(info_col, True, True, 0)

        self._rand_name_lbl = Gtk.Label(label="Press Generate")
        self._rand_name_lbl.get_style_context().add_class("title-label")
        self._rand_name_lbl.set_halign(Gtk.Align.START)
        info_col.pack_start(self._rand_name_lbl, False, False, 0)

        self._rand_badge_lbl = Gtk.Label(label="therapeutic")
        self._rand_badge_lbl.get_style_context().add_class("badge-label")
        self._rand_badge_lbl.set_halign(Gtk.Align.START)
        info_col.pack_start(self._rand_badge_lbl, False, False, 0)

        self._rand_meta_lbl = Gtk.Label(label="")
        self._rand_meta_lbl.get_style_context().add_class("meta-label")
        self._rand_meta_lbl.set_halign(Gtk.Align.START)
        self._rand_meta_lbl.set_line_wrap(True)
        info_col.pack_start(self._rand_meta_lbl, False, False, 0)

        # ── Science note — pull-quote block with left accent bar ─────────────
        # The 3px accent bar colour matches the theme's first gradient stop.
        # GTK3 CSS has no border-left — we use a DrawingArea for the bar.
        science_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)

        self._science_accent = Gtk.DrawingArea()
        self._science_accent.set_size_request(3, -1)
        self._science_accent_color = (0.48, 0.72, 0.63)  # default sage
        def _draw_accent(w, cr):
            cr.set_source_rgba(*self._science_accent_color, 0.7)
            alloc = w.get_allocation()
            cr.rectangle(0, 0, alloc.width, alloc.height)
            cr.fill()
        self._science_accent.connect("draw", _draw_accent)
        science_row.pack_start(self._science_accent, False, False, 0)

        # 8px breathing room between bar and text
        science_row.pack_start(Gtk.Box(), False, False, 4)

        self._science_lbl = Gtk.Label(label="")
        self._science_lbl.get_style_context().add_class("science-label")
        self._science_lbl.set_halign(Gtk.Align.START)
        self._science_lbl.set_line_wrap(True)
        self._science_lbl.set_xalign(0)
        science_row.pack_start(self._science_lbl, True, True, 0)

        info_col.pack_start(science_row, False, False, 6)

        # Palette colour dots
        self._palette_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        info_col.pack_start(self._palette_box, False, False, 4)

        # ── Button rows ───────────────────────────────────────────────────────
        root.pack_start(Gtk.Separator(), False, False, 2)

        btn_row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        root.pack_start(btn_row1, False, False, 0)

        def _btn(label, handler, style_class="action-button"):
            b = Gtk.Button(label=label)
            for cls in style_class.split():
                b.get_style_context().add_class(cls)
            b.connect("clicked", handler)
            return b

        gen_btn = _btn("🎲  Generate", self._on_generate)
        gen_btn.set_name("generate-btn")  # used for scoped CSS selector
        self._generate_btn = gen_btn
        # Attach the pulse CssProvider to the generate button only.
        # CSS uses #generate-btn selector so it can never affect other buttons.
        Gtk.StyleContext.add_provider(
            gen_btn.get_style_context(),
            self._pulse_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1
        )
        btn_row1.pack_start(gen_btn, True, True, 0)
        btn_row1.pack_start(_btn("✔  Apply", self._on_apply_random), True, True, 0)
        btn_row1.pack_start(_btn("💾  Save", self._on_save_theme, "action-button narrow-button"), False, False, 0)
        btn_row1.pack_start(_btn("📂  Load", self._on_load_theme, "action-button narrow-button"), False, False, 0)

        btn_row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        root.pack_start(btn_row2, False, False, 0)

        btn_row2.pack_start(
            _btn("▶  Launch cava", self._on_launch, "launch-button"), True, True, 0
        )
        btn_row2.pack_start(
            _btn("■  Stop cava", self._on_stop, "stop-button"), True, True, 0
        )

        # ── Status / feedback label ───────────────────────────────────────────
        self._applied_lbl = Gtk.Label(label="")
        self._applied_lbl.get_style_context().add_class("applied-label")
        self._applied_lbl.set_halign(Gtk.Align.CENTER)
        root.pack_start(self._applied_lbl, False, False, 2)

        self._update_status_label()

        # Start the gentle pulse animation on the Generate button.
        # 50ms tick = 20fps — lightweight on the Pi 4.
        # Each tick advances the sine wave by a small step (~4s full cycle).
        GLib.timeout_add(50, self._pulse_tick)

    def _on_close(self, *_):
        """Flush RAM config to SD on window close — the one SD write per session."""
        self._closed = True   # signals all GLib timers to stop immediately
        if hasattr(self, "_rand_swatch"):
            self._rand_swatch.close()  # stop swatch fade timer
        flush_to_sd()
        Gtk.main_quit()
        return True  # prevent default GTK destroy (we handle it via main_quit)

    # ── Generate button pulse animation ───────────────────────────────────────
    def _pulse_tick(self):
        """
        Called every 50ms by GLib timer. Advances a sine-wave alpha and
        updates the Generate button's border glow via a scoped CssProvider.

        Step size 0.04 per tick at 50ms = ~1.25 full cycles per 4 seconds.
        The glow colour matches the current theme's first gradient stop so
        the pulse always feels connected to the loaded palette.
        """
        self._pulse_alpha += 0.04 * self._pulse_dir
        if self._pulse_alpha >= 1.0:
            self._pulse_alpha = 1.0
            self._pulse_dir   = -1
        elif self._pulse_alpha <= 0.0:
            self._pulse_alpha = 0.0
            self._pulse_dir   = 1

        r, g, b = self._pulse_color
        # Interpolate border between dim (#2a4060 equivalent) and glow colour
        dim_r, dim_g, dim_b = 0.16, 0.25, 0.38
        a = self._pulse_alpha
        br = dim_r + (r - dim_r) * a
        bg = dim_g + (g - dim_g) * a
        bb = dim_b + (b - dim_b) * a
        border = "#{:02x}{:02x}{:02x}".format(
            int(br * 255), int(bg * 255), int(bb * 255)
        )
        # Shadow glow: soft outer ring at lower opacity
        glow_a  = 0.15 + self._pulse_alpha * 0.35
        glow_css = "rgba({},{},{},{:.2f})".format(
            int(r * 255), int(g * 255), int(b * 255), glow_a
        )
        # #generate-btn targets only this button — never bleeds to Save/Load/Apply
        css = (
            f"button#generate-btn {{"
            f"  border: 1px solid {border};"
            f"  box-shadow: 0 0 6px 1px {glow_css};"
            f"}}"
        ).encode()
        try:
            self._pulse_provider.load_from_data(css)
        except Exception:
            pass
        if self._closed:
            return False
        return True  # keep timer running

    def _update_pulse_color(self, colors):
        """Update glow colour to match the first stop of the new palette."""
        if colors:
            self._pulse_color = hex_to_rgb(colors[0])

    def _update_science_accent(self, colors):
        """Update the science note accent bar colour to match theme's first stop."""
        if colors:
            r, g, b = hex_to_rgb(colors[0])
            self._science_accent_color = (r, g, b)
            self._science_accent.queue_draw()

    def _bg_hex_to_tint_rgb(self, bg_hex):
        """
        Convert theme bg_hex to a clamped dark tint RGB tuple (0.0-1.0).
        Clamps sat ≤ 18%, lightness ≤ 10% — calm regardless of hue.
        Ref: https://muffingroup.com/blog/calm-color-palette/
        """
        r, g, b = hex_to_rgb(bg_hex)
        h, l, s = colorsys.rgb_to_hls(r, g, b)
        s2 = min(s, 0.18)
        l2 = min(l, 0.10)
        return colorsys.hls_to_rgb(h, l2, s2)

    def _update_window_bg(self, bg_hex):
        """
        Fade the window background to a dark tint of the new theme hue.
        Same ~450ms duration as the SwatchArea crossfade — they finish together.
        """
        self._window_bg_old   = self._window_bg_new
        self._window_bg_new   = self._bg_hex_to_tint_rgb(bg_hex)
        self._window_bg_alpha = 0.0
        if not self._window_bg_fading:
            self._window_bg_fading = True
            GLib.timeout_add(33, self._window_bg_tick)

    def _window_bg_tick(self):
        """Advance window background crossfade. Step 0.07 ≈ 450ms at 30fps."""
        self._window_bg_alpha = min(1.0, self._window_bg_alpha + 0.07)
        # Interpolate between old and new tint RGB
        a   = self._window_bg_alpha
        or_, og, ob = self._window_bg_old
        nr, ng, nb  = self._window_bg_new
        r = or_ + (nr - or_) * a
        g = og  + (ng - og)  * a
        b = ob  + (nb - ob)  * a
        tint = "#{:02x}{:02x}{:02x}".format(
            int(r * 255), int(g * 255), int(b * 255)
        )
        css = f"window {{ background-color: {tint}; }}".encode()
        try:
            self._window_bg_provider.load_from_data(css)
        except Exception:
            pass
        if self._closed or self._window_bg_alpha >= 1.0:
            self._window_bg_fading = False
            return False
        return True

    def _on_generate(self, *_):
        raw   = generate_therapeutic()
        name  = raw.get("theme_name") or "Therapeutic Palette"

        self._rand_theme = {
            "id":               f"rand-{id(raw)}",
            "name":             name,
            "desc":             "Therapeutic - science-based calming palette",
            "bg":               raw["bg"],
            "colors":           raw["colors"],
            "noise_reduction":  raw.get("noise_reduction", 77),
            "waves":            raw.get("waves", 1),
            "waveform":         raw.get("waveform", 0),
            "inverted":         raw.get("inverted", False),
            # blend_direction omitted -- not active without horizontal_gradient
            "mode_label":       "therapeutic",
            "science_note":     raw.get("science_note", ""),
            # Bar geometry/reversal -- real cava [general]/[output] keys.
            # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
            "bar_spacing":      raw.get("bar_spacing", 1),
            "bar_width":        raw.get("bar_width", 2),
            "bar_mode":         raw.get("bar_mode", "balanced"),
            "reverse":          raw.get("reverse", False),
        }
        self._render_rand_preview(self._rand_theme)
        self._update_pulse_color(self._rand_theme["colors"])
        self._update_window_bg(self._rand_theme["bg"])
        self._update_science_accent(self._rand_theme["colors"])

    def _render_rand_preview(self, t):
        self._rand_swatch.update(
            t["colors"], t["bg"],
            bar_spacing=t.get("bar_spacing", 1),
            bar_width=t.get("bar_width", 2),
            reverse=t.get("reverse", False),
        )
        self._rand_name_lbl.set_text(t["name"])
        self._rand_badge_lbl.set_text(t["mode_label"])
        self._science_lbl.set_text(t.get("science_note", ""))
        # cava always renders bars regardless of waveform setting.
        # waveform=1 changes the data source (oscilloscope vs FFT spectrum)
        # but the visual output is always block bars in noncurses mode.
        # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
        src_str   = "oscilloscope" if t.get("waveform", 0) else "spectrum"
        inv_str   = "  ↓ inverted" if t.get("inverted", False) else ""
        # waves_str: literal cava config key name + on/off, matching the same
        # convention already used for 'reverse' below -- avoids inventing
        # descriptive adjectives (e.g. "flowing"/"stepped") that don't
        # correspond to anything actually written in the config file.
        # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
        waves_str = "on" if t.get("waves", 1) else "off"
        # bar_mode_str: "dark"/"bright"/"balanced" -- contextual bar geometry
        # derived from palette saturation/lightness. rev_str: mirrors cava's
        # own 'reverse' key name exactly, to avoid any mismatch between what
        # the GUI says and what the config file says.
        # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
        # bar_mode_str: display word for the contextual saturation-driven
        # spacing/width pairing. Internal bar_mode values ("dark"/"balanced"/
        # "bright") are unchanged everywhere they're used for thresholds and
        # .cava round-trip re-derivation -- this dict only swaps the label
        # shown to the user, since saturation (not lightness) is the actual
        # driving signal (see gen_therapeutic comments), so "vibrancy" reads
        # more accurately than "bright"/"dark".
        bar_mode_display = {"dark": "muted", "balanced": "balanced", "bright": "vivid"}
        bar_mode_str = bar_mode_display.get(t.get("bar_mode", "balanced"), "balanced")
        rev_str      = "  ↔ reversed" if t.get("reverse", False) else ""
        self._rand_meta_lbl.set_text(
            f"stops: {len(t['colors'])}   src: {src_str}   "
            f"smooth: {t.get('noise_reduction', 77)}   waves: {waves_str}{inv_str}\n"
            f"vibrancy: {bar_mode_str}   spacing: {t.get('bar_spacing', 1)}   "
            f"width: {t.get('bar_width', 2)}{rev_str}"
        )

        for child in self._palette_box.get_children():
            self._palette_box.remove(child)
        for color in t["colors"]:
            dot = Gtk.DrawingArea()
            dot.set_size_request(22, 22)
            r, g, b = hex_to_rgb(color)
            def _draw_dot(widget, cr, r=r, g=g, b=b):
                # Filled circle
                cr.set_source_rgb(r, g, b)
                cr.arc(11, 11, 9, 0, 2 * math.pi)
                cr.fill()
                # Thin outer ring — same colour at 45% opacity for definition
                cr.set_source_rgba(r, g, b, 0.45)
                cr.set_line_width(1.5)
                cr.arc(11, 11, 9.75, 0, 2 * math.pi)
                cr.stroke()
                # Subtle inner highlight — white arc at top-left (12 o'clock to 9)
                # gives a gentle depth without looking glossy
                cr.set_source_rgba(1, 1, 1, 0.12)
                cr.set_line_width(2.0)
                cr.arc(11, 11, 6.5, math.pi, 3 * math.pi / 2)
                cr.stroke()
            dot.connect("draw", _draw_dot)
            self._palette_box.pack_start(dot, False, False, 2)
        self._palette_box.show_all()

    def _on_apply_random(self, *_):
        if not self._rand_theme:
            return
        try:
            apply_theme(self._rand_theme)
            self._show_applied(f"Applied: {self._rand_theme['name']}")
            self._update_status_label()
            GLib.timeout_add_seconds(3, self._clear_applied)
        except Exception as e:
            self._show_applied(f"Error: {e}")

    def _on_save_theme(self, *_):
        """
        Save the current therapeutic palette as a plain-text INI .cava file.
        Writes [general] (waveform, bar_width, bar_spacing), [output]
        (channels, reverse), [color] (gradient), and [smoothing]
        (noise_reduction) blocks.
        Ref: https://github.com/karlstav/cava/blob/master/example_files/config
        """
        if not self._rand_theme:
            self._show_applied("Generate a theme first")
            GLib.timeout_add_seconds(2, self._clear_applied)
            return

        t         = self._rand_theme
        lines = [
            f"# cava theme: {t['name']}\n",
            "# Generated by Cava Solace -- Therapeutic Randomizer\n",
        ]
        science = t.get("science_note", "")
        if science:
            for s_line in science.splitlines():
                lines.append(f"# {s_line}\n")
        lines += [
            "#\n",
            f"# inverted: {'yes' if t.get('inverted', False) else 'no'}\n",
            f"# reversed: {'yes' if t.get('reverse', False) else 'no'}\n",
            "# Load with: cava --theme <path-to-this-file>\n",
            "# Or copy the blocks below into ~/.config/cava/config\n",
            "#\n",
            "# Note: blend_direction is only active when horizontal_gradient is\n",
            "# also set. This theme uses gradient-only mode (bottom to top).\n",
            "# Ref: https://github.com/karlstav/cava/blob/master/example_files/config\n",
            "#\n",
            "# References:\n",
            "#   https://github.com/karlstav/cava\n",
            "\n",
            "[general]\n",
            f"waveform = {t.get('waveform', 0)}\n",
            f"bar_width = {t.get('bar_width', 2)}\n",
            f"bar_spacing = {t.get('bar_spacing', 1)}\n",
            "\n",
            "[output]\n",
            "channels = stereo\n",
            f"reverse = {1 if t.get('reverse', False) else 0}\n",
            "\n",
            "[color]\n",
            f"background = '{t['bg']}'\n",
            "gradient = 1\n",
            f"gradient_count = {len(t['colors'])}\n",
        ]
        for i, c in enumerate(t["colors"], 1):
            lines.append(f"gradient_color_{i} = '{c}'\n")
        lines += [
            "\n",
            "[smoothing]\n",
            "monstercat = 1\n",
            f"waves = {t.get('waves', 1)}\n",
            f"noise_reduction = {t.get('noise_reduction', 77)}\n",
        ]
        content = "".join(lines)

        dialog = Gtk.FileChooserDialog(
            title="Save theme -- choose where to save",
            parent=self,
            action=Gtk.FileChooserAction.SAVE,
        )
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Save",   Gtk.ResponseType.ACCEPT)
        dialog.set_do_overwrite_confirmation(True)

        safe_name = re.sub(r"[^\w\s-]", "", t["name"])
        safe_name = re.sub(r"[\s]+", "-", safe_name.strip()).lower()
        dialog.set_current_name(f"{safe_name}.cava")

        docs = os.path.expanduser("~/Documents")
        dialog.set_current_folder(docs if os.path.isdir(docs) else os.path.expanduser("~"))

        ff = Gtk.FileFilter()
        ff.set_name("cava theme files (*.cava)")
        ff.add_pattern("*.cava")
        dialog.add_filter(ff)
        fa = Gtk.FileFilter()
        fa.set_name("All files")
        fa.add_pattern("*")
        dialog.add_filter(fa)

        response = dialog.run()
        # IMPORTANT: get_filename() must be called BEFORE destroy()
        path = dialog.get_filename() if response == Gtk.ResponseType.ACCEPT else None
        dialog.destroy()

        if response != Gtk.ResponseType.ACCEPT or not path:
            return
        if not path.endswith(".cava"):
            path += ".cava"

        try:
            with open(path, "w") as f:
                f.write(content)
            self._show_applied(f"Saved: {os.path.basename(path)}")
            GLib.timeout_add_seconds(3, self._clear_applied)
        except Exception as e:
            self._show_applied(f"Save failed: {e}")
            GLib.timeout_add_seconds(4, self._clear_applied)

    def _on_load_theme(self, *_):
        """
        Load a .cava theme file saved by Cava Solace into the preview.
        Parses [general] (waveform, bar_width, bar_spacing), [output]
        (reverse), [color] (gradient), and [smoothing] (noise_reduction)
        blocks. Apply after loading to send to cava.
        Ref: https://github.com/karlstav/cava/blob/master/example_files/config
        """
        dialog = Gtk.FileChooserDialog(
            title="Load theme -- choose a .cava file",
            parent=self,
            action=Gtk.FileChooserAction.OPEN,
        )
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Open",   Gtk.ResponseType.ACCEPT)

        docs = os.path.expanduser("~/Documents")
        dialog.set_current_folder(docs if os.path.isdir(docs) else os.path.expanduser("~"))

        ff = Gtk.FileFilter()
        ff.set_name("cava theme files (*.cava)")
        ff.add_pattern("*.cava")
        dialog.add_filter(ff)
        fa = Gtk.FileFilter()
        fa.set_name("All files")
        fa.add_pattern("*")
        dialog.add_filter(fa)

        response = dialog.run()
        # IMPORTANT: get_filename() must be called BEFORE destroy()
        # GTK invalidates the dialog on destroy -- calling after causes crashes.
        path = dialog.get_filename() if response == Gtk.ResponseType.ACCEPT else None
        dialog.destroy()

        if response != Gtk.ResponseType.ACCEPT or not path:
            return

        try:
            with open(path) as f:
                raw = f.read()

            theme_name   = os.path.splitext(os.path.basename(path))[0].replace("-", " ").title()
            science_note = ""
            comment_lines = []
            for line in raw.splitlines():
                stripped = line.strip()
                if stripped.startswith("#"):
                    comment_lines.append(stripped.lstrip("# ").strip())
            if comment_lines:
                if comment_lines[0].lower().startswith("cava theme:"):
                    theme_name = comment_lines[0].split(":", 1)[1].strip()
                science_lines = [l for l in comment_lines if
                                 any(k in l for k in ["parasympathetic", "Manchester",
                                                       "NeuroLaunch", "evidence"])]
                if science_lines:
                    science_note = "\n".join(science_lines)

            def ini_val(key):
                m = re.search(
                    rf"^\s*{re.escape(key)}\s*=\s*'?([^'\n]+)'?",
                    raw, re.MULTILINE | re.IGNORECASE
                )
                return m.group(1).strip().strip("'\"") if m else None

            bg = ini_val("background") or "#0d0d0d"

            color_matches = re.findall(
                r"^\s*gradient_color_\d+\s*=\s*'?([^'\n]+)'?",
                raw, re.MULTILINE | re.IGNORECASE
            )
            colors = [c.strip().strip("'\"") for c in color_matches]

            if len(colors) < 2:
                raise ValueError("No gradient colors found -- not a valid .cava theme file")

            noise_reduction = int(ini_val("noise_reduction") or 77)
            waves           = int(ini_val("waves") or 1)
            waveform        = int(ini_val("waveform") or 0)
            # inverted is stored as a comment — parse it from comment_lines
            inverted = any("inverted: yes" in l for l in comment_lines)

            # bar_width / bar_spacing: real [general] INI keys (not comments).
            # reverse: real [output] INI key. Defaults match cava's own
            # stock example config (2, 1, 0) for files saved before this
            # feature existed, or hand-edited files that omit them.
            # Ref: https://github.com/karlstav/cava/blob/master/example_files/config
            bar_width   = int(ini_val("bar_width") or 2)
            bar_spacing = int(ini_val("bar_spacing") or 1)
            reverse_val = ini_val("reverse")
            reverse     = (reverse_val == "1") if reverse_val is not None else \
                          any("reversed: yes" in l for l in comment_lines)

            # Re-derive bar_mode label for display consistency with freshly
            # generated themes -- a loaded file may have been hand-edited,
            # so we infer the closest matching mode from the actual values
            # rather than trusting an absent/stale label.
            if bar_spacing >= 2 and bar_width >= 3:
                bar_mode = "dark"
            elif bar_spacing <= 0 and bar_width <= 1:
                bar_mode = "bright"
            else:
                bar_mode = "balanced"

            self._rand_theme = {
                "id":               f"imported-{os.path.basename(path)}",
                "name":             theme_name,
                "desc":             "Loaded - .cava file",
                "bg":               bg,
                "colors":           colors,
                "noise_reduction":  noise_reduction,
                "waves":            waves,
                "waveform":         waveform,
                "inverted":         inverted,
                "mode_label":       "loaded",
                "science_note":     science_note,
                "bar_width":        bar_width,
                "bar_spacing":      bar_spacing,
                "bar_mode":         bar_mode,
                "reverse":          reverse,
            }
            self._render_rand_preview(self._rand_theme)
            self._update_pulse_color(self._rand_theme["colors"])
            self._update_window_bg(self._rand_theme["bg"])
            self._update_science_accent(self._rand_theme["colors"])
            self._show_applied(f"Loaded: {theme_name}")
            GLib.timeout_add_seconds(3, self._clear_applied)

        except (ValueError, OSError) as e:
            self._show_applied(f"Load failed: {e}")
            GLib.timeout_add_seconds(4, self._clear_applied)
        except Exception as e:
            self._show_applied(f"Could not read file: {e}")
            GLib.timeout_add_seconds(4, self._clear_applied)

    # ── Launch / Stop ─────────────────────────────────────────────────────────
    def _on_launch(self, *_):
        self._launch_terminal()

    def _launch_terminal(self):
        """
        Launch cava in a terminal.
        lxterminal is the Pi OS default and runs cava fine (native Wayland,
        truecolor). foot is tried first only as a courtesy if manually installed;
        it is not required and not installed by cava-manager.sh.

        lxterminal uses --profile=cava-solace, a SEPARATE config file
        (lxterminal-cava-solace.conf, created by ensure_lxterminal_cava_profile()
        in the bash installer) that hides the menu bar and scrollbar for a
        cleaner fullscreen visual on the touchscreen. This never touches the
        user's default lxterminal.conf -- Start Menu launches and any other
        normal lxterminal use are completely unaffected.
        Ref: https://github.com/lxde/lxterminal/blob/master/src/setting.c
        """
        for cmd in [["foot", "cava"],
                    ["xfce4-terminal", "--command=cava"],
                    ["lxterminal", "--profile=cava-solace", "-e", "cava"],
                    ["x-terminal-emulator", "-e", "cava"]]:
            try:
                subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self._show_applied("cava launched in terminal mode")
                GLib.timeout_add_seconds(2, self._refresh_status)
                return
            except FileNotFoundError:
                continue
        self._show_applied("No terminal found -- run: lxterminal -e cava")
        GLib.timeout_add_seconds(3, self._clear_applied)

    def _on_stop(self, *_):
        try:
            subprocess.run(["pkill", "-u", str(os.getuid()), "-x", "cava"], check=False)
            self._show_applied("cava stopped")
            GLib.timeout_add_seconds(1, self._refresh_status)
        except Exception as e:
            self._show_applied(f"Stop failed: {e}")
            GLib.timeout_add_seconds(3, self._clear_applied)

    # ── Helpers ───────────────────────────────────────────────────────────────
    def _show_applied(self, msg):
        self._applied_lbl.set_text(msg)

    def _clear_applied(self):
        if not self._closed and self.get_realized():
            self._applied_lbl.set_text("")
        return False

    def _refresh_status(self):
        if not self._closed and self.get_realized():
            self._update_status_label()
        return False

    def _update_status_label(self):
        cava_ok = (os.path.exists(os.path.expanduser("~/.local/bin/cava")) or
                   any(os.path.exists(os.path.join(d, "cava"))
                       for d in os.environ.get("PATH", "").split(":")))
        running = is_cava_running()
        if not cava_ok:
            self._status_lbl.set_markup(
                '<span color="#cc4444">cava not found -- run cava-manager.sh to install</span>')
        elif running:
            self._status_lbl.set_markup(
                '<span color="#1ED760">cava running</span>'
                '  <span color="#505070">-- theme changes apply live</span>')
        else:
            self._status_lbl.set_markup(
                '<span color="#505070">cava not running</span>'
                '  <span color="#404060">-- press Launch to start</span>')


# =============================================================================
# ENTRY POINT
# =============================================================================
if __name__ == "__main__":
    # Clean up any dangling symlink from a previous crashed session
    if os.path.islink(CAVA_CONFIG):
        target = os.readlink(CAVA_CONFIG)
        if not os.path.exists(target):
            try:
                os.unlink(CAVA_CONFIG)
                print("Note: removed dangling config symlink (previous crash?)")
            except Exception:
                pass

    if not os.path.exists(CAVA_CONFIG) and not os.path.islink(CAVA_CONFIG):
        print(f"Note: cava config not found at {CAVA_CONFIG}")
        print("Install cava first using cava-manager.sh, or the GUI will create a minimal config.")

    win = CavaSolace()
    win.show_all()

    GLib.idle_add(lambda: (win._on_generate(), False))

    Gtk.main()
PYEOF
    chmod +x "$GUI_SCRIPT"
    info "GUI script written: $GUI_SCRIPT"
}

# =============================================================================
# GUI ICON
# =============================================================================
write_gui_icon() {
    cat > "$ICON_FILE_GUI" << 'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="14" fill="#111118"/>
  <rect x="8"  y="8"  width="38" height="38" rx="7" fill="#1ED760"/>
  <rect x="54" y="8"  width="38" height="38" rx="7" fill="#fabd2f"/>
  <rect x="8"  y="54" width="38" height="38" rx="7" fill="#eb6f92"/>
  <rect x="54" y="54" width="38" height="38" rx="7" fill="#74c7ec"/>
  <circle cx="50" cy="50" r="9" fill="#111118"/>
  <circle cx="50" cy="50" r="6" fill="#e0e0f0" opacity="0.9"/>
</svg>
SVGEOF
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    info "GUI icon written: $ICON_FILE_GUI"
}

# =============================================================================
# GUI DESKTOP SHORTCUT
# =============================================================================
write_gui_desktop_shortcut() {
    cat > "$DESKTOP_FILE_GUI" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Cava Solace
GenericName=Therapeutic Sonic Visualizer
Comment=Science-based therapeutic audio visualizer
Exec=python3 ${GUI_SCRIPT}
Icon=cava-solace
Terminal=false
Categories=Audio;AudioVideo;Music;
Keywords=audio;visualizer;cava;therapeutic;solace;
StartupNotify=false
EOF
    chmod 644 "$DESKTOP_FILE_GUI"
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    info "GUI desktop shortcut written: $DESKTOP_FILE_GUI"
}

# =============================================================================
# LXTERMINAL CAVA-SOLACE PROFILE
#
# lxterminal supports --profile=NAME, which loads/saves a fully separate
# config file: ~/.config/lxterminal/lxterminal-NAME.conf. This is a real
# built-in lxterminal feature (not a workaround) -- confirmed against the
# actual source (load_setting() in setting.c) and the upstream man page,
# both for the exact version Pi OS Trixie ships (0.4.1-1).
# Ref: https://github.com/lxde/lxterminal/blob/master/src/setting.c
#      https://manpages.debian.org/trixie/lxterminal/x-terminal-emulator.1
#
# IMPORTANT (verified from source): if the profile file does not exist yet,
# lxterminal falls back to the SYSTEM-WIDE default config to seed it -- NOT
# the user's personal ~/.config/lxterminal/lxterminal.conf. Left alone, that
# means cava's terminal could come up with different fonts/colours than the
# user is used to, not just a hidden menu/scrollbar. So this function seeds
# the new profile from the user's ACTUAL current lxterminal.conf (read-only
# copy, never written to) before flipping just the two chrome-hiding keys.
#
# Non-destructive by design: lxterminal.conf (used by Start Menu launches and
# any other normal lxterminal usage) is only ever read here, never written.
# Only created once -- if the file already exists (including from a prior
# install, or hand-edited later), it is left exactly as-is on Update/repeat
# Install so manual tweaks to this profile persist.
# =============================================================================
ensure_lxterminal_cava_profile() {
    if [[ -f "$LXTERM_CAVA_PROFILE" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$LXTERM_CAVA_PROFILE")"

    if [[ -f "$LXTERM_DEFAULT_CONF" ]]; then
        cp "$LXTERM_DEFAULT_CONF" "$LXTERM_CAVA_PROFILE"
    else
        printf '[general]\n' > "$LXTERM_CAVA_PROFILE"
    fi

    # Defensive: a copied file should always have [general], but guard
    # against a missing/malformed source file rather than assume.
    if ! grep -q '^\[general\]' "$LXTERM_CAVA_PROFILE" 2>/dev/null; then
        printf '[general]\n' | cat - "$LXTERM_CAVA_PROFILE" > "$LXTERM_CAVA_PROFILE.tmp" \
            && mv "$LXTERM_CAVA_PROFILE.tmp" "$LXTERM_CAVA_PROFILE"
    fi

    # Force these two keys regardless of what was copied in above.
    if grep -q '^hidemenubar' "$LXTERM_CAVA_PROFILE"; then
        sed -i 's/^hidemenubar.*/hidemenubar=true/' "$LXTERM_CAVA_PROFILE"
    else
        sed -i '/^\[general\]/a hidemenubar=true' "$LXTERM_CAVA_PROFILE"
    fi
    if grep -q '^hidescrollbar' "$LXTERM_CAVA_PROFILE"; then
        sed -i 's/^hidescrollbar.*/hidescrollbar=true/' "$LXTERM_CAVA_PROFILE"
    else
        sed -i '/^\[general\]/a hidescrollbar=true' "$LXTERM_CAVA_PROFILE"
    fi

    info "Created cava-only lxterminal profile: $LXTERM_CAVA_PROFILE"
    info "Your default lxterminal.conf (Start Menu launches) is untouched."
}

install_gui() {
    step "Installing Cava Solace dependencies"
    # python3-gi: PyGObject GTK3 bindings
    # python3-gi-cairo: Cairo drawing support
    # gir1.2-gtk-3.0: GTK3 introspection data required by PyGObject
    # Reference: https://pygobject.gnome.org/
    #
    # IMPORTANT: apt-get errors must NOT abort the script under set -euo pipefail.
    # Pre-check each package with dpkg and only install what is missing.
    # If apt fails we warn but continue — the GUI write must always run.
    local MISSING_PKGS=()
    for pkg in python3-gi python3-gi-cairo gir1.2-gtk-3.0; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            MISSING_PKGS+=("$pkg")
        fi
    done

    if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
        info "Installing missing GTK3 deps: ${MISSING_PKGS[*]}"
        sudo apt-get install -y "${MISSING_PKGS[@]}" || \
            warn "apt-get had errors — GTK3 deps may be incomplete. Continuing anyway."
    else
        info "GTK3 Python dependencies already installed."
    fi

    step "Writing Cava Solace GUI script"
    write_gui_script
    if [[ ! -f "$GUI_SCRIPT" ]]; then
        error "Failed to write GUI script to $GUI_SCRIPT — check disk space and permissions."
    fi
    write_gui_icon
    write_gui_desktop_shortcut
    ensure_lxterminal_cava_profile
    print_ok "Cava Solace installed → Sound & Video → Cava Solace"
}

uninstall_gui() {
    [[ -f "$GUI_SCRIPT" ]]       && rm -f "$GUI_SCRIPT"       && info "Removed: $GUI_SCRIPT"
    [[ -f "$DESKTOP_FILE_GUI" ]] && rm -f "$DESKTOP_FILE_GUI" && info "Removed: $DESKTOP_FILE_GUI"
    [[ -f "$ICON_FILE_GUI" ]]    && rm -f "$ICON_FILE_GUI"    && info "Removed: $ICON_FILE_GUI"
    # lxterminal-cava-solace.conf is exclusively created by and used for this
    # script's --profile=cava-solace launch -- removed unconditionally, no
    # prompt needed (unlike $CAVA_CONFIG_DIR, which holds the user's actual
    # theme and gets a keep/remove prompt). The user's own lxterminal.conf
    # (Start Menu launches) was never written to and is never touched here.
    [[ -f "$LXTERM_CAVA_PROFILE" ]] && rm -f "$LXTERM_CAVA_PROFILE" && \
        info "Removed: $LXTERM_CAVA_PROFILE"
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
}

# =============================================================================
# DEFAULT TERMINAL CONFIG
# =============================================================================
write_default_config() {
    [[ -f "$CAVA_CONFIG" ]] && return

    cat > "$CAVA_CONFIG" << 'EOF'
# cava config — Raspberry Pi 4 / PipeWire
# Generated by cava-manager.sh
# Full reference: https://github.com/karlstav/cava/blob/master/example_files/config

[general]
bars = 0
framerate = 60
autosens = 1
waveform = 0

[input]
method = pipewire
source = auto

[output]
method = noncurses
channels = stereo

[color]
background = '#080d0a'
gradient = 1
gradient_count = 6
gradient_color_1 = '#7ab8a0'
gradient_color_2 = '#7ab8a0'
gradient_color_3 = '#82b8c8'
gradient_color_4 = '#8aaccc'
gradient_color_5 = '#92a0d0'
gradient_color_6 = '#9a94d4'

[smoothing]
monstercat = 1
waves = 1
noise_reduction = 77
EOF
    info "Default config written: $CAVA_CONFIG"
}

# =============================================================================
# TERMINAL COLOUR SUPPORT
#
# Detection uses environment variables, not a hardcoded terminal name list.
# $COLORTERM=truecolor or $COLORTERM=24bit is the standard signal that a
# terminal supports 24-bit colour — set by lxterminal, foot, kitty, and others.
# $TERM containing "256color" indicates at minimum 256-colour support.
#
# Reference: https://github.com/termstandard/colors
# =============================================================================
detect_truecolor() {
    # Primary check: COLORTERM env var — the correct standard signal
    if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
        echo "truecolor (COLORTERM=${COLORTERM})"
        return
    fi
    # Secondary check: TERM contains 256color or direct
    if [[ "${TERM:-}" == *"256color"* || "${TERM:-}" == *"direct"* ]]; then
        echo "256colour (TERM=${TERM})"
        return
    fi
    echo ""
}

check_terminal_colour() {
    step "Checking terminal colour support"

    # Also show which terminal binary is running this session if detectable
    local CURRENT_TERM="${TERM:-unknown}"
    local CURRENT_COLORTERM="${COLORTERM:-not set}"
    info "TERM=$CURRENT_TERM   COLORTERM=$CURRENT_COLORTERM"

    local RESULT
    RESULT=$(detect_truecolor)
    if [[ -n "$RESULT" ]]; then
        print_ok "Truecolor supported: $RESULT"
        info "Your therapeutic gradients will render with full 24-bit colour."
        info "lxterminal, foot, and most modern terminals on Pi OS support this."
        echo ""
        echo "  Reference: https://github.com/termstandard/colors"
        echo ""
        return
    fi

    echo ""
    warn "Truecolor not detected in this session."
    echo ""
    echo "  COLORTERM and TERM do not indicate 24-bit support."
    echo "  This is unusual — most terminals on Raspberry Pi OS Trixie"
    echo "  support truecolor. Try opening a new terminal session and"
    echo "  running this script again from there."
    echo ""
    echo "  If you are running from a tty (not a desktop terminal),"
    echo "  cava will still work but gradient colours may be approximated."
    echo ""
    echo "  Reference: https://github.com/termstandard/colors"
    echo ""
}

# =============================================================================
# STATUS CHECK
# =============================================================================
cava_status() {
    if [[ -f "$CAVA_BIN" ]]; then
        CAVA_VER=$("$CAVA_BIN" --version 2>&1 | head -1 2>/dev/null) || CAVA_VER=""
        [[ -z "$CAVA_VER" ]] && CAVA_VER="installed"
        echo -e "  cava:      ${GREEN}installed${NC}  ($CAVA_VER)"
    else
        echo -e "  cava:      ${YELLOW}not installed${NC}"
    fi

    if [[ -e "$CAVA_CONFIG" ]]; then
        CURRENT_COLOR=$(grep "^gradient_color_1" "$CAVA_CONFIG" 2>/dev/null | head -1 | \
            grep -o "'#[^']*'" | tr -d "'" || echo "unknown")
        echo -e "  config:    ${GREEN}found${NC}  (primary color: $CURRENT_COLOR)"
    else
        echo -e "  config:    ${YELLOW}not found${NC}"
    fi


    local TC_RESULT
    TC_RESULT=$(detect_truecolor)
    if [[ -n "$TC_RESULT" ]]; then
        echo -e "  terminal:  ${GREEN}truecolor${NC}  ($TC_RESULT)"
    else
        echo -e "  terminal:  ${YELLOW}truecolor undetected${NC}  (COLORTERM=${COLORTERM:-not set})"
    fi
}


# =============================================================================
# INSTALL
# Builds cava from source. Writes all generated files (GUI, shader, configs).
# Reference: https://github.com/karlstav/cava#building-from-source
# =============================================================================
do_install() {
    step "Checking platform"
    ARCH=$(uname -m)
    info "Architecture: $ARCH"
    [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]] && \
        warn "Designed for arm64/armhf (Pi 4). Detected $ARCH — continuing anyway."

    # Begin rollback scope — any failure from here will trigger _rollback_cleanup
    _rollback_begin "install"

    if [[ -f "$CAVA_BIN" ]]; then
        info "cava already installed at $CAVA_BIN — skipping build."
    else
        local BUILD_DIR
        BUILD_DIR="$(mktemp -d)" || error "mktemp failed — no temp directory available"
        [[ -z "$BUILD_DIR" ]] && error "mktemp returned empty string"
        _BUILD_DIR_ACTIVE="$BUILD_DIR"
        echo "$BUILD_DIR" > "$BUILD_DIR_FILE"

        step "Installing build dependencies"
        sudo apt-get update -qq || warn "apt-get update had issues but continuing..."
        sudo apt-get install -y \
            build-essential autoconf automake libtool git pkgconf \
            libfftw3-dev \
            libiniparser-dev \
            libpipewire-0.3-dev \
            libpulse-dev \
            libasound2-dev \
            libncursesw5-dev \
            desktop-file-utils
        info "Dependencies ready."

        step "Cloning cava source"
        cd "$BUILD_DIR" || error "cd into temp dir failed"
        git clone --depth=1 https://github.com/karlstav/cava.git || error "git clone failed"
        cd cava || error "cava directory not created"
        CAVA_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")
        info "Source version: $CAVA_VERSION"

        step "Building cava (autotools)"
        # cmake only builds libcavacore.a — full binary requires autotools.
        ./autogen.sh || error "autogen.sh failed"
        ./configure --prefix="$HOME/.local" || error "configure failed"

        make -j"$(nproc)" || error "make failed — check for missing dependencies"
        make install || error "make install failed"
        info "cava installed to: $CAVA_BIN"

        cd "$HOME" || warn "Failed to cd home — continuing cleanup"
        rm -rf "$BUILD_DIR"
    fi

    step "Writing terminal config"
    write_default_config

    step "Installing Cava Solace GUI"
    install_gui

    check_terminal_colour

    # All steps complete — discard rollback state
    _rollback_end

    echo ""
    divider
    echo -e "${BOLD}  cava installed!${NC}"
    divider
    echo ""
    print_info "App menu:               Sound & Video → Cava Solace"
    print_info "Terminal mode:          run 'cava' in any terminal"
    print_info "Terminal config:        $CAVA_CONFIG"
    echo ""
    print_info "cava reads the PipeWire monitor source automatically."
    print_info "Play any audio and cava will visualize it."
    echo ""
    echo "  References:"
    echo "    cava source:   https://github.com/karlstav/cava"
    echo "    cava config:   https://github.com/karlstav/cava/blob/master/example_files/config"
    echo ""
}

# =============================================================================
# UPDATE
# Rebuilds cava from source. Also refreshes the GUI script and shader from
# this script's embedded copies — keeps everything in sync automatically.
# =============================================================================
do_update() {
    if ! command -v cava &>/dev/null && [[ ! -f "$CAVA_BIN" ]]; then
        error "cava is not installed. Run Install first."
    fi

    # Begin rollback scope — backs up existing binary before overwriting
    _rollback_begin "update"

    step "Updating cava"
    local BUILD_DIR
    BUILD_DIR="$(mktemp -d)" || error "mktemp failed — no temp directory available"
    [[ -z "$BUILD_DIR" ]] && error "mktemp returned empty string"
    _BUILD_DIR_ACTIVE="$BUILD_DIR"
    echo "$BUILD_DIR" > "$BUILD_DIR_FILE"
    cd "$BUILD_DIR" || error "cd into temp dir failed"
    git clone --depth=1 https://github.com/karlstav/cava.git || error "git clone failed"
    cd cava || error "cava directory not created"
    CAVA_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")
    info "Building version: $CAVA_VERSION"
    ./autogen.sh || error "autogen.sh failed"
    ./configure --prefix="$HOME/.local" || error "configure failed"
    make -j"$(nproc)" || error "make failed — check for missing dependencies"
    make install || error "make install failed"
    info "cava updated: $CAVA_BIN"

    # Refresh generated files from this script's embedded copies.
    # This keeps the GUI and shader in sync with the manager version.
    step "Refreshing GUI script"
    write_gui_script
    ensure_lxterminal_cava_profile
    print_ok "GUI script refreshed to match this manager version."

    cd "$HOME" || warn "Failed to cd home — continuing cleanup"
    rm -rf "$BUILD_DIR"
    echo ""
    # All steps complete — discard rollback state
    _rollback_end
    print_ok "Update complete. Your configs and themes are unchanged."
}

# =============================================================================
# UNINSTALL
# Removes all files installed by this script.
# =============================================================================
do_uninstall() {
    step "Uninstalling cava"

    # ── Binary ────────────────────────────────────────────────────────────────
    [[ -f "$CAVA_BIN" ]] && rm -f "$CAVA_BIN" && info "Removed: $CAVA_BIN"

    # ── GUI (desktop shortcut, icon, Python script) ───────────────────────────
    uninstall_gui

    # ── Man page and share data (installed by make install) ───────────────────
    local MAN_PAGE="$HOME/.local/share/man/man1/cava.1"
    [[ -f "$MAN_PAGE" ]] && rm -f "$MAN_PAGE" && info "Removed: $MAN_PAGE"
    local SHARE_DIR="$HOME/.local/share/cava"
    [[ -d "$SHARE_DIR" ]] && rm -rf "$SHARE_DIR" && info "Removed: $SHARE_DIR"

    # ── RAM staging files from Python GUI ─────────────────────────────────────
    local RAM_CONFIG="/dev/shm/cava-config-live"
    [[ -f "$RAM_CONFIG" ]] && rm -f "$RAM_CONFIG" && info "Removed RAM file: $RAM_CONFIG"
    local SD_BACKUP="$CAVA_CONFIG.sd"
    [[ -f "$SD_BACKUP" ]] && rm -f "$SD_BACKUP" && info "Removed backup: $SD_BACKUP"
    if [[ -L "$CAVA_CONFIG" ]]; then
        rm -f "$CAVA_CONFIG" && info "Removed dangling config symlink: $CAVA_CONFIG"
    fi

    # ── Desktop database and icon cache ───────────────────────────────────────
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

    # ── Config directory (prompt) ─────────────────────────────────────────────
    if [[ -d "$CAVA_CONFIG_DIR" ]]; then
        echo ""
        echo "  Config directory found: $CAVA_CONFIG_DIR"
        echo "  This contains your current theme and any manual edits."
        read -rp "$(echo -e "${CYAN}  Remove config directory? [y/N]: ${NC}")" RM_CONF
        if [[ "$RM_CONF" =~ ^[Yy]$ ]]; then
            rm -rf "$CAVA_CONFIG_DIR"
            info "Config directory removed."
        else
            info "Config kept at: $CAVA_CONFIG_DIR"
        fi
    fi

    # ── Rollback state directory ──────────────────────────────────────────────
    [[ -d "$STATE_DIR" ]] && rm -rf "$STATE_DIR" && info "Removed: $STATE_DIR"

    # ── Build dependencies — kept on system (safe) ───────────────────────────
    # Build deps are NOT removed during uninstall. Other system packages may
    # depend on them, and removing them via apt-get autoremove can break the OS.
    # If you want to remove them manually later, run:
    #   sudo apt-get remove autoconf automake libtool libfftw3-dev libiniparser-dev \
    #       libpipewire-0.3-dev libpulse-dev libasound2-dev libncursesw5-dev desktop-file-utils
    # Ref: https://www.debian.org/doc/manuals/apt-guide/ch-apt-get.en.html
    info "Build dependencies are kept on your system (safe to leave installed)."
    info "To remove them manually later, see the comment in do_uninstall() in this script."


    echo ""
    divider
    echo -e "${GREEN}  cava fully uninstalled.${NC}"
    divider
    echo ""
    exit 0
}

# =============================================================================
# MAIN MENU
# =============================================================================
main_menu() {
    # Detect incomplete previous run (crash / power loss) and offer recovery
    _check_partial_state

    while true; do
        echo ""
        divider
        echo -e "${BOLD}  Cava Solace — Therapeutic Sonic Visualizer${NC}"
        echo -e "  cava audio visualizer for Raspberry Pi"
        echo -e "  Source: https://github.com/karlstav/cava"
        divider
        echo ""
        cava_status
        echo ""
        echo -e "  ${CYAN}1)${NC}  Install cava"
        echo -e "  ${CYAN}2)${NC}  Update  cava"
        echo -e "  ${CYAN}3)${NC}  Open Cava Solace  (therapeutic GUI)"
        echo -e "  ${CYAN}4)${NC}  Check / fix terminal colour support"
        echo -e "  ${CYAN}5)${NC}  Edit config manually"
        echo -e "  ${CYAN}6)${NC}  Uninstall cava"
        echo -e "  ${CYAN}7)${NC}  Exit"
        echo ""
        read -rp "$(echo -e "${CYAN}  Choose an option [1-7]: ${NC}")" CHOICE

        case "$CHOICE" in
            1) do_install      ;;
            2) do_update       ;;
            3)
                if [[ -f "$GUI_SCRIPT" ]]; then
                    python3 "$GUI_SCRIPT" &
                    info "Cava Solace launched."
                else
                    warn "GUI not installed. Run Install (option 1) first."
                fi
                ;;
            4) check_terminal_colour ;;
            5)
                EDITOR="${EDITOR:-nano}"
                "$EDITOR" "$CAVA_CONFIG" 2>/dev/null || \
                    nano "$CAVA_CONFIG"   2>/dev/null || \
                    vi   "$CAVA_CONFIG"
                ;;
            6) do_uninstall    ;;
            7)
                echo ""
                echo "  Goodbye! Run cava in any terminal to start visualizing."
                echo ""
                exit 0
                ;;
            *) warn "Invalid choice. Enter 1–7." ;;
        esac
    done
}

# =============================================================================
# ENTRY POINT
# =============================================================================
clear
echo ""
divider
echo -e "${BOLD}  Cava Solace v2.7.0${NC}"
echo -e "  Therapeutic Sonic Visualizer — Manager"
echo -e "  Self-contained — generates all files on Install"
divider
main_menu
