#!/bin/bash
#
# One-shot setup of a TRSE development environment on Debian/Ubuntu.
#
# Builds TRSE from source, creates the directory links the application expects
# next to its binary, installs a trse.ini pointing at the locally installed
# assemblers and emulators, and registers a desktop launcher.
#
# Usage:  ./setup_linux.sh [-j N] [--no-apt] [--no-roms] [--no-desktop]
#
set -euo pipefail

TRSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(nproc)"
DO_APT=1
DO_ROMS=1
DO_DESKTOP=1

while [ $# -gt 0 ]; do
    case "$1" in
        -j) JOBS="$2"; shift 2 ;;
        --no-apt) DO_APT=0; shift ;;
        --no-roms) DO_ROMS=0; shift ;;
        --no-desktop) DO_DESKTOP=0; shift ;;
        -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# ---------------------------------------------------------------- dependencies
if [ $DO_APT -eq 1 ]; then
    echo "==> Installing build dependencies and retro tooling"
    $SUDO apt-get update
    # Qt5 + OpenGL headers are what TRSE.pro needs to build.
    $SUDO apt-get install -y qtbase5-dev qt5-qmake qtdeclarative5-dev \
                             mesa-common-dev libgl1-mesa-dev
    # vice provides x64sc/c1541/petcat, the rest is used by the non-6502 targets.
    $SUDO apt-get install -y vice lz4 nasm dosbox xvfb
fi

# --------------------------------------------------------------------- compile
echo "==> Building TRSE with $JOBS jobs"
cd "$TRSE_DIR"
qmake TRSE.pro
make -j"$JOBS"

# TRSE resolves units/ and themes/ as applicationDirPath() + "/../", so the
# binary has to live one directory below the repository root. applicationDirPath
# resolves symlinks, so this needs to be a real copy - re-run this script (or
# repeat the cp) after every rebuild.
echo "==> Installing the binary into bin/"
mkdir -p bin
cp trse bin/trse

# ------------------------------------------------------------ runtime symlinks
# TRSE chdir()s to the directory of its own binary and looks these up relative
# to it, so they have to sit next to the freshly built ./trse.
echo "==> Linking themes / tutorials / project_templates"
ln -sfn Publish/source/themes themes
ln -sfn Publish/tutorials tutorials
ln -sfn Publish/project_templates project_templates

# ---------------------------------------------------------------- settings ini
# QStandardPaths::AppDataLocation, i.e. where TRSE and "trse -cli" read trse.ini.
SETTINGS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/TRSE"
TRSE_INI="$SETTINGS_DIR/trse.ini"
echo "==> Updating $TRSE_INI"
mkdir -p "$SETTINGS_DIR"
if [ ! -e "$TRSE_INI" ]; then
    cp Publish/publish_linux/trse.ini "$TRSE_INI"
fi

# Point a tool key at the local binary, but only when the value currently in the
# file is unusable: the shipped trse.ini uses "0" as the placeholder, and a path
# left over from another machine no longer exists. A value that does resolve to
# an executable is something the user picked deliberately, so it is kept.
set_tool() {
    local key="$1" bin="$2" path current
    path="$(command -v "$bin" || true)"
    [ -n "$path" ] || return 0
    current="$(sed -n "s|^$key *= *||p" "$TRSE_INI" | head -1)"
    [ -n "$current" ] && [ -x "$current" ] && return 0
    if grep -q "^$key *=" "$TRSE_INI"; then
        sed -i "s|^$key *=.*|$key = $path|" "$TRSE_INI"
    else
        printf '%s = %s\n' "$key" "$path" >> "$TRSE_INI"
    fi
    echo "    $key = $path"
}
set_tool emulator         x64sc
set_tool vic20_emulator   xvic
set_tool c128_emulator    x128
set_tool plus4_emulator   xplus4
set_tool pet_emulator     xpet
set_tool c1541            c1541
set_tool nasm             nasm
set_tool dosbox           dosbox
set_tool lz4              lz4

# ------------------------------------------------------------------ vice roms
# Debian/Ubuntu ship vice without the Commodore ROM images, so x64sc aborts with
# "Couldn't load kernal ROM" on startup. The upstream release tarball contains
# them; this mirrors what .github/workflows/linux.yml does for the CI runners.
# The ROM file names differ between VICE releases (3.5 has "kernal", 3.7 has
# "kernal-901227-03.bin"), so the tarball has to match the installed emulator.
if [ $DO_ROMS -eq 1 ] && command -v x64sc >/dev/null; then
    if ls "$HOME"/.config/vice/C64/kernal* /usr/share/vice/C64/kernal* >/dev/null 2>&1; then
        echo "==> VICE ROM images already present"
    else
        VICE_VER="$(x64sc --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
        echo "==> Fetching VICE $VICE_VER ROM images"
        tmp="$(mktemp -d)"
        if wget -q --tries=3 -O "$tmp/vice.tar.gz" \
            "https://sourceforge.net/projects/vice-emu/files/releases/vice-$VICE_VER.tar.gz/download" \
            && tar -xzf "$tmp/vice.tar.gz" -C "$tmp" "vice-$VICE_VER/data"; then
            mkdir -p "$HOME/.config/vice"
            cp -r "$tmp/vice-$VICE_VER/data/"* "$HOME/.config/vice/"
        else
            echo "    could not fetch ROMs for VICE $VICE_VER - install them manually"
            echo "    into ~/.config/vice/ if you want to run the emulator"
        fi
        rm -rf "$tmp"
    fi
fi

# ------------------------------------------------------------- desktop launcher
# Registers TRSE with the desktop environment so it shows up in the application
# menu and can be pinned to the dock/dash. StartupWMClass has to match the
# WM_CLASS the running window reports ("trse", "TRSE"), otherwise the launched
# window is shown as a second, unnamed entry instead of lighting up this one.
if [ $DO_DESKTOP -eq 1 ]; then
    APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/128x128/apps"
    echo "==> Installing desktop launcher into $APPS_DIR"
    install -Dm644 resources/images/trse_icon.png "$ICON_DIR/trse.png"
    mkdir -p "$APPS_DIR"
    cat > "$APPS_DIR/trse.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=TRSE
GenericName=Retro Development IDE
Comment=Turbo Rascal Syntax Error - development suite for 8 and 16 bit systems
Exec=$TRSE_DIR/bin/trse %f
Path=$TRSE_DIR/bin
Icon=trse
Terminal=false
Categories=Development;IDE;
StartupWMClass=TRSE
Keywords=c64;commodore;amiga;retro;assembler;pascal;
EOF
    # Refresh the caches, so the entry appears without a re-login. Both tools are
    # optional and their absence only delays when the launcher shows up.
    command -v update-desktop-database >/dev/null && \
        update-desktop-database "$APPS_DIR" 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null && \
        gtk-update-icon-cache -qtf "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true
fi

echo
echo "Done. Start the IDE with:        $TRSE_DIR/bin/trse"
echo "                                 or from the application menu / dock"
echo "Compile from the command line:   $TRSE_DIR/bin/trse -cli op=project \\"
echo "                                     project=<project>.trse input_file=<source>.ras"
