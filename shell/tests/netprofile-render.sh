#!/bin/sh
# 换 WAN 口后必须重渲染防检测片段（独立审计 P2 的回归保护）。
# 断言三件事：
#   1) 首次 campus 渲染出的 oifname 与当时的 wan.device 一致
#   2) 纯幂等再跑：不新增 reload、产物不变
#   3) wan.device 改口后再跑：片段跟到新口，且恰好新增一次 firewall reload
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new np-render
sb_fixture net-anon
sb_profile_world
NFTDIR=$SB_ROOT/etc/campus/nft
TTL=$NFTDIR/10-ttl.nft
NOL=$NFTDIR/20-noleak.nft

has_wan() { # 文件 口名
	grep -q "oifname \"$2\"" "$1" 2>/dev/null && echo yes || echo no
}

echo "== 首次 campus 按当前 WAN 渲染 =="
out=$(sh "$SB_PROFILE" campus 2>&1); rc=$?
eq "退出 0" '0' "$rc"
eq "wan.device 是 eth0" 'eth0' "$(uci -q get network.wan.device)"
eq "ttl 片段用 eth0" 'yes' "$(has_wan "$TTL" eth0)"
eq "noleak 片段用 eth0" 'yes' "$(has_wan "$NOL" eth0)"

echo "== 纯幂等再跑：不重写、不 reload =="
rcount=$(sb_reload_count)
md5_before=$(cksum <"$TTL")
out2=$(sh "$SB_PROFILE" campus 2>&1); rc=$?
eq "第二次退出 0" '0' "$rc"
contains "第二次提示无需切换" '无需切换' "$out2"
eq "产物未变" "$md5_before" "$(cksum <"$TTL")"
eq "未新增 reload" "$rcount" "$(sb_reload_count)"

echo "== 换口后重渲染 =="
uci set network.wan.device='eth1' >/dev/null 2>&1
uci set network.wan6.device='eth1' >/dev/null 2>&1
uci commit network >/dev/null 2>&1
out3=$(sh "$SB_PROFILE" campus 2>&1); rc=$?
eq "换口后退出 0" '0' "$rc"
eq "ttl 片段跟到 eth1" 'yes' "$(has_wan "$TTL" eth1)"
eq "noleak 片段跟到 eth1" 'yes' "$(has_wan "$NOL" eth1)"
eq "旧口不再出现" 'no' "$(has_wan "$TTL" eth0)"
eq "恰好新增一次 reload" "$((rcount + 1))" "$(sb_reload_count)"
eq "新增的是 firewall reload" 'firewall reload' \
	"$(sb_reloads | tail -n1)"

finish NETPROFILE-RENDER
