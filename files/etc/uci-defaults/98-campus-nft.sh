#!/bin/sh
# 首次启动执行一次（uci-defaults 语义：成功后自删）。
# 职责：只 add 不覆盖地创建 campus 防检测规则的 fw4 include 段，全部 enabled='0'。
#   - 规则本体在 /etc/campus/nft/*.nft（由同目录 render.sh 从 *.nft.tmpl 渲染）；
#   - 开启/关闭由 netprofile 用 `uci set firewall.<段名>.enabled='0|1'` 完成，
#     不需要改任何文件；
#   - 本脚本先于 99-custom.sh 执行，此时 WAN 设备名还没定，所以这里**不渲染**片段，
#     也不启用任何规则。真正生效链路：netprofile 切换 campus → render.sh → enabled=1
#     → fw4 reload。
#
# 幂等：同名段已存在则整段跳过（不动用户已改过的值），可反复执行。

LOGFILE="${CAMPUS_LOG:-/etc/config/uci-defaults-log.txt}"
log() { echo "$(date '+%F %T') $*" >>"$LOGFILE" 2>/dev/null; }

NFTDIR=/etc/campus/nft
created=0
failed=0

# add_include <段名> <片段路径> <position> <chain>
add_include() {
	_name=$1
	_path=$2
	_pos=$3
	_chain=$4

	if [ -n "$(uci -q get "firewall.$_name" 2>/dev/null)" ]; then
		log "include $_name 已存在，跳过（保留现有值）"
		return 0
	fi

	if ! uci set "firewall.$_name=include"; then
		log "WARN: 创建 include $_name 失败"
		failed=$((failed + 1))
		return 1
	fi
	# 注意：值里**不能**带引号。整行在双引号内，内层单引号会原样写进 UCI，
	# 得到 type="'nftables'" 这种值 —— fw4 解析 include 类型失败后整份 ruleset
	# 渲染中止（表现为 NAT/转发全丢，只有路由器自己能上网）。
	# 2026-11-05 真机实测：config include 的五项全部被引号污染，fw4 报
	#   "option 'type' specifies invalid value ''nftables''" + "left-hand side
	#    expression is not an array or object"。改动前务必保持下列写法无内层引号。
	uci set "firewall.$_name.type=nftables"
	uci set "firewall.$_name.path=$_path"
	uci set "firewall.$_name.position=$_pos"
	uci set "firewall.$_name.chain=$_chain"
	uci set "firewall.$_name.enabled=0"
	log "include $_name 创建：type=nftables position=$_pos chain=$_chain path=$_path enabled=0"
	created=$((created + 1))
	return 0
}

log "=== 98-campus-nft start ==="

if ! command -v uci >/dev/null 2>&1; then
	log "WARN: 没有 uci，跳过 include 段创建"
	exit 0
fi

[ -d "$NFTDIR" ] || log "WARN: $NFTDIR 不存在（片段会缺失，fw4 只 warn 不报错）"

# 一档：campus 默认开启的两条（enabled 由 netprofile 置 1）
#   TTL/HopLimit 归一必须落 mangle_forward（forward 钩子之前内核已递减 TTL）
add_include campus_ttl     "$NFTDIR/10-ttl.nft"     chain-append  mangle_forward
#   出向发现协议兜底 drop（片段内绝不含 DHCP 的 67/68）
add_include campus_noleak  "$NFTDIR/20-noleak.nft"  chain-append  mangle_forward

# 二档：默认关，用户显式开启（副作用见各片段头部注释与 docs）
#   NAT 源端口随机化：chain-prepend 抢在 fw4 自己的 masquerade 之前
add_include campus_natport "$NFTDIR/30-srcport.nft" chain-prepend srcnat_wan
#   NTP 收敛到本机：dstnat 里 redirect
add_include campus_ntp     "$NFTDIR/40-ntp.nft"     chain-append  dstnat
#   并发连接上限：mangle_forward 里 ct count over N drop
add_include campus_conncap "$NFTDIR/50-conncap.nft" chain-append  mangle_forward

# 可选段 campus_dnsprobe 故意不建：C8a（探测域名收敛）落在 dnsmasq 的 address=/…/#
# 上，没有对应的 nft 片段；建一个指向不存在文件的 include 只会增加噪音。
# 若将来确实要加，照 add_include 的签名补一行即可。

if [ "$created" -gt 0 ]; then
	if uci commit firewall; then
		log "uci commit firewall 完成，新建 $created 段"
	else
		log "WARN: uci commit firewall 失败"
		failed=$((failed + 1))
	fi
else
	log "无新增段，跳过 uci commit firewall"
fi

log "=== 98-campus-nft done（新建 ${created}，失败 ${failed}）==="

# 首启脚本不阻断启动：失败只写日志，交给 netprofile/文档排查
exit 0
