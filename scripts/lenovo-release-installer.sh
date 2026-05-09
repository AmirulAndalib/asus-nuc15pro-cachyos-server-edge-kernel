#!/usr/bin/env bash
set -euo pipefail

OWNER_REPO="${OWNER_REPO:-AmirulAndalib/lenovo-v15g2-itl-cachyos-server-edge-kernel}"

STATE_DIR="/var/lib/lenovo-kernel-updater"
LOG_DIR="/var/log/lenovo-kernel-updater"
WORK_DIR="/tmp/lenovo-kernel-install"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$WORK_DIR"

LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "========== LENOVO KERNEL UPDATER START =========="
date
uname -a

echo "========== ENSURE TOOLS =========="
apt-get update -qq
apt-get install -y curl jq ca-certificates

echo "========== FETCH RELEASE METADATA =========="
API="https://api.github.com/repos/${OWNER_REPO}/releases"
curl -fsSL "$API" > "$WORK_DIR/releases.json"

TAG="$(jq -r '.[0].tag_name' "$WORK_DIR/releases.json")"

if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "ERROR: no release tag found."
  exit 1
fi

echo "Latest release tag: $TAG"

LAST_TAG_FILE="$STATE_DIR/last-installed-tag"

if [ -f "$LAST_TAG_FILE" ] && [ "$(cat "$LAST_TAG_FILE")" = "$TAG" ]; then
  echo "Already installed release $TAG. Nothing to do."
  exit 0
fi

echo "========== DOWNLOAD ASSETS =========="
rm -rf "$WORK_DIR/assets"
mkdir -p "$WORK_DIR/assets"

jq -r '.[0].assets[] | select(.name | test("^(linux-(image|headers).*\\.deb|linux-libc-dev_.*\\.deb|SHA256SUMS|BUILD_MANIFEST)$")) | .browser_download_url' \
  "$WORK_DIR/releases.json" > "$WORK_DIR/urls.txt"

cat "$WORK_DIR/urls.txt"

grep -q 'linux-image'   "$WORK_DIR/urls.txt" || { echo "ERROR: no linux-image asset"; exit 1; }
grep -q 'linux-headers' "$WORK_DIR/urls.txt" || { echo "ERROR: no linux-headers asset"; exit 1; }
grep -q 'SHA256SUMS'    "$WORK_DIR/urls.txt" || { echo "ERROR: no SHA256SUMS asset"; exit 1; }

cd "$WORK_DIR/assets"

while IFS= read -r url; do
  [ -z "$url" ] && continue
  echo "Downloading: $url"
  curl -fLJO "$url"
done < "$WORK_DIR/urls.txt"

ls -lh

echo "========== BUILD MANIFEST =========="
cat BUILD_MANIFEST 2>/dev/null || true

echo "========== VERIFY CHECKSUMS =========="
sha256sum -c SHA256SUMS

echo "========== ENSURE FALLBACK KERNELS =========="
apt-get install -y linux-image-generic linux-headers-generic || true

echo "========== INSTALL KERNEL PACKAGES =========="
mapfile -t DEBS < <(
  find . -maxdepth 1 -type f \
    \( -name 'linux-headers-*.deb' -o -name 'linux-image-*.deb' -o -name 'linux-libc-dev_*.deb' \) |
    sort
)

if [ "${#DEBS[@]}" -eq 0 ]; then
  echo "ERROR: no .deb kernel packages found"
  exit 1
fi

dpkg -i "${DEBS[@]}"
apt-get -f install -y

echo "========== UPDATE INITRAMFS + GRUB =========="
update-initramfs -u -k all
update-grub

echo "========== APPLY LENOVO SYSTEM TUNING =========="

install -Dm644 /dev/stdin /etc/modprobe.d/i915-guc.conf <<'MODPROBE'
options i915 enable_guc=3
MODPROBE

install -Dm644 /dev/stdin /etc/sysctl.d/99-lenovo-v15g2-server.conf <<'SYSCTL'
# TCP: BBR + FQ
net.core.default_qdisc             = fq
net.ipv4.tcp_congestion_control    = bbr

# Larger socket buffers
net.core.rmem_max                  = 134217728
net.core.wmem_max                  = 134217728
net.ipv4.tcp_rmem                  = 4096 87380 134217728
net.ipv4.tcp_wmem                  = 4096 65536 134217728
net.ipv4.tcp_fastopen              = 3

# Docker/container inotify
fs.inotify.max_user_watches        = 1048576
fs.inotify.max_user_instances      = 1024

# Memory: server bias
vm.swappiness                      = 10
vm.vfs_cache_pressure              = 50
vm.dirty_background_ratio          = 5
vm.dirty_ratio                     = 20

# Intel GPU perf monitoring
dev.i915.perf_stream_paranoid      = 0
SYSCTL

sysctl --system || true

echo "========== RECORD INSTALLED TAG =========="
echo "$TAG" > "$LAST_TAG_FILE"

echo "========== FINAL PACKAGE STATE =========="
dpkg -l | grep -iE 'cachyos|linux-image|linux-headers' || true
ls -lh /boot | grep -E 'cachyos|vmlinuz|initrd' || true

echo "========== REBOOT =========="
sync
systemctl reboot