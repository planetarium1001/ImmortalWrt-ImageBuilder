#!/bin/sh
# ipv6mode 结构：三态分支、受管键、存档机制
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/usr/sbin/ipv6mode"
FAIL=0

[ -x "$S" ] && echo "ok: 可执行" || { echo "FAIL: 缺脚本"; FAIL=1; }
for m in nat66 native off status forget; do
	grep -qE "^[[:space:]]*$m\)" "$S" && echo "ok: 支持 $m" || { echo "FAIL: 缺 $m"; FAIL=1; }
done
grep -q "masq6=1" "$S" && echo "ok: nat66 开 masq6" || { echo "FAIL: 缺 masq6 开启"; FAIL=1; }
grep -q 'delete "firewall' "$S" && echo "ok: 关 masq6" || { echo "FAIL: 缺 masq6 关闭"; FAIL=1; }
grep -q "save_state" "$S" && grep -q "restore_state" "$S" && echo "ok: 有存档与恢复" || { echo "FAIL: 缺存档机制"; FAIL=1; }
grep -q "dhcp.lan.ra='disabled'" "$S" && echo "ok: off 关 RA" || { echo "FAIL: 缺 off 分支"; FAIL=1; }
grep -q "uci commit network" "$S" && echo "ok: 有 commit" || { echo "FAIL: 缺 commit"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "IPV6MODE OK" || echo "IPV6MODE FAILED"
exit $FAIL
