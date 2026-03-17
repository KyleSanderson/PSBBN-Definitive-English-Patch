#!/bin/bash
# build-ps2-tools.sh
#
# Builds Neutrino and NHDDL from source, then installs the resulting binaries
# into the distribution asset directories so the installer scripts pick them up.
#
# Build modes (auto-detected):
#   Native  — PS2DEV/PS2SDK env vars point to an installed PS2 toolchain.
#             The toolchain from https://github.com/ps2dev/ps2dev/releases can
#             be extracted to ~/ps2dev and this script will find it automatically.
#   Docker  — Falls back to Docker/Podman images if no native toolchain is found.
#             Neutrino: ps2max/dev:v20260228
#             NHDDL:    ghcr.io/ps2homebrew/ps2homebrew:main
#
# Usage:
#   ./build-ps2-tools.sh            # build both
#   ./build-ps2-tools.sh neutrino   # build Neutrino only
#   ./build-ps2-tools.sh nhddl      # build NHDDL only
#
# Source repositories (override with env vars or edit the defaults below):
#   NEUTRINO_REPO / NEUTRINO_BRANCH
#   NHDDL_REPO    / NHDDL_BRANCH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source repository configuration — override via env vars or edit here
# ---------------------------------------------------------------------------
NEUTRINO_REPO="${NEUTRINO_REPO:-https://github.com/kylesanderson/neutrino}"
NEUTRINO_BRANCH="${NEUTRINO_BRANCH:-cheats}"

NHDDL_REPO="${NHDDL_REPO:-https://github.com/kylesanderson/nhddl}"
NHDDL_BRANCH="${NHDDL_BRANCH:-cheats}"

NEUTRINO_SRC="$SCRIPT_DIR/neutrino-src"
NHDDL_SRC="$SCRIPT_DIR/nhddl-src"

NEUTRINO_ASSETS="$SCRIPT_DIR/scripts/assets/neutrino"
NHDDL_ASSETS="$SCRIPT_DIR/scripts/assets/NHDDL"

NEUTRINO_IMAGE="ps2max/dev:v20260228"
NHDDL_IMAGE="ghcr.io/ps2homebrew/ps2homebrew:main"

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# NixOS toolchain compatibility
# ---------------------------------------------------------------------------
#
# On NixOS the default ELF interpreter (/lib64/ld-linux-x86-64.so.2) is the
# nix-ld shim. GCC's cc1 calls dlopen(NULL) to inspect its own image; the shim
# returns NULL for that call, which triggers "internal compiler error: Segfault".
#
# Fix: patchelf every x86-64 dynamic executable in the PS2 toolchain once so it
# uses the real glibc interpreter and carries an RPATH for its companion libs.
# After patching, no LD_LIBRARY_PATH is needed (and setting it would break things
# by mixing glibc versions and causing bash subprocess segfaults).
#
# The function is a no-op on standard Linux where the interpreter is not nix-ld.

_get_elf_interp() {
    readelf -l "$1" 2>/dev/null \
        | awk '/interpreter/ {gsub(/[\[\]]/,"",$2); print $2; exit}'
}

_patch_nixos_toolchain() {
    local patchelf_bin glibc_interp glibc_dir mpc_dir rpath count=0 cur_interp f

    patchelf_bin=$(command -v patchelf 2>/dev/null || \
                   find /nix/store -maxdepth 4 -path "*/patchelf*/bin/patchelf" \
                        -type f ! -path "*.drv*" 2>/dev/null | head -1)
    [[ -n "$patchelf_bin" ]] || { echo "WARNING: patchelf not found; skipping." >&2; return 1; }

    # Find the real glibc interpreter (highest version; exclude nix-ld shim)
    glibc_interp=$(find /nix/store -maxdepth 4 -name "ld-linux-x86-64.so.2" \
                        ! -path "*.drv*" ! -path "*nix-ld*" 2>/dev/null \
                        | sort -r | head -1)
    [[ -n "$glibc_interp" ]] || { echo "WARNING: real glibc not found; skipping." >&2; return 1; }
    glibc_dir=$(dirname "$glibc_interp")

    # GCC companion libs (libmpc, libmpfr, libgmp) — put in RPATH
    mpc_dir=$(find /nix/store -maxdepth 4 -name "libmpc.so.3" \
                   ! -path "*.drv*" 2>/dev/null | head -1 | xargs -r dirname)
    rpath="${mpc_dir:+$mpc_dir:}$glibc_dir"

    echo "    Interpreter: $glibc_interp"
    echo "    RPATH:       $rpath"

    local -a scan_dirs=(
        "$PS2DEV/bin"
        "$PS2DEV/ee/bin"   "$PS2DEV/ee/libexec"
        "$PS2DEV/iop/bin"  "$PS2DEV/iop/libexec"
        "$PS2SDK/bin"
    )
    for dir in "${scan_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            cur_interp=$(_get_elf_interp "$f")
            [[ "$cur_interp" == *nix-ld* ]] || continue
            "$patchelf_bin" --set-interpreter "$glibc_interp" --set-rpath "$rpath" "$f" 2>/dev/null \
                && count=$((count + 1)) || true
        done < <(find "$dir" -type f -print0 2>/dev/null)
    done
    echo "    Patched $count toolchain binaries."
}

_maybe_patch_nixos_toolchain() {
    [[ -L /lib64/ld-linux-x86-64.so.2 ]] || return 0
    [[ "$(readlink /lib64/ld-linux-x86-64.so.2)" == *nix-ld* ]] || return 0
    local sample_bin="$PS2DEV/iop/bin/mipsel-none-elf-gcc"
    [[ -f "$sample_bin" ]] || return 0
    [[ "$(_get_elf_interp "$sample_bin")" == *nix-ld* ]] || return 0  # already patched
    echo "    NixOS detected — patching toolchain for ELF interpreter compatibility..."
    _patch_nixos_toolchain
}

# ---------------------------------------------------------------------------
# Toolchain detection
# ---------------------------------------------------------------------------

# Auto-detect PS2DEV location if not already set
if [[ -z "${PS2DEV:-}" ]]; then
    for candidate in "$HOME/ps2dev" /usr/local/ps2dev /opt/ps2dev; do
        if [[ -x "$candidate/ee/bin/mips64r5900el-ps2-elf-gcc" ]]; then
            export PS2DEV="$candidate"
            break
        fi
    done
fi

if [[ -n "${PS2DEV:-}" ]]; then
    export PS2SDK="${PS2SDK:-$PS2DEV/ps2sdk}"
    # $PS2SDK/bin contains iopfixup and other SDK host tools required by the build
    export PATH="$PS2DEV/bin:$PS2DEV/ee/bin:$PS2DEV/iop/bin:$PS2SDK/bin:$PATH"

    # IMPORTANT: do NOT set LD_LIBRARY_PATH. On NixOS, mixing the toolchain's
    # glibc with the system shell's glibc via LD_LIBRARY_PATH causes bash
    # subprocess segfaults. The toolchain is made self-sufficient via patchelf.
    unset LD_LIBRARY_PATH
    _maybe_patch_nixos_toolchain

    BUILD_MODE="native"
else
    BUILD_MODE="docker"
    CONTAINER_RUNTIME=""
    for runtime in docker podman; do
        if command -v "$runtime" &>/dev/null; then
            CONTAINER_RUNTIME="$runtime"
            break
        fi
    done
    [[ -n "$CONTAINER_RUNTIME" ]] \
        || die "No PS2 toolchain found and no container runtime (docker/podman) available.
Install the PS2 toolchain from https://github.com/ps2dev/ps2dev/releases
or install Docker/Podman to use container-based builds."
fi

echo "Build mode: $BUILD_MODE${BUILD_MODE:+ (PS2DEV=$PS2DEV)}"

# ---------------------------------------------------------------------------
# Build functions
# ---------------------------------------------------------------------------

_install_neutrino_assets() {
    [[ -f "$NEUTRINO_SRC/ee/loader/neutrino.elf" ]] \
        || die "neutrino.elf not found after build — check output above."

    cp "$NEUTRINO_SRC/ee/loader/neutrino.elf"  "$NEUTRINO_ASSETS/neutrino.elf"
    cp "$NEUTRINO_SRC/ee/loader/version.txt"   "$NEUTRINO_ASSETS/version.txt"

    # Replace modules directory wholesale so stale IRXs don't linger
    rm -rf "$NEUTRINO_ASSETS/modules"
    cp -r  "$NEUTRINO_SRC/ee/loader/modules"   "$NEUTRINO_ASSETS/modules"

    echo "    neutrino.elf -> $NEUTRINO_ASSETS/neutrino.elf"
    echo "    modules/     -> $NEUTRINO_ASSETS/modules/"
    echo "    version.txt  -> $NEUTRINO_ASSETS/version.txt"
}

_install_nhddl_assets() {
    # The output ELF includes the git version in its name; exclude _unc (unpacked) variant
    local nhddl_elf
    nhddl_elf=$(find "$NHDDL_SRC" -maxdepth 1 -name "nhddl-*.elf" \
                     ! -name "*_unc.elf" | sort | tail -n1)
    [[ -n "$nhddl_elf" ]] \
        || die "No nhddl-*.elf found after build — check output above."

    cp "$nhddl_elf" "$NHDDL_ASSETS/nhddl.elf"
    echo "    $(basename "$nhddl_elf") -> $NHDDL_ASSETS/nhddl.elf"
}

build_neutrino() {
    echo
    echo "==> Building Neutrino..."
    if [[ ! -d "$NEUTRINO_SRC" ]]; then
        echo "    Cloning $NEUTRINO_REPO (branch: $NEUTRINO_BRANCH)..."
        git clone --depth=1 --branch "$NEUTRINO_BRANCH" "$NEUTRINO_REPO" "$NEUTRINO_SRC"
    fi

    if [[ "$BUILD_MODE" == "native" ]]; then
        # mmcefhi.irx is not included in ps2sdk releases; copy it from the
        # distribution assets (already in git) so the build can find it.
        local mmce_dst="$PS2SDK/iop/irx/mmcefhi.irx"
        if [[ ! -f "$mmce_dst" ]]; then
            local mmce_src="$NEUTRINO_ASSETS/modules/mmcefhi.irx"
            [[ -f "$mmce_src" ]] \
                || die "mmcefhi.irx not found at $mmce_src — cannot build Neutrino."
            echo "    Copying mmcefhi.irx to ps2sdk..."
            cp "$mmce_src" "$mmce_dst"
        fi
        ( cd "$NEUTRINO_SRC"
          make all copy    # builds IOP modules and copies all IRX to ee/loader/modules/
          make -C ee/loader  # builds neutrino.elf and version.txt
        )
    else
        "$CONTAINER_RUNTIME" run --rm \
            --user "$(id -u):$(id -g)" \
            -v "$NEUTRINO_SRC:/src" -w /src \
            "$NEUTRINO_IMAGE" \
            bash -c "git config --global --add safe.directory /src &&
                     make all copy &&
                     make -C ee/loader"
    fi

    echo
    echo "==> Installing Neutrino assets..."
    _install_neutrino_assets
    echo "    Neutrino build complete."
}

build_nhddl() {
    echo
    echo "==> Building NHDDL..."
    if [[ ! -d "$NHDDL_SRC" ]]; then
        echo "    Cloning $NHDDL_REPO (branch: $NHDDL_BRANCH)..."
        git clone --depth=1 --branch "$NHDDL_BRANCH" "$NHDDL_REPO" "$NHDDL_SRC"
    fi

    if [[ "$BUILD_MODE" == "native" ]]; then
        ( cd "$NHDDL_SRC"; make )
    else
        "$CONTAINER_RUNTIME" run --rm \
            --user "$(id -u):$(id -g)" \
            -v "$NHDDL_SRC:/src" -w /src \
            "$NHDDL_IMAGE" \
            bash -c "git config --global --add safe.directory /src && make"
    fi

    echo
    echo "==> Installing NHDDL assets..."
    _install_nhddl_assets
    echo "    NHDDL build complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

TARGET="${1:-both}"
case "$TARGET" in
    neutrino) build_neutrino ;;
    nhddl)    build_nhddl ;;
    both|"")  build_neutrino; build_nhddl ;;
    *)
        echo "Usage: $0 [neutrino|nhddl|both]"
        exit 1
        ;;
esac

echo
echo "==> All done. Run the Game-Installer to test with your PS2 drive."
