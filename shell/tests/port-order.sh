#!/bin/sh
# ac-3：默认约定 eth0=WAN、eth1..eth3=br-lan，且配置不依赖改名结果
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
N="$ROOT/files/etc/config/network"
FAIL=0

grep -q "option device 'eth0'" "$N" && echo "ok: WAN 默认 eth0" || { echo "FAIL: WAN 不是 eth0"; FAIL=1; }
for p in eth1 eth2 eth3; do
	grep -q "list ports '$p'" "$N" && echo "ok: br-lan 含 $p" || { echo "FAIL: br-lan 缺 $p"; FAIL=1; }
done

# 首启不得再重命名或删改端口
S="$ROOT/files/etc/uci-defaults/99-custom.sh"
if grep -q "ip link set .*name" "$S"; then echo "FAIL: 首启仍在改名"; FAIL=1; else echo "ok: 首启不改名"; fi
grep -q "/usr/sbin/nicsync" "$S" && echo "ok: 首启调用 nicsync 自检" || { echo "FAIL: 缺少自检调用"; FAIL=1; }

# 不存在的 portmap init 不应被引用
if grep -rq "init.d/portmap" "$ROOT/files" "$ROOT/docs" 2>/dev/null; then
	echo "FAIL: 仍有 init.d/portmap 引用"; FAIL=1
else
	echo "ok: 无 portmap init 引用"
fi

[ "$FAIL" = "0" ] && echo "PORT-ORDER OK" || echo "PORT-ORDER FAILED"
exit $FAIL
