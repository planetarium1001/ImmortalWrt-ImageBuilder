#!/bin/sh
# ac-5：主机名为 ImmortalWrt
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/etc/uci-defaults/99-custom.sh"
FAIL=0
grep -q "hostname='ImmortalWrt'" "$S" && echo "ok: hostname=ImmortalWrt" || { echo "FAIL: 主机名不对"; FAIL=1; }
if grep -q "n5105-router" "$S"; then echo "FAIL: 仍残留旧主机名"; FAIL=1; else echo "ok: 无旧主机名"; fi
[ "$FAIL" = "0" ] && echo "HOSTNAME OK" || echo "HOSTNAME FAILED"
exit $FAIL
