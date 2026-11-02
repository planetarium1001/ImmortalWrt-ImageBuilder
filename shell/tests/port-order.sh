#!/bin/sh
# ac-3：端口按 PCI 槽位顺序重命名，两阶段无冲突
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/etc/init.d/portmap"
FAIL=0

[ -x "$S" ] && echo "ok: portmap init 存在" || { echo "FAIL: 缺 portmap"; FAIL=1; }
grep -q "START=15" "$S" && echo "ok: START=15（早于 network）" || { echo "FAIL: 启动序不对"; FAIL=1; }
grep -q "tmp\$i" "$S" && echo "ok: 两阶段改名" || { echo "FAIL: 未用临时名过渡"; FAIL=1; }
grep -q "PCI_SLOT_NAME" "$S" && echo "ok: 按 PCI 槽位排序" || { echo "FAIL: 未用槽位"; FAIL=1; }

# 静态网络配置必须引用 eth0..eth3，且不再动态改端口
N="$ROOT/files/etc/config/network"
grep -q "option device 'eth0'" "$N" && echo "ok: WAN 引用 eth0" || { echo "FAIL: WAN 未引用 eth0"; FAIL=1; }
for p in eth1 eth2 eth3; do
	grep -q "list ports '$p'" "$N" && echo "ok: br-lan 含 $p" || { echo "FAIL: br-lan 缺 $p"; FAIL=1; }
done

# 首启脚本不得再删改 br_lan.ports
if grep -q "delete network.br_lan.ports\|add_list network.br_lan.ports" "$ROOT/files/etc/uci-defaults/99-custom.sh"; then
	echo "FAIL: 首启仍在动态改端口"; FAIL=1
else
	echo "ok: 首启不再动态改端口"
fi

[ "$FAIL" = "0" ] && echo "PORT-ORDER OK" || echo "PORT-ORDER FAILED"
exit $FAIL
