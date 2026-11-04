#!/bin/sh
# PRD「apply 失败必须自动回滚」的失败注入用例（三条路径，不修改被测脚本）：
#   1) reload 失败（/etc/init.d/firewall 桩返回 1）
#   2) render 失败（/etc/campus/nft/render.sh 返回 1）
#   3) uci commit 失败（uci 包装器拦截 commit）
#
# 每条路径都断言三件事，且都是"能失败"的断言：
#   * 退出码非 0，stderr 说明失败原因并声明已回滚；
#   * **逐键**比对 16 个受管键全部回到切换前的值（不是看单个键、不是看文件存在）；
#   * /etc/netprofile 保持不变（仍是切换前 profile 名；从未切换过时仍不存在）。
#
# 注意：这里**不对** include 段的 chain 取值做断言（campus_noleak/campus_conncap 的
# chain 由 98-campus-nft 单元调整，属 campus-rules-scope.sh 的职责），只看 enabled。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

# netprofile 的受管键白名单（16 项；与 netprofile 的 BASE_KEYS + masq6 + 5 个 include 一致）
KEYS='network.wan.proto network.wan.hostname
network.wan6.proto network.wan6.auto network.wan6.reqprefix
network.globals.ula_prefix
dhcp.lan.ra dhcp.lan.dhcpv6 dhcp.lan.ndp dhcp.lan.ra_flags
firewall.@zone[1].masq6
firewall.campus_ttl.enabled firewall.campus_noleak.enabled
firewall.campus_natport.enabled firewall.campus_ntp.enabled firewall.campus_conncap.enabled'
INCLUDES='campus_ttl campus_noleak campus_natport campus_ntp campus_conncap'

snap_keys() { # 受管键现值快照（每行 key=value，未设置为空串）
	for _k in $KEYS; do
		printf '%s=%s\n' "$_k" "$(uci -q get "$_k" 2>/dev/null)"
	done
}

cmp_keys() { # <标签> <快照文件>：逐键比对，任一不同就 FAIL
	_tag=$1
	_f=$2
	for _k in $KEYS; do
		_w=$(awk -F= -v k="$_k" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$_f")
		_g=$(uci -q get "$_k" 2>/dev/null)
		eq "$_tag 回滚后 $_k" "$_w" "$_g"
	done
}

inject_initd_fail() { # <name>：把沙盒里的 /etc/init.d/<name> 换成退出 1 的桩
	cat >"$SB_ROOT/etc/init.d/$1" <<'EOS'
#!/bin/sh
echo "$(basename "$0") $* (injected fail)" >>"$SB_RELOADS"
exit 1
EOS
	chmod +x "$SB_ROOT/etc/init.d/$1"
}

################ 路径 1：reload 失败 ################
echo "== 路径 1：firewall reload 失败 =="
sb_new np-rb-reload
sb_fixture net-anon
sb_profile_world
sh "$SB_PROFILE" home >/dev/null 2>&1
eq "站位：当前 profile=home" 'home' "$(cat "$SB_ROOT/etc/netprofile" 2>/dev/null)"
snap_keys >"$SB_ROOT/before.keys"
inject_initd_fail firewall

out=$(sh "$SB_PROFILE" campus 2>&1); rc=$?
ne "退出码非 0" '0' "$rc"
contains "报 reload 失败" 'reload 失败' "$out"
contains "声明开始回滚" '回滚' "$out"
contains "声明已回滚到切换前状态" '已回滚到切换前状态' "$out"
cmp_keys "reload 失败" "$SB_ROOT/before.keys"
eq "/etc/netprofile 仍是 home" 'home' "$(cat "$SB_ROOT/etc/netprofile" 2>/dev/null)"
eq "没有把 campus 的 profile 名写进去" '' "$(grep -v '^home$' "$SB_ROOT/etc/netprofile" 2>/dev/null)"

################ 路径 2：render 失败 ################
echo "== 路径 2：render.sh 失败（应从没到过 enabled=1）=="
sb_new np-rb-render
sb_fixture net-anon
sb_profile_world
eq "站位：还没有 profile 标记" 'no' "$([ -f "$SB_ROOT/etc/netprofile" ] && echo yes || echo no)"
for _s in $INCLUDES; do
	eq "站位：firewall.$_s.enabled 初始为 0" '0' "$(uci -q get "firewall.$_s.enabled")"
done
snap_keys >"$SB_ROOT/before.keys"

cat >"$SB_ROOT/etc/campus/nft/render.sh" <<'EOS'
#!/bin/sh
echo "campus-nft: 注入的渲染失败" >&2
exit 1
EOS
chmod +x "$SB_ROOT/etc/campus/nft/render.sh"

out=$(sh "$SB_PROFILE" campus 2>&1); rc=$?
ne "退出码非 0" '0' "$rc"
contains "报渲染失败" '渲染失败' "$out"
contains "声明开始回滚" '回滚' "$out"
for _s in $INCLUDES; do
	eq "render 失败后 firewall.$_s.enabled 未被置 1" '0' "$(uci -q get "firewall.$_s.enabled")"
done
cmp_keys "render 失败" "$SB_ROOT/before.keys"
eq "/etc/netprofile 仍未生成" 'no' "$([ -f "$SB_ROOT/etc/netprofile" ] && echo yes || echo no)"

################ 路径 3：uci commit 失败 ################
echo "== 路径 3：uci commit 失败 =="
sb_new np-rb-commit
sb_fixture net-anon
sb_profile_world
sh "$SB_PROFILE" home >/dev/null 2>&1
eq "站位：当前 profile=home" 'home' "$(cat "$SB_ROOT/etc/netprofile" 2>/dev/null)"
snap_keys >"$SB_ROOT/before.keys"

# 注入：uci 包装器把所有 commit 子命令变成失败，其余原样转给真 UCI 语义 fake
cat >"$SB_ROOT/bin/uci" <<EOS
#!/bin/sh
for _a in "\$@"; do
	case "\$_a" in
	commit) echo "uci: 注入的 commit 失败" >&2; exit 1 ;;
	esac
done
exec sh "$TS_DIR/lib-uci-stub.sh" "\$@"
EOS
chmod +x "$SB_ROOT/bin/uci"

out=$(sh "$SB_PROFILE" campus 2>&1); rc=$?
ne "退出码非 0" '0' "$rc"
contains "报 commit 失败" 'uci commit 失败' "$out"
contains "声明开始回滚" '回滚' "$out"
cmp_keys "commit 失败" "$SB_ROOT/before.keys"
eq "/etc/netprofile 仍是 home" 'home' "$(cat "$SB_ROOT/etc/netprofile" 2>/dev/null)"
eq "没有把 campus 的 profile 名写进去" '' "$(grep -v '^home$' "$SB_ROOT/etc/netprofile" 2>/dev/null)"

finish NETPROFILE-ROLLBACK
