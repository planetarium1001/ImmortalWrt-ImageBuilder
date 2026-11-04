#!/bin/sh
# NAT66 相关：由 ipv6mode 提供，不再靠整份 firewall 覆盖
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/usr/sbin/ipv6mode"
FAIL=0

[ -e "$ROOT/files/etc/config/firewall" ] && { echo "FAIL: 仍在覆盖 firewall"; FAIL=1; } || echo "ok: 不覆盖 firewall"
grep -q "masq6=1" "$S" && echo "ok: nat66 开 masq6" || { echo "FAIL: 缺 masq6 开关"; FAIL=1; }
grep -q "ula_prefix" "$S" && echo "ok: 使用 ULA 前缀" || { echo "FAIL: 缺 ULA"; FAIL=1; }
grep -q "dhcp.lan.ra='disabled'" "$S" && echo "ok: off 关 RA" || { echo "FAIL: 缺关闭分支"; FAIL=1; }
grep -q "wan6.auto='1'" "$S" && echo "ok: native 打开 wan6" || { echo "FAIL: 缺 native 分支"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "NAT66 OK" || echo "NAT66 FAILED"
exit $FAIL
