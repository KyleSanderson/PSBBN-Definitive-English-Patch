#!/bin/bash
# build-ps2-tools.sh
#
# Builds Neutrino and NHDDL from source and installs binaries into
# scripts/assets/ so the PSBBN installer picks them up.
#
# Build modes (resolved in order):
#   1. Native    — uses a ps2dev toolchain already on PATH / in PS2DEV.
#                  If none is found on Linux x86_64 or macOS, the latest release
#                  is downloaded from github.com/ps2dev/ps2dev automatically.
#   2. Container — uses Docker/Podman with the exact same images as each
#                  project's CI (mirrors .github/workflows in both repos):
#                    Neutrino: ps2max/dev:v20260228
#                    NHDDL:    ghcr.io/ps2homebrew/ps2homebrew:main
#                  Forced when BUILD_MODE=docker, or when no native toolchain
#                  release exists for the current platform (e.g. Linux arm64).
#
# Usage:
#   ./build-ps2-tools.sh            # build both
#   ./build-ps2-tools.sh neutrino   # Neutrino only
#   ./build-ps2-tools.sh nhddl      # NHDDL only
#   ./build-ps2-tools.sh clean      # remove source trees (triggers re-clone)
#
# Environment overrides:
#   NEUTRINO_REPO / NEUTRINO_BRANCH  — source repo/branch
#   NHDDL_REPO    / NHDDL_BRANCH
#   NEUTRINO_IMAGE / NHDDL_IMAGE     — container images
#   BUILD_MODE=docker                — force container builds
#   CLEAN=1                          — wipe + re-clone source trees before build
#   PS2DEV=/path/to/ps2dev           — use a specific toolchain location

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configuration — override via env vars or edit the defaults here
# ---------------------------------------------------------------------------

# Source repos / branches
NEUTRINO_REPO="${NEUTRINO_REPO:-https://github.com/kylesanderson/neutrino}"
NEUTRINO_BRANCH="${NEUTRINO_BRANCH:-cheats}"

NHDDL_REPO="${NHDDL_REPO:-https://github.com/kylesanderson/nhddl}"
NHDDL_BRANCH="${NHDDL_BRANCH:-cheats}"

# Container images — must match the project CI workflows
# Neutrino: .github/workflows/compile.yml  → container: ps2max/dev:v20260228
# NHDDL:    .github/workflows/build.yml    → container: ghcr.io/ps2homebrew/ps2homebrew:main
NEUTRINO_IMAGE="${NEUTRINO_IMAGE:-ps2max/dev:v20260228}"
NHDDL_IMAGE="${NHDDL_IMAGE:-ghcr.io/ps2homebrew/ps2homebrew:main}"

NEUTRINO_SRC="$SCRIPT_DIR/neutrino-src"
NHDDL_SRC="$SCRIPT_DIR/nhddl-src"

NEUTRINO_ASSETS="$SCRIPT_DIR/scripts/assets/neutrino"
NHDDL_ASSETS="$SCRIPT_DIR/scripts/assets/NHDDL"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "    $*"; }

# ---------------------------------------------------------------------------
# Toolchain auto-install
# ---------------------------------------------------------------------------

# Returns the GitHub release asset name for the current platform, or empty
# string if no pre-built release exists (e.g. Linux arm64).
_platform_ps2dev_asset() {
    case "$(uname -s)" in
        Linux)  [[ "$(uname -m)" == "x86_64" ]] && echo "ps2dev-ubuntu-latest.tar.gz" || echo "" ;;
        Darwin) echo "ps2dev-macos-latest.tar.gz" ;;
        *)      echo "" ;;
    esac
}

# Download and install the latest ps2dev release to $HOME/ps2dev.
_install_toolchain() {
    local asset
    asset=$(_platform_ps2dev_asset)
    [[ -n "$asset" ]] \
        || die "No pre-built ps2dev release for $(uname -s)/$(uname -m). Use BUILD_MODE=docker."

    echo "==> Installing PS2 toolchain..."
    local tag
    tag=$(curl -sf "https://api.github.com/repos/ps2dev/ps2dev/releases/latest" \
          | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" \
          2>/dev/null) || tag="latest"
    local dest="$HOME/ps2dev"
    local url="https://github.com/ps2dev/ps2dev/releases/download/${tag}/${asset}"
    local tmp
    tmp=$(mktemp "/tmp/ps2dev-XXXXXX.tar.gz")
    trap 'rm -f "$tmp"' EXIT

    info "Release : $tag  ($asset)"
    info "Target  : $dest"
    info "URL     : $url"

    # Download to a temp file so we can verify integrity before extracting.
    # The toolchain tarball is ~400 MB; use --retry so transient failures recover.
    if ! curl -fL --retry 3 --retry-delay 5 --progress-bar "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "Download failed. Check your internet connection and retry."
    fi

    # Sanity check: must be a valid gzip and at least 50 MB
    local size
    size=$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)
    if (( size < 50000000 )); then
        rm -f "$tmp"
        die "Downloaded archive is only ${size} bytes — likely incomplete. Retry."
    fi
    if ! file "$tmp" 2>/dev/null | grep -q "gzip\|compressed"; then
        # 'file' may not be available everywhere; skip check if so
        :
    fi

    # Remove any previous partial install before extracting
    # (tarball has a top-level ps2dev/ dir → extracts to dest automatically)
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    tar -xzf "$tmp" -C "$(dirname "$dest")"
    rm -f "$tmp"
    trap - EXIT

    [[ -x "$dest/ee/bin/mips64r5900el-ps2-elf-gcc" ]] \
        || die "Toolchain extraction failed — the archive may be corrupt. Delete $dest and retry."
    info "Installed: $dest"
}

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
# Toolchain detection + auto-install
# ---------------------------------------------------------------------------

_setup_native_toolchain() {
    local dir="$1"
    export PS2DEV="$dir"
    export PS2SDK="${PS2SDK:-$PS2DEV/ps2sdk}"
    # $PS2SDK/bin has iopfixup and other host tools required at build time
    export PATH="$PS2DEV/bin:$PS2DEV/ee/bin:$PS2DEV/iop/bin:$PS2SDK/bin:$PATH"
    # NEVER set LD_LIBRARY_PATH: on NixOS mixing the toolchain glibc (2.42) with
    # the shell glibc (2.40) via LD_LIBRARY_PATH causes bash subprocess crashes.
    # The toolchain is made self-sufficient by patchelf instead.
    unset LD_LIBRARY_PATH
    _maybe_patch_nixos_toolchain
}

BUILD_MODE="${BUILD_MODE:-}"
CONTAINER_RUNTIME=""

if [[ "$BUILD_MODE" != "docker" ]]; then
    # 1. Honour an explicitly-set PS2DEV
    if [[ -n "${PS2DEV:-}" ]] && [[ -x "${PS2DEV}/ee/bin/mips64r5900el-ps2-elf-gcc" ]]; then
        _setup_native_toolchain "$PS2DEV"
        BUILD_MODE="native"
    else
        # 2. Scan well-known locations
        for _candidate in "$HOME/ps2dev" /usr/local/ps2dev /opt/ps2dev; do
            if [[ -x "$_candidate/ee/bin/mips64r5900el-ps2-elf-gcc" ]]; then
                _setup_native_toolchain "$_candidate"
                BUILD_MODE="native"
                break
            fi
        done
    fi

    # 3. Auto-install from GitHub releases if nothing found
    if [[ "$BUILD_MODE" != "native" ]]; then
        if [[ -n "$(_platform_ps2dev_asset)" ]]; then
            _install_toolchain
            _setup_native_toolchain "$HOME/ps2dev"
            BUILD_MODE="native"
        fi
    fi
fi

# 4. Fall back to Docker/Podman
if [[ "$BUILD_MODE" != "native" ]]; then
    BUILD_MODE="docker"
    for _runtime in docker podman; do
        if command -v "$_runtime" &>/dev/null; then
            CONTAINER_RUNTIME="$_runtime"
            break
        fi
    done
    if [[ -z "$CONTAINER_RUNTIME" ]]; then
        if [[ -n "$(_platform_ps2dev_asset)" ]]; then
            die "Toolchain install failed and no Docker/Podman found.\nCheck your internet connection or install Docker/Podman."
        else
            die "No PS2 toolchain found and no Docker/Podman available.\nInstall Docker or Podman, then re-run this script."
        fi
    fi
fi

if [[ "$BUILD_MODE" == "native" ]]; then
    echo "Build mode: native  (PS2DEV=$PS2DEV)"
else
    echo "Build mode: docker  ($CONTAINER_RUNTIME)"
fi

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

_clone_or_clean() {
    local src="$1" repo="$2" branch="$3"
    if [[ "${CLEAN:-0}" == "1" ]] && [[ -d "$src" ]]; then
        echo "    Removing $src (CLEAN=1)..."
        rm -rf "$src"
    fi
    if [[ ! -d "$src" ]]; then
        echo "    Cloning $repo  (branch: $branch)..."
        git clone --depth=1 --branch "$branch" "$repo" "$src"
    fi
}

build_neutrino() {
    echo
    echo "==> Building Neutrino ($NEUTRINO_REPO @ $NEUTRINO_BRANCH)..."
    _clone_or_clean "$NEUTRINO_SRC" "$NEUTRINO_REPO" "$NEUTRINO_BRANCH"

    if [[ "$BUILD_MODE" == "native" ]]; then
        # mmcefhi.irx is not in ps2sdk releases; copy from distribution assets.
        local mmce_dst="$PS2SDK/iop/irx/mmcefhi.irx"
        if [[ ! -f "$mmce_dst" ]]; then
            local mmce_src="$NEUTRINO_ASSETS/modules/mmcefhi.irx"
            [[ -f "$mmce_src" ]] \
                || die "mmcefhi.irx not found at $mmce_src — cannot build Neutrino."
            info "Copying mmcefhi.irx → ps2sdk..."
            cp "$mmce_src" "$mmce_dst"
        fi
        ( cd "$NEUTRINO_SRC"
          # 'all' builds every IOP module + ee/loader (neutrino.elf + version.txt)
          # 'copy' assembles all IRX into ee/loader/modules/
          make all copy
        )
    else
        # Mirror the CI workflow exactly:
        #   .github/workflows/compile.yml → make clean all release
        # 'release' calls 'all copy' then packages into releases/*.7z
        # After it runs, neutrino.elf + modules/ are still in ee/loader/
        "$CONTAINER_RUNTIME" run --rm \
            -v "$NEUTRINO_SRC:/src" -w /src \
            "$NEUTRINO_IMAGE" \
            bash -c "git config --global --add safe.directory /src && \
                     make clean all release"
    fi

    echo
    echo "==> Installing Neutrino assets..."
    _install_neutrino_assets
    echo "    Neutrino build complete."
}

build_nhddl() {
    echo
    echo "==> Building NHDDL ($NHDDL_REPO @ $NHDDL_BRANCH)..."
    _clone_or_clean "$NHDDL_SRC" "$NHDDL_REPO" "$NHDDL_BRANCH"

    if [[ "$BUILD_MODE" == "native" ]]; then
        ( cd "$NHDDL_SRC"; make )
    else
        # Mirror the CI workflow:
        #   .github/workflows/build.yml → git fetch --unshallow && make
        "$CONTAINER_RUNTIME" run --rm \
            -v "$NHDDL_SRC:/src" -w /src \
            "$NHDDL_IMAGE" \
            bash -c "git config --global --add safe.directory /src && \
                     git fetch --prune --unshallow 2>/dev/null || true && \
                     make"
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
    clean)
        echo "==> Removing source trees..."
        rm -rf "$NEUTRINO_SRC" "$NHDDL_SRC"
        echo "    Done. Run the script again to re-clone and rebuild."
        exit 0
        ;;
    *)
        echo "Usage: $0 [neutrino|nhddl|both|clean]"
        exit 1
        ;;
esac

echo
echo "==> All done. Run the Game-Installer to test with your PS2 drive."
