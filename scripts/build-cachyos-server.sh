#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export TZ=Pacific/Auckland

WORK="/work"
BUILD="/work/build"
DIST="/work/dist"
CACHY_PKG="$BUILD/cachy-pkg"

# Options:
#   linux-cachyos-rc      = bleeding-edge RC/mainline
#   linux-cachyos-server  = server variant, usually stable/latest non-RC
CACHY_VARIANT="${CACHY_VARIANT:-linux-cachyos-rc}"

echo "========== CONTAINER INFO =========="
date
uname -a
dpkg --print-architecture
dpkg --print-foreign-architectures || true
df -h
free -h

echo "========== TOOLCHAIN INFO =========="
clang --version || true
ld.lld --version || true
x86_64-linux-gnu-gcc --version | head -2 || true
ccache --version || true
make --version | head -2 || true

echo "========== CCACHE SETUP =========="
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
export CCACHE_COMPILERCHECK=content
ccache --zero-stats || true
ccache -s || true

echo "========== FETCH CACHYOS PKGBUILD + CONFIG =========="
rm -rf "$BUILD"
mkdir -p "$CACHY_PKG"

git clone --depth=1 https://github.com/CachyOS/linux-cachyos.git "$CACHY_PKG"

CACHY_COMMIT="$(git -C "$CACHY_PKG" rev-parse --short HEAD)"
PKGBUILD_DIR="$CACHY_PKG/$CACHY_VARIANT"

if [ ! -d "$PKGBUILD_DIR" ]; then
  echo "ERROR: variant directory not found: $PKGBUILD_DIR"
  echo "Available variants:"
  find "$CACHY_PKG" -maxdepth 1 -type d -name 'linux-cachyos*' -printf '  %f\n' | sort
  exit 1
fi

echo "linux-cachyos commit: $CACHY_COMMIT"
echo "Using variant: $CACHY_VARIANT"

echo "========== PARSE PKGBUILD =========="

_pkgbuild_subshell() {
  bash -c "
    cd '$PKGBUILD_DIR'
    prepare() { true; }
    build() { true; }
    package() { true; }
    source PKGBUILD 2>/dev/null || true
    $1
  " 2>/dev/null
}

KVER="$(_pkgbuild_subshell 'printf "%s" "${pkgver:-}"' | tr -d $'\n')"
PKGREL="$(_pkgbuild_subshell 'printf "%s" "${pkgrel:-1}"' | tr -d $'\n')"
PKGREL="${PKGREL:-1}"

if [ -z "${KVER:-}" ]; then
  echo "ERROR: pkgver could not be expanded — check PKGBUILD"
  echo "--- PKGBUILD head ---"
  head -50 "$PKGBUILD_DIR/PKGBUILD"
  exit 1
fi

echo "CachyOS kernel: ${KVER}-${PKGREL}"

mapfile -t SOURCE_ITEMS < <(
  _pkgbuild_subshell 'printf "%s\n" "${source[@]+${source[@]}}"'
)

echo "Expanded PKGBUILD source items:"
printf '  %s\n' "${SOURCE_ITEMS[@]}"

mapfile -t PATCH_URLS < <(
  printf '%s\n' "${SOURCE_ITEMS[@]}" |
    grep -oP 'https://[^\s"'"'"']+\.patch([?#][^\s"'"'"']*)?' || true
)

TARBALL_URL="$(
  printf '%s\n' "${SOURCE_ITEMS[@]}" |
    grep -oP 'https://[^\s"'"'"']+\.tar\.(xz|gz|bz2)([?#][^\s"'"'"']*)?' |
    head -1 || true
)"

if [ -z "${TARBALL_URL:-}" ]; then
  echo "ERROR: no tarball URL found in PKGBUILD source array"
  echo "--- PKGBUILD source items ---"
  printf '%s\n' "${SOURCE_ITEMS[@]}"
  exit 1
fi

echo "Tarball URL: $TARBALL_URL"
echo "Extra patch URLs (${#PATCH_URLS[@]}):"
printf '  %s\n' "${PATCH_URLS[@]+"${PATCH_URLS[@]}"}"

echo "========== DOWNLOAD KERNEL =========="
cd "$BUILD"

TARBALL_FILE="$(basename "$TARBALL_URL" | sed 's/[?#].*//')"
wget -q --show-progress -O "$TARBALL_FILE" "$TARBALL_URL"

echo "Extracting $TARBALL_FILE ..."
tar -xf "$TARBALL_FILE"
rm -f "$TARBALL_FILE"

echo "========== DETECT EXTRACTED SOURCE TREE =========="
echo "Build directory after extraction:"
find "$BUILD" -maxdepth 2 -type d | sort

LINUX_SRC="$(
  find "$BUILD" -mindepth 1 -maxdepth 2 -type f -name Makefile \
    ! -path "$CACHY_PKG/*" \
    -printf '%h\n' |
    while read -r candidate; do
      if [ -f "$candidate/scripts/config" ]; then
        printf '%s\n' "$candidate"
        break
      fi
    done
)"

if [ -z "${LINUX_SRC:-}" ]; then
  echo "ERROR: kernel source directory not found after extraction"
  echo "--- BUILD LISTING ---"
  ls -la "$BUILD"
  echo "--- CANDIDATE MAKEFILES ---"
  find "$BUILD" -maxdepth 4 -type f -name Makefile -print
  echo "--- CANDIDATE scripts/config ---"
  find "$BUILD" -maxdepth 5 -type f -path '*/scripts/config' -print
  exit 1
fi

echo "Source tree: $LINUX_SRC"
cd "$LINUX_SRC"

echo "========== APPLY EXTRA CACHYOS PATCH URLS =========="
PATCH_FAIL=0

if [ "${#PATCH_URLS[@]}" -eq 0 ]; then
  echo "No extra patch URLs found."
else
  for url in "${PATCH_URLS[@]}"; do
    name="$(basename "$url" | sed 's/[?#].*//')"
    echo "  -> $name"

    if ! curl -fsSL -o "/tmp/${name}" "$url"; then
      echo "WARN: download failed: $url"
      PATCH_FAIL=1
      continue
    fi

    if ! patch -p1 --forward --fuzz=3 -r /dev/null < "/tmp/${name}"; then
      echo "WARN: patch failed or already applied: $name"
      PATCH_FAIL=1
    fi
  done
fi

[ "$PATCH_FAIL" -ne 0 ] && echo "WARN: one or more extra patches failed or were already applied; continuing."

echo "========== SETUP BASE CONFIG =========="
if [ ! -f "$PKGBUILD_DIR/config" ]; then
  echo "ERROR: base config missing: $PKGBUILD_DIR/config"
  find "$PKGBUILD_DIR" -maxdepth 2 -type f | sort
  exit 1
fi

cp "$PKGBUILD_DIR/config" .config
chmod +x ./scripts/config

echo "========== APPLY SERVER / TIGER LAKE TWEAKS =========="

./scripts/config --set-str LOCALVERSION "-cachyos-edge-lenovov15g2"

# CPU target: x86-64-v3 where Cachy/Graysky symbols exist.
./scripts/config --disable GENERIC_CPU    || true
./scripts/config --disable GENERIC_CPU2   || true
./scripts/config --disable GENERIC_CPU4   || true
./scripts/config --enable  GENERIC_CPU3   || true

# Timer frequency: 100 Hz server profile.
./scripts/config --disable HZ_250   || true
./scripts/config --disable HZ_300   || true
./scripts/config --disable HZ_500   || true
./scripts/config --disable HZ_600   || true
./scripts/config --disable HZ_750   || true
./scripts/config --disable HZ_1000  || true
./scripts/config --enable  HZ_100
./scripts/config --set-val HZ 100

# Preemption: best-effort no-preempt/server throughput.
./scripts/config --disable PREEMPT_VOLUNTARY_BUILD || true
./scripts/config --disable PREEMPT_BUILD           || true
./scripts/config --disable PREEMPT_DYNAMIC         || true
./scripts/config --disable PREEMPT_LAZY            || true
./scripts/config --disable PREEMPT                 || true
./scripts/config --enable  PREEMPT_NONE_BUILD      || true

# LTO: ThinLTO.
./scripts/config --enable  LTO              || true
./scripts/config --enable  LTO_CLANG        || true
./scripts/config --disable LTO_NONE         || true
./scripts/config --disable LTO_CLANG_FULL   || true
./scripts/config --enable  LTO_CLANG_THIN   || true

# Transparent Huge Pages: always.
./scripts/config --enable  TRANSPARENT_HUGEPAGE
./scripts/config --disable TRANSPARENT_HUGEPAGE_MADVISE || true
./scripts/config --disable TRANSPARENT_HUGEPAGE_NEVER   || true
./scripts/config --enable  TRANSPARENT_HUGEPAGE_ALWAYS

# Expose config via /proc/config.gz.
./scripts/config --enable IKCONFIG
./scripts/config --enable IKCONFIG_PROC

# Intel Tiger Lake iGPU / Quick Sync.
./scripts/config --module DRM_I915 || ./scripts/config --enable DRM_I915 || true

# Intel CPU power management.
./scripts/config --enable X86_INTEL_PSTATE || true
./scripts/config --enable INTEL_IDLE || true
./scripts/config --enable INTEL_HFI_THERMAL || true

# WiFi: Intel AX201.
./scripts/config --module IWLWIFI || ./scripts/config --enable IWLWIFI || true
./scripts/config --module IWLMVM  || ./scripts/config --enable IWLMVM  || true

# Sound: Intel SOF / SoundWire, best-effort modules.
./scripts/config --module SND_SOC_SOF                      || true
./scripts/config --module SND_SOC_SOF_INTEL_SOUNDWIRE_LINK || true
./scripts/config --module SND_SOC_SOF_TIGERLAKE            || true

# Thunderbolt / USB4.
./scripts/config --module THUNDERBOLT || ./scripts/config --enable THUNDERBOLT || true
./scripts/config --module USB4        || ./scripts/config --enable USB4        || true

# Intel PMT telemetry.
./scripts/config --module INTEL_PMT_TELEMETRY || ./scripts/config --enable INTEL_PMT_TELEMETRY || true
./scripts/config --module INTEL_PMT_CRASHLOG  || ./scripts/config --enable INTEL_PMT_CRASHLOG  || true

# Network: BBR + FQ.
./scripts/config --enable TCP_CONG_BBR || true
./scripts/config --enable DEFAULT_BBR || true
./scripts/config --set-str DEFAULT_TCP_CONG "bbr" || true
./scripts/config --module NET_SCH_FQ || ./scripts/config --enable NET_SCH_FQ || true

# Docker/container support.
./scripts/config --enable NAMESPACES || true
./scripts/config --enable NET_NS || true
./scripts/config --enable PID_NS || true
./scripts/config --enable IPC_NS || true
./scripts/config --enable UTS_NS || true
./scripts/config --enable USER_NS || true
./scripts/config --module OVERLAY_FS || ./scripts/config --enable OVERLAY_FS || true
./scripts/config --module VETH || ./scripts/config --enable VETH || true
./scripts/config --module BRIDGE || ./scripts/config --enable BRIDGE || true
./scripts/config --module BRIDGE_NETFILTER || ./scripts/config --enable BRIDGE_NETFILTER || true

# Useful server/filesystem modules.
./scripts/config --module NF_TABLES || ./scripts/config --enable NF_TABLES || true
./scripts/config --module IP_NF_NAT || ./scripts/config --enable IP_NF_NAT || true
./scripts/config --module NFS_FS || true
./scripts/config --module CIFS || true
./scripts/config --module SMB_SERVER || true
./scripts/config --module BTRFS_FS || true
./scripts/config --module F2FS_FS || true
./scripts/config --module XFS_FS || true

# Reduce package size.
./scripts/config --disable DEBUG_INFO_BTF    || true
./scripts/config --disable DEBUG_INFO_DWARF5 || true

echo "========== OLDDEFCONFIG =========="
make ARCH=x86_64 LLVM=1 LLVM_IAS=1 olddefconfig

echo "========== VERIFY CRITICAL CONFIG OPTIONS =========="
FAILED=0

_check_eq() {
  local key="$1"
  local val="$2"
  if ! grep -qE "^${key}=${val}$" .config; then
    echo "CRITICAL: ${key}=${val} not found — got: $(grep "^${key}=" .config 2>/dev/null || echo '(not set)')"
    FAILED=1
  fi
}

_check_ym() {
  local key="$1"
  if ! grep -qE "^${key}=[ym]$" .config; then
    echo "CRITICAL: ${key} not set to y or m — got: $(grep "^${key}=" .config 2>/dev/null || echo '(not set)')"
    FAILED=1
  fi
}

_warn_ym() {
  local key="$1"
  if ! grep -qE "^${key}=[ym]$" .config; then
    echo "WARN: ${key} absent/not y/m — got: $(grep "^${key}=" .config 2>/dev/null || echo '(not set)')"
  fi
}

_check_eq  CONFIG_HZ_100                      y
_check_eq  CONFIG_HZ                          100
_check_eq  CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS y
_check_eq  CONFIG_LTO_CLANG_THIN              y

_check_ym  CONFIG_DRM_I915
_check_ym  CONFIG_TCP_CONG_BBR
_check_ym  CONFIG_IWLWIFI
_check_ym  CONFIG_IWLMVM
_check_ym  CONFIG_OVERLAY_FS
_check_ym  CONFIG_VETH
_check_ym  CONFIG_BRIDGE

_warn_ym   CONFIG_GENERIC_CPU3
_warn_ym   CONFIG_NET_SCH_FQ
_warn_ym   CONFIG_PREEMPT_NONE_BUILD
_warn_ym   CONFIG_NF_TABLES
_warn_ym   CONFIG_BRIDGE_NETFILTER

if [ "$FAILED" -ne 0 ]; then
  echo "Aborting due to critical config failure."
  echo "Relevant config:"
  grep -E 'CONFIG_HZ=|CONFIG_HZ_100|CONFIG_PREEMPT|CONFIG_LTO|CONFIG_TRANSPARENT_HUGEPAGE|CONFIG_DRM_I915|CONFIG_TCP_CONG_BBR|CONFIG_IWLWIFI|CONFIG_IWLMVM|CONFIG_GENERIC_CPU3|CONFIG_NET_SCH_FQ|CONFIG_OVERLAY_FS|CONFIG_VETH|CONFIG_BRIDGE' .config || true
  exit 1
fi

echo "Critical config verified."

echo "========== CONFIG SUMMARY =========="
grep -E \
  'CONFIG_HZ=|CONFIG_HZ_100|CONFIG_PREEMPT|CONFIG_CC_IS_CLANG|CONFIG_LTO_CLANG_THIN|CONFIG_TRANSPARENT_HUGEPAGE=|CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS|CONFIG_DEFAULT_TCP_CONG|CONFIG_TCP_CONG_BBR=|CONFIG_DRM_I915=|CONFIG_IWLWIFI=|CONFIG_IWLMVM=|CONFIG_GENERIC_CPU3|CONFIG_NET_SCH_FQ=|CONFIG_LOCALVERSION|CONFIG_OVERLAY_FS=|CONFIG_VETH=|CONFIG_BRIDGE=' \
  .config || true

echo "========== BUILD =========="

# Important:
# - ARCH=x86_64 targets Lenovo.
# - Host/container is ARM64.
# - CROSS_COMPILE provides GNU cross tools expected by Debian packaging.
# - CC explicitly targets x86_64 to avoid aarch64 clang default.
make ARCH=x86_64 LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=x86_64-linux-gnu- \
  CC="ccache clang --target=x86_64-linux-gnu" \
  HOSTCC=gcc \
  KCFLAGS="-march=x86-64-v3 -mtune=generic" \
  KBUILD_DEBARCH=amd64 \
  KDEB_PKGVERSION="${KVER}-${PKGREL}-cachyos" \
  KBUILD_BUILD_USER=github \
  KBUILD_BUILD_HOST=actions \
  -j"$(nproc)" bindeb-pkg

echo "========== COLLECT RELEASE ASSETS =========="
rm -rf "$DIST"
mkdir -p "$DIST"

find "$BUILD" -maxdepth 3 -type f -name "*.deb" ! -name "*-dbg_*" -exec cp -v {} "$DIST/" \;

cd "$DIST"

ls linux-image-*.deb   >/dev/null 2>&1 || { echo "ERROR: no linux-image deb"; exit 1; }
ls linux-headers-*.deb >/dev/null 2>&1 || { echo "ERROR: no linux-headers deb"; exit 1; }

sha256sum *.deb > SHA256SUMS

echo "========== BUILD MANIFEST =========="
CLANG_VER="$(clang --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")"
LLD_VER="$(ld.lld --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")"

cat > BUILD_MANIFEST <<MANIFEST
CLANG_VERSION=${CLANG_VER}
LLD_VERSION=${LLD_VER}
KERNEL_VERSION=${KVER}
PKGREL=${PKGREL}
CACHY_COMMIT=${CACHY_COMMIT}
CACHY_VARIANT=${CACHY_VARIANT}
BUILD_DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
KERNEL_LOCALVERSION=-cachyos-edge-lenovov15g2
SCHEDULER=eevdf
CPU_TARGET=x86-64-v3
TIMER_HZ=100
LTO=ThinLTO
THP=always
PREEMPT=best-effort-none
BASE=cachyos-rc
MANIFEST

cat BUILD_MANIFEST

echo "========== CCACHE STATS =========="
ccache -s || true

echo "========== FINAL ASSETS =========="
ls -lh
cat SHA256SUMS

echo "========== FIX OWNERSHIP =========="
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "${HOST_UID}:${HOST_GID}" /work || true
fi