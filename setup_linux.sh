#!/bin/bash
#
# One-shot setup of a TRSE development environment on Debian/Ubuntu.
#
# Builds TRSE from source, creates the directory links the application expects
# next to its binary and installs a trse.ini pointing at the locally installed
# assemblers and emulators.
#
# Usage:  ./setup_linux.sh [-j N] [--no-apt] [--no-roms]
#
set -euo pipefail

TRSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(nproc)"
DO_APT=1
DO_ROMS=1

while [ $# -gt 0 ]; do
    case "$1" in
        -j) JOBS="$2"; shift 2 ;;
        --no-apt) DO_APT=0; shift ;;
        --no-roms) DO_ROMS=0; shift ;;
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
echo "==> Installing $SETTINGS_DIR/trse.ini"
mkdir -p "$SETTINGS_DIR"
if [ -e "$SETTINGS_DIR/trse.ini" ]; then
    echo "    already present, leaving it untouched"
else
    cp Publish/publish_linux/trse.ini "$SETTINGS_DIR/trse.ini"
    # Replace the placeholder tool paths with whatever is installed here.
    set_tool() {
        local key="$1" bin="$2" path
        path="$(command -v "$bin" || true)"
        [ -n "$path" ] && sed -i "s,^$key =.*,$key = $path," "$SETTINGS_DIR/trse.ini"
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
fi

# ------------------------------------------------------------------ vice roms
# Ubuntu ships vice without the Commodore ROM images, so x64sc refuses to boot.
# The upstream release tarball contains them; this mirrors what .github/workflows
# /linux.yml does for the CI runners.
if [ $DO_ROMS -eq 1 ] && [ ! -f "$HOME/.config/vice/C64/kernal" ]; then
    echo "==> Fetching VICE ROM images"
    tmp="$(mktemp -d)"
    if wget -q --tries=3 -O "$tmp/vice.tar.gz" \
        "https://sourceforge.net/projects/vice-emu/files/releases/vice-3.5.tar.gz/download"; then
        tar -xzf "$tmp/vice.tar.gz" -C "$tmp" vice-3.5/data
        mkdir -p "$HOME/.config/vice"
        cp -r "$tmp"/vice-3.5/data/* "$HOME/.config/vice/"
    else
        echo "    download failed - install the ROMs manually if you want to use VICE"
    fi
    rm -rf "$tmp"
fi

echo
echo "Done. Start the IDE with:        $TRSE_DIR/trse"
echo "Compile from the command line:   $TRSE_DIR/trse -cli op=project \\"
echo "                                     project=<project>.trse input_file=<source>.ras"
