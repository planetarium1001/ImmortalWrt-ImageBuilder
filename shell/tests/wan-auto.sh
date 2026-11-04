#!/bin/sh
# ac-3：首启不再强制 wan.auto=0，沿用上游默认
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/etc/uci-defaults/99-custom.sh"
FAIL=0

grep -q "network.wan.auto='0'" "$S" && { echo "FAIL: 仍强制 auto=0"; FAIL=1; } || echo "ok: 未强制关闭 WAN"
grep -q "network.wan6.auto='0'" "$S" && { echo "FAIL: 仍强制 wan6 auto=0"; FAIL=1; } || echo "ok: 未强制关闭 wan6"
grep -q "proto='dhcp'" "$S" && echo "ok: WAN 用 dhcp" || { echo "FAIL: WAN 非 dhcp"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "WAN-AUTO OK" || echo "WAN-AUTO FAILED"
exit $FAIL
