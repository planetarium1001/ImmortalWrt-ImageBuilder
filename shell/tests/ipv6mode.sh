#!/bin/sh
# ac-4：ipv6mode 三态切换正确且幂等
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/usr/sbin/ipv6mode"
FAIL=0

[ -x "$S" ] && echo "ok: ipv6mode 可执行" || { echo "FAIL: 缺脚本"; FAIL=1; }
for m in nat66 native off status; do
	grep -q "^	$m)" "$S" && echo "ok: 支持 $m" || { echo "FAIL: 缺 $m 分支"; FAIL=1; }
done

# nat66：ULA + masq6 + wan6 关闭
grep -q "ula_prefix=\"\$ULA\"" "$S" && echo "ok: nat66 设 ULA" || { echo "FAIL: nat66 未设 ULA"; FAIL=1; }
grep -q "masq6='1'" "$S" && echo "ok: nat66 开 masq6" || { echo "FAIL: nat66 未开 masq6"; FAIL=1; }
# native：删 ULA、删 masq6、wan6 打开
grep -q "delete network.globals.ula_prefix" "$S" && echo "ok: native/off 删 ULA" || { echo "FAIL: 未删 ULA"; FAIL=1; }
grep -q "delete firewall.@zone\[1\].masq6" "$S" && echo "ok: native/off 关 masq6" || { echo "FAIL: 未关 masq6"; FAIL=1; }
# off：关 RA/DHCPv6
grep -q "dhcp.lan.ra='disabled'" "$S" && echo "ok: off 关 RA" || { echo "FAIL: off 未关 RA"; FAIL=1; }

# 幂等：重复 set 相同值 + commit
grep -q "uci commit network" "$S" && grep -q "uci commit dhcp" "$S" && grep -q "uci commit firewall" "$S" \
	&& echo "ok: 三个 commit 齐全" || { echo "FAIL: 缺 commit"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "IPV6MODE OK" || echo "IPV6MODE FAILED"
exit $FAIL
