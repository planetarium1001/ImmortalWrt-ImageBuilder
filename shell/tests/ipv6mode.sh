#!/bin/sh
# ipv6mode 现在是**薄壳**（IPv6 维度已并入 netprofile）。
# 旧用例断言的是已删除的 save_state/restore_state 与 /etc/config/ipv6mode.d，
# 这里改成断言"转发行为"：nat66→campus、native→home、off→只关 IPv6 维度。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new ipv6
sb_fixture net-anon
sb_profile_world
NET=$UCI_STUB_DIR/network

echo "== nat66 → netprofile campus =="
rc=0
sh "$SB_IPV6MODE" nat66 >/dev/null 2>&1 || rc=$?
eq "nat66 退出 0" '0' "$rc"
eq "profile 标记为 campus" 'campus' "$(cat "$SB_ROOT/etc/netprofile" 2>/dev/null)"
eq "wan6.auto=1（V1：nat66 必须让 wan6 自启动）" '1' "$(uci -q get network.wan6.auto)"
eq "wan6.reqprefix=no（不请 PD）" 'no' "$(uci -q get network.wan6.reqprefix)"
eq "ula_prefix 已写" 'fd7a:6e64:6c35::/48' "$(uci -q get network.globals.ula_prefix)"
eq "masq6=1" '1' "$(uci -q get firewall.@zone[1].masq6)"
eq "dhcp.lan.ra=server" 'server' "$(uci -q get dhcp.lan.ra)"
eq "不再写旧存档目录" 'no' "$([ -d "$SB_ROOT/etc/config/ipv6mode.d" ] && echo yes || echo no)"
eq "不再写旧状态文件" 'no' "$([ -f "$SB_ROOT/etc/config/ipv6mode" ] && echo yes || echo no)"

echo "== status → netprofile status =="
out=$(sh "$SB_IPV6MODE" status 2>&1); rc=$?
eq "status 退出 0" '0' "$rc"
contains "status 报 profile" 'profile: campus' "$out"
contains "status 报受管键" '受管键（16' "$out"

echo "== native → home =="
rc=0
sh "$SB_IPV6MODE" native >/dev/null 2>&1 || rc=$?
eq "native 退出 0" '0' "$rc"
eq "profile 标记为 home" 'home' "$(cat "$SB_ROOT/etc/netprofile" 2>/dev/null)"
eq "home 不做 NAT66（masq6 删除）" '' "$(uci -q get firewall.@zone[1].masq6)"
eq "home 不写 ULA" '' "$(uci -q get network.globals.ula_prefix)"

echo "== off：只关 IPv6 维度，不写存档 =="
rc=0
sh "$SB_IPV6MODE" off >/dev/null 2>&1 || rc=$?
eq "off 退出 0" '0' "$rc"
eq "wan6.auto=0" '0' "$(uci -q get network.wan6.auto)"
eq "wan6.proto 仍是 dhcpv6" 'dhcpv6' "$(uci -q get network.wan6.proto)"
eq "wan6.reqprefix 删除" '' "$(uci -q get network.wan6.reqprefix)"
eq "ula_prefix 删除" '' "$(uci -q get network.globals.ula_prefix)"
eq "dhcp.lan.ra=disabled" 'disabled' "$(uci -q get dhcp.lan.ra)"
eq "dhcp.lan.dhcpv6=disabled" 'disabled' "$(uci -q get dhcp.lan.dhcpv6)"
eq "dhcp.lan.ra_flags 删除" '' "$(uci -q get dhcp.lan.ra_flags)"
eq "masq6 删除" '' "$(uci -q get firewall.@zone[1].masq6)"
eq "profile 标记已清除（off 不被记住）" 'no' "$([ -f "$SB_ROOT/etc/netprofile" ] && echo yes || echo no)"

echo "== forget nat66 → netprofile forget campus =="
sh "$SB_PROFILE" campus >/dev/null 2>&1
eq "站位：campus 存档存在" 'yes' "$([ -f "$SB_ROOT/etc/netprofile.d/campus.state" ] && echo yes || echo no)"
sh "$SB_IPV6MODE" forget nat66 >/dev/null 2>&1; rc=$?
eq "forget nat66 退出 0" '0' "$rc"
eq "campus 存档已删" 'no' "$([ -f "$SB_ROOT/etc/netprofile.d/campus.state" ] && echo yes || echo no)"
sh "$SB_IPV6MODE" forget native >/dev/null 2>&1; rc=$?
eq "forget native 退出 0" '0' "$rc"

echo "== 参数校验与旧存档提示 =="
sh "$SB_IPV6MODE" bogus >/dev/null 2>&1; rc=$?
eq "未知子命令退出 2" '2' "$rc"
sh "$SB_IPV6MODE" >/dev/null 2>&1; rc=$?
eq "无参数打印用法并退出 2" '2' "$rc"
mkdir -p "$SB_ROOT/etc/config/ipv6mode.d"
out=$(sh "$SB_IPV6MODE" status 2>&1)
contains "检测到旧存档时给出废弃提示" '已废弃' "$out"

finish IPV6MODE
