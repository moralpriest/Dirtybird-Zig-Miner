#!/usr/bin/env bash
#
# Dirtybird Zig Miner -- Termux (Android) setup & launcher.
#
# On Android/Termux: installs Zig, clones the repo, and builds from source
# (required because the pre-built arm64 release is non-PIE, which Android rejects).
# On other platforms: downloads the latest pre-built release.
#
# Prompts for pool/wallet, sets threads to nproc-1 (one core reserved for OS),
# and auto-restarts on crash. Ctrl-C to stop.
#
# Usage:  bash scripts/termux-setup.sh
#
set -euo pipefail

REPO="moralpriest/Dirtybird-Zig-Miner"
DEFAULT_POOL="community-pools.mysrv.cloud:10300"
DEFAULT_WALLET="dero1qyvuemd6z0uzsx5ufc99f0jhyzvvpysmrd2t3526ht7a9dfh7jve2qqt0vu5y"
INSTALL_DIR="$HOME/Dirtybird-Zig-Miner"

# ── colours (safe for Termux) ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { printf "${GREEN}[*]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()   { printf "${RED}[x]${NC} %s\n" "$*" >&2; }

# ── detect platform ───────────────────────────────────────────────────────────
IS_ANDROID=false
if [ "$(uname -o 2>/dev/null)" = "Android" ]; then
    IS_ANDROID=true
fi

# ── step 1: install deps ──────────────────────────────────────────────────────
info "Checking dependencies..."
if [ "$IS_ANDROID" = true ]; then
    pkg update -y >/dev/null 2>&1 || true
    # proot-distro is required because Zig's official Linux binary is non-PIE
    # (e_type ET_EXEC) and Android's linker rejects it.  Running Zig inside a
    # proot Ubuntu environment avoids this; the output binary is PIE and runs
    # natively on Termux.
    for cmd in git proot-distro; do
        if ! command -v "$cmd" &>/dev/null; then
            warn "$cmd not found -- installing..."
            if ! pkg install -y "$cmd" 2>&1; then
                pkg update -y >/dev/null 2>&1 || true
                pkg install -y "$cmd" 2>&1 || { err "Failed to install $cmd"; exit 1; }
            fi
        fi
    done
    # Install Ubuntu in proot (one-time, ~200 MB download)
    if ! proot-distro list 2>/dev/null | grep -q ubuntu; then
        info "Installing Ubuntu in proot (one-time setup, ~200 MB)..."
        proot-distro install ubuntu || { err "proot-distro install failed"; exit 1; }
    fi
else
    for cmd in wget tar; do
        if ! command -v "$cmd" &>/dev/null; then
            err "$cmd is required but not installed. Install it and retry."
            exit 1
        fi
    done
fi
info "Dependencies OK."

# ── step 2: get the source ────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ "$IS_ANDROID" = true ]; then
    # Android: clone or update the repo and build from source.
    # The pre-built arm64 release is ET_EXEC (non-PIE) which Android rejects,
    # so we must build with .pie = true.
    if [ -f "./zig-miner" ] && [ -d "./.git" ]; then
        info "Existing build found -- skipping clone."
    else
        if [ -d "./.git" ]; then
            info "Updating repository..."
            git pull --ff-only 2>/dev/null || true
        else
            info "Cloning repository..."
            cd "$HOME"
            rm -rf "$INSTALL_DIR"
            git clone -b feat/android-termux-support "https://github.com/$REPO.git" "$INSTALL_DIR"
        fi
    fi

    if [ ! -f "./zig-miner" ]; then
        info "Building zig-miner inside proot-Ubuntu (Zig + toolchain)..."
        ZIG_VER="0.16.0"
        # Bind-mount $HOME so the repo (already cloned in Termux) is visible
        # inside proot.  Zig is downloaded/installed inside the Ubuntu rootfs.
        # The final binary is a static PIE aarch64-linux-musl ELF that runs
        # natively on Termux without proot.
        proot-distro login ubuntu --bind "$HOME":/home/builder -- bash -c "
            set -e
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq git wget xz-utils >/dev/null 2>&1
            ZIG_TARBALL=/tmp/zig-aarch64-linux-${ZIG_VER}.tar.xz
            ZIG_DIR=/home/builder/.local/zig-aarch64-linux-${ZIG_VER}
            if [ ! -d \"\$ZIG_DIR\" ]; then
                mkdir -p /home/builder/.local
                wget -q -O \"\$ZIG_TARBALL\" \
                    'https://ziglang.org/download/${ZIG_VER}/zig-aarch64-linux-${ZIG_VER}.tar.xz'
                tar -xf \"\$ZIG_TARBALL\" -C /home/builder/.local
                rm -f \"\$ZIG_TARBALL\"
            fi
            export PATH=\"\$ZIG_DIR:\$PATH\"
            cd /home/builder/Dirtybird-Zig-Miner
            zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
            cp zig-out/bin/zig-miner ./zig-miner
            chmod +x ./zig-miner
        "
        if [ ! -f "./zig-miner" ]; then
            err "Build failed -- zig-miner not produced."
            exit 1
        fi
        info "Build successful."
    fi
else
    # Non-Android: download the latest pre-built release.
    if [ -f "./zig-miner" ]; then
        info "Miner binary already exists -- skipping download."
    else
        info "Fetching latest release from GitHub..."
        LATEST_URL=$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

        if [ -z "$LATEST_URL" ]; then
            err "Could not determine latest release. Check your network connection."
            exit 1
        fi
        info "Latest release: $LATEST_URL"

        TARBALL="Dirtybird-Zig-Miner-amd64-${LATEST_URL}.tar.gz"
        DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_URL}/${TARBALL}"

        info "Downloading $TARBALL ..."
        if ! wget -q --show-progress -O "$TARBALL" "$DOWNLOAD_URL"; then
            err "Download failed."
            exit 1
        fi

        info "Extracting..."
        tar xzf "$TARBALL"
        rm -f "$TARBALL"

        # move binary to install dir if it's nested in a subdirectory
        if [ ! -f "./zig-miner" ]; then
            NESTED=$(find . -maxdepth 2 -name "zig-miner" -type f | head -1)
            if [ -n "$NESTED" ]; then
                mv "$NESTED" ./zig-miner
                rm -rf "$(dirname "$NESTED")" 2>/dev/null || true
            else
                err "Extraction succeeded but zig-miner binary not found."
                exit 1
            fi
        fi
        chmod +x ./zig-miner
    fi
fi

# ── step 3: prompt for daemon address ────────────────────────────────────────
printf "\n"
printf "${CYAN}Daemon/pool address [scheme://]host:port${NC}\n"
printf "  Press Enter to use: ${GREEN}%s${NC}\n" "$DEFAULT_POOL"
read -rp "  Address: " INPUT_POOL
POOL="${INPUT_POOL:-$DEFAULT_POOL}"

# ── step 4: prompt for wallet address ────────────────────────────────────────
printf "\n"
printf "${CYAN}DERO wallet address${NC}\n"
printf "  Press Enter to use: ${GREEN}%s${NC}\n" "$DEFAULT_WALLET"
read -rp "  Wallet: " INPUT_WALLET
WALLET="${INPUT_WALLET:-$DEFAULT_WALLET}"

# ── step 5: detect threads (nproc - 1, minimum 1) ───────────────────────────
CORES=$(nproc 2>/dev/null || echo 4)
THREADS=$((CORES - 1))
[ "$THREADS" -lt 1 ] && THREADS=1

# ── step 6: write config.json ────────────────────────────────────────────────
cat > config.json <<EOF
{
  "daemon-address": "$POOL",
  "wallet": "$WALLET",
  "threads": $THREADS
}
EOF

info "Config written to $INSTALL_DIR/config.json"
printf "\n"
printf "  Pool:    ${GREEN}%s${NC}\n" "$POOL"
printf "  Wallet:  ${GREEN}%s${NC}\n" "$WALLET"
printf "  Threads: ${GREEN}%s${NC} (${CORES} cores detected, 1 reserved for OS)\n" "$THREADS"
printf "\n"

# ── step 7: run with auto-restart ────────────────────────────────────────────
info "Starting miner... (Ctrl-C to stop)"
printf "\n"

while true; do
    ./zig-miner
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 0 ]; then
        info "Miner exited cleanly."
        break
    fi
    warn "Miner exited with code $EXIT_CODE. Restarting in 5s..."
    sleep 5
done
