#!/bin/sh
# 回归守卫：98-campus-nft.sh 写进 UCI 的 include 段必须"干净"。
#
# 背景（2026-11-05 真机实测）：脚本原先把 `uci set "firewall.$_name.type='nftables'"`
# 写在双引号里，内层单引号被**原样写进 UCI**，于是段值成了 `'nftables'`（带引号）。
# fw4 解析 include 类型失败后**整份 ruleset 渲染中止**（前一行还只是 warn：
# `option 'type' specifies invalid value ''nftables''`，紧接着
# `left-hand side expression is not an array or object` → fw4.uc:3289 `if (!inc.enabled)`），
# 结果是 NAT 与转发全都没有：只有路由器自己能上网，LAN/WiFi 客户端全断。
#
# 本用例**真的执行脚本**（沙盒 + libuci 语义的 uci fake），然后断言：
#   ① 五个 include 段的 type/position/chain/path/enabled 逐字正确；
#   ② 任何段值里都不含引号（本次事故的直接特征）；
#   ③ type 是 fw4 枚举里的合法值、position 是 fw4 认的 position 值；
#   ④ 重复执行不改动已有段（脚本自称幂等）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

S="$REPO/files/etc/uci-defaults/98-campus-nft.sh"
[ -f "$S" ] || { bad "缺脚本 $S"; echo "CAMPUS-INCLUDE FAILED"; exit 1; }

sb_new campus-inc
LOG="$SB_ROOT/campus.log"
D=$(sb_script "$S" etc/uci-defaults/98-campus-nft.sh)

echo "== 首次执行 =="
CAMPUS_LOG="$LOG" sh "$D" >/dev/null 2>&1
eq "脚本退出 0" '0' "$?"

uci_get() { uci -q get "firewall.$1.$2" 2>/dev/null; }

expect_sec() { # <段名> <position> <chain> <path>
	eq "$1.type 是 nftables（无引号）" 'nftables' "$(uci_get "$1" type)"
	eq "$1.position" "$2" "$(uci_get "$1" position)"
	eq "$1.chain" "$3" "$(uci_get "$1" chain)"
	# 沙盒里 sb_script 会把 /etc/ 前缀改写成 $SB_ROOT/etc/，所以路径断言跟着沙盒走；
	# 真机路径本身另由"源文件逐字包含"这条断言守住。
	eq "$1.path（沙盒内）" "$SB_ROOT$4" "$(uci_get "$1" path)"
	eq "$1.enabled 默认 0" '0' "$(uci_get "$1" enabled)"
}

expect_sec campus_ttl     chain-append  mangle_forward /etc/campus/nft/10-ttl.nft
expect_sec campus_noleak  chain-append  mangle_forward /etc/campus/nft/20-noleak.nft
expect_sec campus_natport chain-prepend srcnat_wan     /etc/campus/nft/30-srcport.nft
expect_sec campus_ntp     chain-append  dstnat         /etc/campus/nft/40-ntp.nft
expect_sec campus_conncap chain-append  mangle_forward /etc/campus/nft/50-conncap.nft

echo "== 静态守卫：uci set 的参数里不许出现内层引号 =="
# 这是本类 bug 的直接特征，也是唯一可靠的判据：uci fake 对"值里带引号"的容忍度
# 与真 uci 不完全一致（实测它会把 type 的引号吃掉、path 的留着），所以行为断言只能兜底。
q_lines=$(grep -nE 'uci set "firewall\.\$_name\.[a-z]+='"'"'|uci set "firewall\.\$_name\.[a-z]+="[^"]*'"'"'' "$S" || true)
eq "uci set 参数无内层引号" '' "$q_lines"

echo "== 值里不许有内层引号（行为兜底） =="
# uci show 的输出形如 firewall.campus_ttl.type='nftables'；
# 事故版本是 type=''nftables''（外层引号里还套了一层）⇒ 剥掉最外层后仍含引号即失败。
inner=$(uci show firewall 2>/dev/null \
	| sed -n "s/^firewall\.campus_[a-z]*\.[a-z]*=//p" \
	| sed -e "s/^'\(.*\)'\$/\\1/" \
	| grep -F "'" || true)
eq "include 段值无内层引号" '' "$inner"

echo "== type / position 必须在 fw4 的枚举内 =="
bad_types=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.campus_[a-z]*\.type='\(.*\)'$/\1/p" | grep -vxE 'nftables|script|restore' || true)
eq "type 取值合法" '' "$bad_types"
bad_pos=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.campus_[a-z]*\.position='\(.*\)'$/\1/p" \
	| grep -vxE 'ruleset-prepend|ruleset-append|table-prepend|table-append|chain-prepend|chain-append' || true)
eq "position 取值合法（fw4 只认 pre/append 系列）" '' "$bad_pos"

echo "== 真机路径（NFTDIR 必须指向 /etc/campus/nft，且五个片段都引用它） =="
grep -q '^NFTDIR=/etc/campus/nft$' "$S" && ok "NFTDIR=/etc/campus/nft" || bad "NFTDIR 不是 /etc/campus/nft"
for f in 10-ttl.nft 20-noleak.nft 30-srcport.nft 40-ntp.nft 50-conncap.nft; do
	grep -q "\$NFTDIR/$f" "$S" && ok "引用片段 $f" || bad "缺片段引用 $f"
done

echo "== 幂等：再跑一次不改动已有段 =="
before=$(uci show firewall 2>/dev/null | grep '^firewall\.campus_')
CAMPUS_LOG="$LOG" sh "$D" >/dev/null 2>&1
eq "第二次执行退出 0" '0' "$?"
after=$(uci show firewall 2>/dev/null | grep '^firewall\.campus_')
eq "已有段逐字未变" "$before" "$after"
grep -q '已存在，跳过' "$LOG" && ok "日志记录了跳过" || bad "缺跳过日志"

finish CAMPUS-INCLUDE
