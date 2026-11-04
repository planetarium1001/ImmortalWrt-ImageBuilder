#!/bin/sh
# ac-2：每个 profile 记住自己的受管键手改。
# 在 campus 下手改 → 切 home → 切回 campus，手改值仍在；home 侧同理。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new np-memory
sb_fixture net-anon
sb_profile_world

echo "== campus 下手改两个受管键 =="
sh "$SB_PROFILE" campus >/dev/null 2>&1
uci set firewall.campus_natport.enabled='1'
uci set network.wan6.reqprefix='auto'
eq "站位：natport 已开" '1' "$(uci -q get firewall.campus_natport.enabled)"
eq "站位：reqprefix 手改" 'auto' "$(uci -q get network.wan6.reqprefix)"

echo "== 切到 home =="
rc=0
sh "$SB_PROFILE" home >/dev/null 2>&1 || rc=$?
eq "home 切换成功" '0' "$rc"
eq "home 回到模板：reqprefix 删除" '' "$(uci -q get network.wan6.reqprefix)"
eq "home 回到模板：natport=0" '0' "$(uci -q get firewall.campus_natport.enabled)"
eq "home 不做 NAT66（masq6 删除）" '' "$(uci -q get firewall.@zone[1].masq6)"
eq "campus 存档已生成" 'yes' "$([ -s "$SB_ROOT/etc/netprofile.d/campus.state" ] && echo yes)"
contains "存档里记下了 reqprefix 手改" 'network.wan6.reqprefix=auto' \
	"$(cat "$SB_ROOT/etc/netprofile.d/campus.state")"
contains "存档里记下了 natport 手改" 'firewall.campus_natport.enabled=1' \
	"$(cat "$SB_ROOT/etc/netprofile.d/campus.state")"

echo "== 在 home 下手改，再切回 campus 再切回 home =="
uci set firewall.campus_ntp.enabled='1'
uci set dhcp.lan.ndp='disabled'
rc=0
sh "$SB_PROFILE" campus >/dev/null 2>&1 || rc=$?
eq "切回 campus 成功" '0' "$rc"
eq "campus 手改恢复：reqprefix" 'auto' "$(uci -q get network.wan6.reqprefix)"
eq "campus 手改恢复：natport" '1' "$(uci -q get firewall.campus_natport.enabled)"
eq "campus 模板值仍在：wan6.auto" '1' "$(uci -q get network.wan6.auto)"
eq "campus 模板值仍在：hostname" '*' "$(uci -q get network.wan.hostname)"
eq "campus 模板值仍在：masq6" '1' "$(uci -q get firewall.@zone[1].masq6)"

rc=0
sh "$SB_PROFILE" home >/dev/null 2>&1 || rc=$?
eq "再切 home 成功" '0' "$rc"
eq "home 手改恢复：ntp=1" '1' "$(uci -q get firewall.campus_ntp.enabled)"

echo "== forget ①：非当前档 → 只删存档，当时配置一动不动 =="
# 此刻当前档是 home；丢弃 campus 的存档应只影响"下次切回"，不动当前配置
before=$(sb_uci_cksum)
out=$(sh "$SB_PROFILE" forget campus 2>&1); rc=$?
eq "forget campus（当前在 home）退出 0" '0' "$rc"
eq "campus 存档已删" 'no' "$([ -f "$SB_ROOT/etc/netprofile.d/campus.state" ] && echo yes || echo no)"
eq "当时配置（uci 全量字节）未变" "$before" "$(sb_uci_cksum)"
eq "home 的受管键未被改写：ntp 仍是手改值" '1' "$(uci -q get firewall.campus_ntp.enabled)"
contains "提示下次切回才生效" '下次切回' "$out"
rc=0
sh "$SB_PROFILE" campus >/dev/null 2>&1 || rc=$?
eq "下次切回 campus 成功" '0' "$rc"
eq "非当前档 forget 在切回时生效：reqprefix 回模板" 'no' "$(uci -q get network.wan6.reqprefix)"
eq "非当前档 forget 在切回时生效：natport 回模板" '0' "$(uci -q get firewall.campus_natport.enabled)"

echo "== forget ②：当前档 → 删存档并立即按模板重写受管键 =="
# 当前已在 campus：先手改两个受管键，再 forget campus
uci set firewall.campus_natport.enabled='1'
uci set network.wan6.reqprefix='auto'
eq "站位：natport=1" '1' "$(uci -q get firewall.campus_natport.enabled)"
eq "站位：reqprefix=auto" 'auto' "$(uci -q get network.wan6.reqprefix)"
out=$(sh "$SB_PROFILE" forget campus 2>&1); rc=$?
eq "forget campus（当前就在 campus）退出 0" '0' "$rc"
eq "存档已删" 'no' "$([ -f "$SB_ROOT/etc/netprofile.d/campus.state" ] && echo yes || echo no)"
eq "受管键立即回模板：natport=0" '0' "$(uci -q get firewall.campus_natport.enabled)"
eq "受管键立即回模板：reqprefix=no" 'no' "$(uci -q get network.wan6.reqprefix)"
eq "受管键立即回模板：hostname" '*' "$(uci -q get network.wan.hostname)"
eq "受管键立即回模板：masq6" '1' "$(uci -q get firewall.@zone[1].masq6)"
contains "提示已立即重写" '立即按模板重写' "$out"
eq "profile 标记仍是 campus" 'campus' "$(cat "$SB_ROOT/etc/netprofile" 2>/dev/null)"

echo "== forget ②之后：切走再切回也不带回手改 =="
sh "$SB_PROFILE" home >/dev/null 2>&1
rc=0
sh "$SB_PROFILE" campus >/dev/null 2>&1 || rc=$?
eq "再切回 campus 成功" '0' "$rc"
eq "手改未复活：natport" '0' "$(uci -q get firewall.campus_natport.enabled)"
eq "手改未复活：reqprefix" 'no' "$(uci -q get network.wan6.reqprefix)"

finish NETPROFILE-MEMORY
