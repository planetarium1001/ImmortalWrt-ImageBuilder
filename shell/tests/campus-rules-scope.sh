#!/bin/sh
# ac-7（离线等价断言）：防检测规则只在 campus 生效
#
# 真机判据是 `nft list ruleset | grep -c '!campus'`（campus>0 / home=0）。本机没有 nft，
# 因此这里断言**决定真机结果的那几个事实**：
#   1. 五个片段/模板都存在，且规则行数 == 带 `!campus:` 注释的行数
#   2. 规则行里不出现 67/68（DHCP），不复刻历史 bug
#   3. campus 一档两项取 1、二档三项取 0；home 五项全 0
#   4. include 段的 position/chain/路径与 design 一致
# 真机实测见 handoff.md 的部署清单（刷机后逐条打勾）。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D="$ROOT/files/etc/campus/nft"
NP="$ROOT/files/usr/sbin/netprofile"
INIT="$ROOT/files/etc/uci-defaults/98-campus-nft.sh"
FAIL=0

ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; FAIL=1; }

for f in 10-ttl.nft.tmpl 20-noleak.nft.tmpl 30-srcport.nft 40-ntp.nft.tmpl 50-conncap.nft.tmpl; do
	if [ ! -f "$D/$f" ]; then bad "缺片段 ${f}"; continue; fi
	rules=$(grep -vcE '^[[:space:]]*(#|$)' "$D/$f")
	marks=$(grep -c 'comment "!campus:' "$D/$f")
	if [ "$rules" -ge 1 ] && [ "$marks" -eq "$rules" ]; then
		ok "${f}：规则 $rules 条，全部带 !campus 标记"
	else
		bad "${f}：规则 $rules 条，带标记的只有 $marks 条"
	fi
done

if grep -hE '^[[:space:]]*[^#[:space:]]' "$D"/*.nft "$D"/*.tmpl 2>/dev/null \
	| grep -qE 'dport[^;]*\b(67|68)\b'; then
	bad "规则行里出现 67/68（会砍掉自己的 DHCP）"
else
	ok "规则行未触碰 67/68"
fi

tier1=$(grep -n '\*:firewall\.campus_ttl\.enabled | \*:firewall\.campus_noleak\.enabled)' "$NP" | cut -d: -f1)
if [ -n "$tier1" ] && sed -n "${tier1},$((tier1 + 3))p" "$NP" | grep -q "= 'campus' \]; then printf '%s' '1'"; then
	ok "一档（ttl/noleak）：campus=1、其它=0"
else
	bad "一档分支不是「campus=1 否则 0」"
fi
tier2=$(grep -n '\*:firewall\.campus_natport\.enabled | \*:firewall\.campus_ntp\.enabled | \*:firewall\.campus_conncap\.enabled)' "$NP" | cut -d: -f1)
if [ -n "$tier2" ] && sed -n "${tier2},$((tier2 + 2))p" "$NP" | grep -q "printf '%s' '0'"; then
	ok "二档（natport/ntp/conncap）：两套 profile 均为 0"
else
	bad "二档分支不是恒 0"
fi

need() {
	if grep -qE "^add_include[[:space:]]+$1[[:space:]]+.*[[:space:]]$2[[:space:]]+$3\$" "$INIT"; then
		ok "$1 → $2 / $3"
	else
		bad "$1 的 position/chain 不是 $2 / $3"
	fi
}
need campus_ttl      chain-append   mangle_forward
need campus_noleak   chain-append   mangle_forward
need campus_natport  chain-prepend  srcnat_wan
need campus_ntp      chain-append   dstnat
need campus_conncap  chain-append   mangle_forward

for pair in "campus_ttl:10-ttl.nft" "campus_noleak:20-noleak.nft" "campus_natport:30-srcport.nft" "campus_ntp:40-ntp.nft" "campus_conncap:50-conncap.nft"; do
	s=${pair%%:*}; f=${pair##*:}
	grep -qE "^add_include[[:space:]]+$s[[:space:]]+.*/$f" "$INIT" \
		&& ok "$s 指向 $f" || bad "$s 没有指向 $f"
done

echo "---"
if [ "$FAIL" = "0" ]; then
	echo "真机待办: nft list ruleset | grep -c '!campus'   (campus>0；netprofile home 后 =0)"
	echo "CAMPUS-RULES-SCOPE OK"
	exit 0
fi
echo "CAMPUS-RULES-SCOPE FAILED"
exit 1
