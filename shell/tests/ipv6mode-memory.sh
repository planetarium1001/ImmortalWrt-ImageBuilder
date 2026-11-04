#!/bin/sh
# IPv6 三态的记忆能力（原 ac-4）现在由 netprofile 的存档提供，ipv6mode 只是映射：
#   在 nat66 下手改 → 切 native → 切回 nat66，手改仍在；home 侧同理。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new ipv6-mem
sb_fixture net-anon
sb_profile_world

echo "== 例 1：nat66 下手改 → native → nat66 =="
sh "$SB_IPV6MODE" nat66 >/dev/null 2>&1
eq "nat66 初始模板：ula" 'fd7a:6e64:6c35::/48' "$(uci -q get network.globals.ula_prefix)"
uci set network.globals.ula_prefix='fd00:1234::/48'
uci set dhcp.lan.ra='hybrid'
rc=0
sh "$SB_IPV6MODE" native >/dev/null 2>&1 || rc=$?
eq "切 native 成功" '0' "$rc"
eq "native 用模板：ula 删除" '' "$(uci -q get network.globals.ula_prefix)"
eq "native 用模板：ra=server" 'server' "$(uci -q get dhcp.lan.ra)"
eq "campus 存档存在" 'yes' "$([ -s "$SB_ROOT/etc/netprofile.d/campus.state" ] && echo yes)"
contains "存档含 ula 手改" 'network.globals.ula_prefix=fd00:1234::/48' \
	"$(cat "$SB_ROOT/etc/netprofile.d/campus.state")"
contains "存档含 ra 手改" 'dhcp.lan.ra=hybrid' "$(cat "$SB_ROOT/etc/netprofile.d/campus.state")"

rc=0
sh "$SB_IPV6MODE" nat66 >/dev/null 2>&1 || rc=$?
eq "切回 nat66 成功" '0' "$rc"
eq "nat66 恢复 ula 手改" 'fd00:1234::/48' "$(uci -q get network.globals.ula_prefix)"
eq "nat66 恢复 ra 手改" 'hybrid' "$(uci -q get dhcp.lan.ra)"
eq "nat66 恢复 masq6" '1' "$(uci -q get firewall.@zone[1].masq6)"

echo "== 例 2：native 下手改 → nat66 → native =="
sh "$SB_IPV6MODE" native >/dev/null 2>&1   # 先站到 home
eq "站位：当前是 home" 'home' "$(cat "$SB_ROOT/etc/netprofile")"
uci set dhcp.lan.dhcpv6='disabled'
uci set network.wan6.auto='0'
sh "$SB_IPV6MODE" nat66 >/dev/null 2>&1
eq "nat66 期间 wan6.auto 回到 1（home 手改不影响 campus）" '1' "$(uci -q get network.wan6.auto)"
rc=0
sh "$SB_IPV6MODE" native >/dev/null 2>&1 || rc=$?
eq "切回 native 成功" '0' "$rc"
eq "native 恢复 dhcpv6 手改" 'disabled' "$(uci -q get dhcp.lan.dhcpv6)"
eq "native 恢复 wan6.auto 手改" '0' "$(uci -q get network.wan6.auto)"

echo "== 例 3：非当前档 forget → 切回时重套模板 =="
# 此刻当前档是 home（例 2 结束在 native）
before=$(sb_uci_cksum)
sh "$SB_IPV6MODE" forget nat66 >/dev/null 2>&1; rc=$?
eq "forget nat66（当前在 home）退出 0" '0' "$rc"
eq "campus 存档已删" 'no' "$([ -f "$SB_ROOT/etc/netprofile.d/campus.state" ] && echo yes || echo no)"
eq "非当前档 forget 不动当前配置" "$before" "$(sb_uci_cksum)"
rc=0
sh "$SB_IPV6MODE" nat66 >/dev/null 2>&1 || rc=$?
eq "切回 nat66 成功" '0' "$rc"
eq "切回后 ula 回到模板" 'fd7a:6e64:6c35::/48' "$(uci -q get network.globals.ula_prefix)"
eq "切回后 ra 回到模板" 'server' "$(uci -q get dhcp.lan.ra)"

echo "== 例 4：当前档 forget（ipv6mode forget nat66 映射到 netprofile forget campus）=="
uci set network.globals.ula_prefix='fd00:9999::/48'
uci set network.wan6.reqprefix='auto'
out=$(sh "$SB_IPV6MODE" forget nat66 2>&1); rc=$?
eq "当前档 forget 退出 0" '0' "$rc"
eq "ula 立即回到模板" 'fd7a:6e64:6c35::/48' "$(uci -q get network.globals.ula_prefix)"
eq "reqprefix 立即回到模板" 'no' "$(uci -q get network.wan6.reqprefix)"
eq "campus 存档已删" 'no' "$([ -f "$SB_ROOT/etc/netprofile.d/campus.state" ] && echo yes || echo no)"

finish IPV6MEM
