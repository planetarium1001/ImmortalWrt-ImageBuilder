#!/bin/sh
# ac-3：首启按上游式动态枚举生成 wan/br-lan 与 LAN 地址
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/etc/uci-defaults/99-custom.sh"
FAIL=0

grep -q '/sys/class/net' "$S" && echo "ok: 枚举物理口" || { echo "FAIL: 未枚举"; FAIL=1; }
grep -q 'wan_if=$(echo "$ifnames" | awk' "$S" && echo "ok: 首个为 WAN" || { echo "FAIL: WAN 选择逻辑缺失"; FAIL=1; }
grep -q 'lan_ifs=$(echo "$ifnames" | cut -d' "$S" && echo "ok: 其余为 LAN" || { echo "FAIL: LAN 选择逻辑缺失"; FAIL=1; }
grep -q 'uci -q delete "network.$sec.ports"' "$S" && echo "ok: 先清空桥成员" || { echo "FAIL: 未清空"; FAIL=1; }
grep -q 'count" -eq 1' "$S" && echo "ok: 单网口分支" || { echo "FAIL: 缺单网口分支"; FAIL=1; }
grep -q "hostname='ImmortalWrt'" "$S" && echo "ok: 主机名" || { echo "FAIL: 主机名不对"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "UCI-NIC OK" || echo "UCI-NIC FAILED"
exit $FAIL
