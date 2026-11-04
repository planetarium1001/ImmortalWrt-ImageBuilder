#!/bin/sh
# ac-1：netprofile 无参数等价 campus；status 输出当前 profile 与受管键实际值；
# 连跑两次幂等（第二次不再写配置、不再 reload）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new np-switch
sb_fixture net-anon
sb_profile_world
NET=$UCI_STUB_DIR/network

echo "== 无参数等价 campus =="
out=$(sh "$SB_PROFILE" 2>&1); rc=$?
eq "退出 0" '0' "$rc"
contains "提示已切换到 campus" '已切换到 campus' "$out"
eq "profile 标记文件" 'campus' "$(cat "$SB_ROOT/etc/netprofile" 2>/dev/null)"
eq "wan6.auto=1" '1' "$(uci -q get network.wan6.auto)"
eq "一档 include 已开" '1' "$(uci -q get firewall.campus_ttl.enabled)"
contains "reload 顺序 network 在前" 'network reload' "$(sb_reloads)"
contains "reload 顺序 firewall 在后" 'firewall reload' "$(sb_reloads)"
eq "reload 顺序正确（network 行号 < firewall 行号）" 'yes' \
	"$(awk '/^network reload/{n=NR} /^firewall reload/{f=NR} END{print (n && f && n < f) ? "yes" : "no"}' "$SB_RELOADS")"

echo "== 连跑两次幂等 =="
before=$(cksum <"$NET")
rcount=$(sb_reload_count)
out2=$(sh "$SB_PROFILE" 2>&1); rc=$?
eq "第二次退出 0" '0' "$rc"
contains "第二次提示无需切换" '无需切换' "$out2"
eq "第二次未新增 reload" "$rcount" "$(sb_reload_count)"
eq "第二次配置逐字节未变" "$before" "$(cksum <"$NET")"

echo "== status =="
out=$(sh "$SB_PROFILE" status 2>&1); rc=$?
eq "status 退出 0" '0' "$rc"
contains "status 报 profile" 'profile: campus' "$out"
contains "status 报受管键数量" '受管键（16' "$out"
contains "status 列出 masq6" 'firewall.@zone[1].masq6' "$out"
contains "status 列出 ula_prefix" 'network.globals.ula_prefix' "$out"
contains "status 标出一致性" '一致(' "$out"
eq "status 只读（配置未变）" "$before" "$(cksum <"$NET")"

echo "== 参数校验 =="
sh "$SB_PROFILE" bogus >/dev/null 2>&1; rc=$?
eq "未知子命令退出 2" '2' "$rc"
sh "$SB_PROFILE" forget >/dev/null 2>&1; rc=$?
eq "forget 缺参数退出 2" '2' "$rc"

finish NETPROFILE-SWITCH
