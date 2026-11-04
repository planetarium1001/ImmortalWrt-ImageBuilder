#!/bin/sh
# ac-2：不再整份覆盖 network/dhcp/firewall
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0
for f in network dhcp firewall; do
	[ -e "$ROOT/files/etc/config/$f" ] && { echo "FAIL: 仍覆盖 $f"; FAIL=1; }
done
[ "$FAIL" = "0" ] && echo "ok: 三个覆盖文件已删除"

# 首启必须用 uci 设置而非拷贝文件
S="$ROOT/files/etc/uci-defaults/99-custom.sh"
grep -q "uci set network.lan.ipaddr" "$S" && echo "ok: 首启设 LAN 地址" || { echo "FAIL: 未设 LAN 地址"; FAIL=1; }
grep -q "uci add_list \"network.\$sec.ports" "$S" && echo "ok: 首启动态写桥成员" || { echo "FAIL: 未动态写端口"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "NO-OVERRIDE OK" || echo "NO-OVERRIDE FAILED"
exit $FAIL
