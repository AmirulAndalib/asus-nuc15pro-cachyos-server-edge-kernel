#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="scripts/nuc16pro-kernel-updater.sh.in"
OUT="scripts/nuc16pro-kernel-updater.sh"

# Splices tracked config/unit files (modprobe.d/, sysctl.d/, udev/, systemd/)
# into the @@FILE:<path>@@ markers in the .in template, producing the single
# self-contained script that gets wget'd onto the device. Keep this in sync
# with the .in template and source files - CI's sync-check step re-runs this
# and fails the build if the output drifts from what's committed.
awk '
  /^@@FILE:.*@@$/ {
    path = $0
    sub(/^@@FILE:/, "", path)
    sub(/@@$/, "", path)
    n = (getline line < path)
    while (n > 0) { print line; n = (getline line < path) }
    if (n < 0) { print "assemble: cannot read " path > "/dev/stderr"; exit 1 }
    close(path)
    next
  }
  { print }
' "$SRC" > "$OUT"

echo "assembled $OUT from $SRC"
