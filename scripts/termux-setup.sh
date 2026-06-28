#!/usr/bin/env bash
#
# Dirtybird Zig Miner -- Termux (Android) setup & launcher.
#
# Downloads the pre-built release for the current platform:
#   - Android/Termux (aarch64): arm64 static-PIE binary
#   - Linux (x86_64):           amd64 static binary
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
    for cmd in wget tar; do
        if ! command -v "$cmd" &>/dev/null; then
            pkg update -y >/dev/null 2>&1 || true
            pkg install -y "$cmd" 2>&1 || { err "Failed to install $cmd"; exit 1; }
        fi
    done
else
    for cmd in wget tar; do
        if ! command -v "$cmd" &>/dev/null; then
            err "$cmd is required but not installed. Install it and retry."
            exit 1
        fi
    done
fi
info "Dependencies OK."

# ── step 2: get the binary ────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ -f "./zig-miner" ]; then
    info "Miner binary already exists -- skipping download."
else
    info "Fetching latest release from GitHub..."
    LATEST_TAG=$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$LATEST_TAG" ]; then
        err "Could not determine latest release. Check your network connection."
        exit 1
    fi
    info "Latest release: $LATEST_TAG"

    if [ "$IS_ANDROID" = true ]; then
        ARCH_SUFFIX="arm64"
    else
        ARCH_SUFFIX="amd64"
    fi

    TARBALL="Dirtybird-Zig-Miner-${ARCH_SUFFIX}-${LATEST_TAG}.tar.gz"
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_TAG}/${TARBALL}"

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
