#!/bin/sh
# ac-4：ipv6mode 每模式存档与恢复（功能验证）
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/usr/sbin/ipv6mode"
FAIL=0

W=/tmp/ipv6m; rm -rf $W; mkdir -p $W/bin $W/etc/config
cp "$ROOT/shell/tests/uci-stub6.sh" $W/bin/uci
chmod +x $W/bin/uci
export UCI_STUB_DB=$W/etc/config/uci.db

# 用 sandbox 路径替换脚本里的绝对路径
sed -e "s#/etc/config/ipv6mode.d#$W/etc/config/ipv6mode.d#" \
    -e "s#^CUR_FILE=/etc/config/ipv6mode#CUR_FILE=$W/etc/config/ipv6mode#" \
    -e "s#/etc/init.d/network reload#true#" \
    -e "s#/etc/init.d/dnsmasq restart#true#" \
    -e "s#/etc/init.d/firewall reload#true#" "$S" > $W/ipv6mode

printf 'firewall.cfg01.name=wan\n' >"$UCI_STUB_DB"
run() { PATH=$W/bin:$PATH sh $W/ipv6mode "$@"; }

# 1) 首次切 nat66 → 套模板
run nat66 >/dev/null
[ "$(grep -F 'network.wan6.auto=' "$UCI_STUB_DB" | tail -1)" = "network.wan6.auto=0" ] && echo "ok: nat66 关 wan6" || { echo "FAIL: nat66 未关 wan6"; FAIL=1; }
[ "$(grep -F 'firewall.cfg01.masq6=' "$UCI_STUB_DB" | tail -1)" = "firewall.cfg01.masq6=1" ] && echo "ok: nat66 开 masq6" || { echo "FAIL: nat66 未开 masq6"; FAIL=1; }

# 2) 用户手改 nat66 参数
run_uci() { PATH=$W/bin:$PATH uci "$@"; }
run_uci set network.globals.ula_prefix='fd00:1234::/48'
run_uci set dhcp.lan.ra='hybrid'

# 3) 切 native → nat66 状态被存档，native 套模板
run native >/dev/null
[ -f "$W/etc/config/ipv6mode.d/nat66.state" ] && echo "ok: 切走时保存 nat66" || { echo "FAIL: 未保存 nat66"; FAIL=1; }
grep -q "ula_prefix=fd00:1234::/48" "$W/etc/config/ipv6mode.d/nat66.state" && echo "ok: 存档含用户改动" || { echo "FAIL: 存档未含改动"; FAIL=1; }
[ "$(grep -F 'firewall.cfg01.masq6=' "$UCI_STUB_DB" | tail -1)" != "firewall.cfg01.masq6=1" ] && echo "ok: native 关 masq6" || { echo "FAIL: native 仍有 masq6"; FAIL=1; }

# 4) 家里改 native
run_uci set network.wan6.auto='1'
run_uci set dhcp.lan.dhcpv6='disabled'

# 5) 切回 nat66 → 恢复用户改动
run nat66 >/dev/null
[ "$(grep -F 'network.globals.ula_prefix=' "$UCI_STUB_DB" | tail -1)" = "network.globals.ula_prefix=fd00:1234::/48" ] && echo "ok: nat66 恢复 ULA 改动" || { echo "FAIL: ULA 未恢复"; FAIL=1; }
[ "$(grep -F 'dhcp.lan.ra=' "$UCI_STUB_DB" | tail -1)" = "dhcp.lan.ra=hybrid" ] && echo "ok: nat66 恢复 ra 改动" || { echo "FAIL: ra 未恢复"; FAIL=1; }

# 6) 再回 native → 恢复家里那次改动
run native >/dev/null
[ "$(grep -F 'dhcp.lan.dhcpv6=' "$UCI_STUB_DB" | tail -1)" = "dhcp.lan.dhcpv6=disabled" ] && echo "ok: native 恢复家中改动" || { echo "FAIL: native 改动丢失"; FAIL=1; }

# 7) forget 后回到模板
run forget native >/dev/null
[ -f "$W/etc/config/ipv6mode.d/native.state" ] && { echo "FAIL: forget 未删除"; FAIL=1; } || echo "ok: forget 生效"

[ "$FAIL" = "0" ] && echo "IPV6MEM OK" || echo "IPV6MEM FAILED"
exit $FAIL
