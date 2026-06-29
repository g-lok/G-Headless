#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── System dependencies (Arch Linux) ──────────────────────────
MISSING=()
for pkg in gptfdisk qemu-user-static qemu-user-static-binfmt arch-install-scripts; do
  pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[*] Installing system deps: ${MISSING[*]}"
  sudo pacman -S --needed --noconfirm "${MISSING[@]}"
fi

# ── Config ────────────────────────────────────────────────────
PI_IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
PI_IMAGE_SHA256="acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3"
PI_IMAGE_XZ="files/pi-base.img.xz"
PI_IMAGE_RAW="files/pi-base.img"
AUR_PKG="mkinitcpio-systemd-extras"

# ── Step 1: Pi OS Lite image ────────────────────────────────
if [ -f "$PI_IMAGE_RAW" ]; then
  echo "[+] $PI_IMAGE_RAW exists, skipping download"
else
  if [ ! -f "$PI_IMAGE_XZ" ]; then
    echo "[*] Downloading Pi OS Lite 64-bit (Trixie)..."
    curl -fsSL -o "$PI_IMAGE_XZ" "$PI_IMAGE_URL"
  else
    echo "[*] $PI_IMAGE_XZ already downloaded"
  fi

  echo "[*] Verifying SHA256..."
  echo "$PI_IMAGE_SHA256  $PI_IMAGE_XZ" | sha256sum -c

  echo "[*] Decompressing -> $PI_IMAGE_RAW"
  xz -d "$PI_IMAGE_XZ"
  echo "[+] $PI_IMAGE_RAW ready"
fi

# ── Step 2: Vendored mkinitcpio-systemd-extras ─────────────
shopt -s nullglob
existing=(files/"$AUR_PKG"-*.pkg.tar.zst)
if [ ${#existing[@]} -gt 0 ]; then
  echo "[+] ${existing[0]} exists, skipping build"
else
  echo "[*] Building $AUR_PKG from AUR..."
  BUILD_DIR="$(mktemp -d)"
  git clone --depth=1 "https://aur.archlinux.org/$AUR_PKG.git" "$BUILD_DIR/$AUR_PKG"
  pushd "$BUILD_DIR/$AUR_PKG" >/dev/null
  makepkg -sc --noconfirm
  cp ./*.pkg.tar.zst "$SCRIPT_DIR/files/"
  popd >/dev/null
  rm -rf "$BUILD_DIR"
  echo "[+] $(ls files/"$AUR_PKG"-*.pkg.tar.zst) ready"
fi
shopt -u nullglob

# ── Step 3: Ansible Galaxy collections ──────────────────────
echo "[*] Installing Ansible Galaxy collections..."
poetry run ansible-galaxy collection install -r requirements.yml

echo "[✔] All deps ready"
