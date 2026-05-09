# Lenovo V15 G2 ITL CachyOS Edge Kernel

Bleeding-edge [CachyOS](https://github.com/CachyOS/linux-cachyos) kernel release pipeline for the Lenovo V15 G2 ITL with Intel Core i5-1135G7.
Tracks `linux-cachyos-rc`, the latest mainline RC release with CachyOS patches and server-profile config.

## Target System

- **Machine:** Lenovo V15 G2 ITL
- **CPU:** Intel Core i5-1135G7 / Tiger Lake (4C/8T, 2.4–4.2 GHz)
- **iGPU:** Intel Iris Xe Graphics (i915, GuC/HuC)
- **WiFi:** Intel Wi-Fi 6 AX201
- **Target architecture:** x86-64-v3
- **Target OS:** Ubuntu 26.04 LTS (amd64)
- **Kernel base:** [CachyOS linux-cachyos-rc](https://github.com/CachyOS/linux-cachyos) (latest bleeding-edge RC)
- **Package format:** Debian/Ubuntu `.deb`

## Kernel Profile

| Setting                | Value                                 |
| ---------------------- | ------------------------------------- |
| Scheduler              | EEVDF (server profile)                |
| Compiler               | LLVM / Clang + LLD                    |
| LTO                    | ThinLTO                               |
| CPU target             | x86-64-v3 (AVX2, BMI2, FMA, LZCNT …) |
| Timer frequency        | 100 Hz                                |
| Transparent Huge Pages | always                                |
| Preemption model       | None (max-throughput)                 |
| TCP congestion         | BBR (mainline)                        |
| GuC / HuC              | Enabled via `i915.enable_guc=3`     |

## Pipeline

GitHub Actions runs on a self-hosted Oracle Ampere A1 (AArch64) runner.
The kernel is **cross-compiled natively on ARM64** using LLVM. No QEMU needed.

```text
Oracle A1 (ARM64) -> clang --target=x86_64-linux-gnu -> .deb (amd64)
```

Weekly schedule: Wednesday 12:00 UTC (Thursday 00:00 NZST / 01:00 NZDT).

### Release assets

- `linux-image-*.deb` - kernel image and modules
- `linux-headers-*.deb` - headers for DKMS / out-of-tree modules
- `linux-libc-dev_*.deb` - userspace kernel headers (if present)
- `SHA256SUMS` - SHA-256 checksums
- `BUILD_MANIFEST` - compiler version, CachyOS commit, build timestamp

Release tag format: `v{KERNEL}-cachyos-edge-x86_64v3-{YYYYMMDD}.{RUN}`
Release title format: `Linux {kernel-pkg} • CachyOS Edge • Lenovo V15 G2 ITL • {YYYY-MM-DD}`

RC kernels are automatically published as pre-releases.

## Required GitHub Runner Labels

```text
self-hosted
Linux
ARM64
oracle-a1
tkg-builder
```

## Setup

### 1. Fork/clone and set OWNER_REPO

```bash
git clone https://github.com/amirulandalib/lenovo-v15g2-itl-cachyos-server-edge-kernel.git
```

Set `OWNER_REPO` in two places to match your GitHub username:

**`scripts/lenovo-release-installer.sh`** (line 4):

```bash
OWNER_REPO="${OWNER_REPO:-amirulandalib/lenovo-v15g2-itl-cachyos-server-edge-kernel}"
```

**`systemd/lenovo-kernel-updater.service`** (Environment line):

```ini
Environment=OWNER_REPO=amirulandalib/lenovo-v15g2-itl-cachyos-server-edge-kernel
```

### 2. Register the self-hosted runner

On your Oracle A1 instance:

```bash
./config.sh --url https://github.com/amirulandalib/lenovo-v15g2-itl-cachyos-server-edge-kernel \
  --token YOUR_RUNNER_TOKEN \
  --labels self-hosted,Linux,ARM64,oracle-a1,tkg-builder
```

Ensure Docker is installed and the runner user can run Docker without sudo.

### 3. Install the auto-updater on the Lenovo machine

Run as root:

```bash
# Copy installer
cp scripts/lenovo-release-installer.sh /usr/local/sbin/lenovo-kernel-updater.sh
chmod 700 /usr/local/sbin/lenovo-kernel-updater.sh

# Install systemd units
cp systemd/lenovo-kernel-updater.service /etc/systemd/system/
cp systemd/lenovo-kernel-updater.timer   /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now lenovo-kernel-updater.timer
```

The installer is idempotent. It records the installed tag in
`/var/lib/lenovo-kernel-updater/last-installed-tag` and skips if already installed.

### 4. Apply Tiger Lake boot parameters

Add to GRUB (`/etc/default/grub`):

```sh
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_pstate=active i915.enable_guc=3"
```

Then:

```bash
sudo update-grub
```

The installer automatically writes `/etc/modprobe.d/i915-guc.conf` and
`/etc/sysctl.d/99-lenovo-v15g2-server.conf` (BBR, large buffers, inotify,
vm tuning, i915 perf monitoring) on first run.

## Manual Build

Trigger via GitHub Actions → **Build Lenovo V15 G2 ITL CachyOS Edge Kernel** → **Run workflow**.

## Manual Install

```bash
sudo /usr/local/sbin/lenovo-kernel-updater.sh
```

## Logs

Install logs: `/var/log/lenovo-kernel-updater/`

## Fallback Kernels

The installer ensures `linux-image-generic` is installed before switching.
GRUB presents all kernels at boot.
