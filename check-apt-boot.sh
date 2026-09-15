#!/usr/bin/env bash
# FS150: show the product router. 31/32 rates persist in FC extras.txt,
# not the old rates systemd unit.
# Insert uses:
#   sudo systemctl status xgc2-fs150-mavlink-router.service
set -euo pipefail
exec systemctl status xgc2-fs150-mavlink-router.service
