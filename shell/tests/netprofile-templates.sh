#!/bin/sh
# ac-3：campus/home 模板值逐键断言（表驱动，多一个少一个都算失败）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new np-tpl
sb_fixture net-anon
sb_profile_world

# 期望表：key=value；值 '-' 表示该键在 uci 里不存在
expect_vals() { # <标签> key=value ...
	_tag=$1
	shift
	for _kv in "$@"; do
		_k=${_kv%%=*}
		_v=${_kv#*=}
		# 期望值 '-' 表示该键必须不存在
		[ "$_v" = '-' ] && _v=''
		eq "$_tag $_k" "$_v" "$(uci -q get "$_k" 2>/dev/null)"
	done
}

echo "== campus 模板 =="
rc=0
sh "$SB_PROFILE" campus >/dev/null 2>&1 || rc=$?
eq "campus 切换成功" '0' "$rc"
expect_vals campus \
	network.wan.proto=dhcp \
	network.wan.hostname='*' \
	network.wan6.proto=dhcpv6 \
	network.wan6.auto=1 \
	network.wan6.reqprefix=no \
	network.globals.ula_prefix=fd7a:6e64:6c35::/48 \
	dhcp.lan.ra=server \
	dhcp.lan.dhcpv6=server \
	dhcp.lan.ndp=disabled \
	'dhcp.lan.ra_flags=managed-config other-config' \
	firewall.@zone[1].masq6=1 \
	firewall.campus_ttl.enabled=1 \
	firewall.campus_noleak.enabled=1 \
	firewall.campus_natport.enabled=0 \
	firewall.campus_ntp.enabled=0 \
	firewall.campus_conncap.enabled=0

echo "== 受管键恰好 16 项（status 自报数量）=="
contains "status 报 16 个受管键" '受管键（16' "$(sh "$SB_PROFILE" status 2>&1)"
for _b in 10-ttl 20-noleak 40-ntp 50-conncap; do
	eq "渲染出 $_b.nft" 'yes' "$([ -f "$SB_ROOT/etc/campus/nft/$_b.nft" ] && echo yes || echo no)"
done
eq "渲染产物里没有残留占位符" '0' \
	"$(cat "$SB_ROOT"/etc/campus/nft/*.nft 2>/dev/null | grep -c '@WAN@\|@LAN_IF@' || true)"
contains "渲染用上了真实 WAN 设备名" 'oifname "eth0"' \
	"$(cat "$SB_ROOT/etc/campus/nft/10-ttl.nft" 2>/dev/null)"

echo "== home 模板 =="
rc=0
sh "$SB_PROFILE" home >/dev/null 2>&1 || rc=$?
eq "home 切换成功" '0' "$rc"
expect_vals home \
	network.wan.proto=dhcp \
	network.wan.hostname=- \
	network.wan6.proto=dhcpv6 \
	network.wan6.auto=1 \
	network.wan6.reqprefix=- \
	network.globals.ula_prefix=- \
	dhcp.lan.ra=server \
	dhcp.lan.dhcpv6=server \
	dhcp.lan.ndp=disabled \
	dhcp.lan.ra_flags=- \
	firewall.@zone[1].masq6=- \
	firewall.campus_ttl.enabled=0 \
	firewall.campus_noleak.enabled=0 \
	firewall.campus_natport.enabled=0 \
	firewall.campus_ntp.enabled=0 \
	firewall.campus_conncap.enabled=0

echo "== 切换回的 campus 仍是模板（未被 home 污染）=="
sh "$SB_PROFILE" campus >/dev/null 2>&1
expect_vals campus2 \
	network.wan.hostname='*' \
	network.wan6.reqprefix=no \
	network.globals.ula_prefix=fd7a:6e64:6c35::/48 \
	firewall.@zone[1].masq6=1
# home 的存档不该改变 campus 的模板值
eq "campus 下 ula_prefix 未沿用 home 的'-'" 'fd7a:6e64:6c35::/48' "$(uci -q get network.globals.ula_prefix)"

finish NETPROFILE-TEMPLATES
