#!/bin/sh
# /etc/campus/nft/render.sh —— 把 campus 防检测片段的 *.nft.tmpl 渲染成 fw4 可收录的 *.nft
#
# 为什么需要渲染：fw4 的 `config include`（type nftables）只能收录静态文件，而规则要按
# 真实设备名限定（oifname "<wan>" / iifname "<lan>"）。25.12 的端口分配由首启脚本按物理口
# 枚举决定，镜像里不能写死 eth0/eth1，所以片段以 .tmpl 形式随镜像发布，运行时用本脚本把
# 占位符换成 uci 里的真值。
#
# 占位符：
#   @WAN@    → WAN 出接口名（uci network.wan.device，兜底 wan.device/ifname → wan6.device
#              → ubus network.interface.wan 的 l3_device/device）
#   @LAN_IF@ → LAN 入接口名（uci network.lan.device，兜底 br-lan）
#
# 用法：
#   sh /etc/campus/nft/render.sh                        # 自动解析
#   sh /etc/campus/nft/render.sh --wan eth0 --lan br-lan # 显式指定
#   CAMPUS_NFT_DIR=/tmp/x sh render.sh --wan eth0        # 测试用目录覆盖
#
# 约定：
#   - 幂等：同一输入重复执行产物一致；内容未变时不重写文件。
#   - 取不到 WAN 设备名、或设备名含非法字符时退出 1，且不改动已有产物
#     （避免写出看似正常、实际静默不匹配的规则）。调用方应先处理失败再置 enabled=1。
#   - 本脚本不 reload 防火墙：调用方（netprofile）按自己的顺序 `fw4 reload`。
#   - 30-srcport.nft 无占位符，是静态文件，不经过本脚本。

set -u

DIR="${CAMPUS_NFT_DIR:-/etc/campus/nft}"
wan=""
lan=""

log() { echo "campus-nft: $*" >&2; }
uget() { uci -q get "$1" 2>/dev/null || true; }

usage() {
	cat <<'EOF'
用法: render.sh [--wan DEV] [--lan DEV]
  --wan DEV   WAN 出接口名（默认取 uci network.wan.device 等）
  --lan DEV   LAN 入接口名（默认取 uci network.lan.device，兜底 br-lan）
环境变量 CAMPUS_NFT_DIR 可覆盖片段目录（默认 /etc/campus/nft，测试用）。
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--wan) wan="${2:-}"; shift 2 || shift ;;
		--wan=*) wan="${1#*=}"; shift ;;
		--lan) lan="${2:-}"; shift 2 || shift ;;
		--lan=*) lan="${1#*=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) log "未知参数：$1"; usage >&2; exit 2 ;;
	esac
done

[ -d "$DIR" ] || { log "片段目录不存在：$DIR"; exit 1; }
[ -w "$DIR" ] || { log "片段目录不可写：$DIR"; exit 1; }

valid_name() {
	case "$1" in
		""|*[!A-Za-z0-9_.:@-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# ---- 解析 WAN ----
[ -n "$wan" ] || wan=$(uget network.wan.device)
[ -n "$wan" ] || wan=$(uget network.wan.ifname)
[ -n "$wan" ] || wan=$(uget network.wan6.device)
if [ -z "$wan" ] && command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
	st=$(ubus call network.interface.wan status 2>/dev/null) || st=""
	if [ -n "$st" ]; then
		wan=$(printf '%s' "$st" | jsonfilter -e '@.l3_device' 2>/dev/null) || wan=""
		[ -n "$wan" ] || { wan=$(printf '%s' "$st" | jsonfilter -e '@.device' 2>/dev/null) || wan=""; }
	fi
fi

if ! valid_name "$wan"; then
	log "取不到合法的 WAN 设备名（uci network.wan.device / wan6.device / ubus 均无结果）；"
	log "不渲染，保持既有产物。可用 --wan <dev> 显式指定。"
	exit 1
fi

# ---- 解析 LAN ----
[ -n "$lan" ] || lan=$(uget network.lan.device)
valid_name "$lan" || lan="br-lan"

if [ -d /sys/class/net ] && [ ! -e "/sys/class/net/$wan" ]; then
	log "WARN: $wan 当前不在 /sys/class/net（设备可能尚未就绪）——仍按该名字渲染"
fi

# ---- 渲染 ----
rendered=0
failed=0
for tmpl in "$DIR"/*.nft.tmpl; do
	[ -f "$tmpl" ] || continue
	dst=${tmpl%.tmpl}
	tmp="$dst.new.$$"
	if ! sed -e "s|@WAN@|$wan|g" -e "s|@LAN_IF@|$lan|g" "$tmpl" >"$tmp"; then
		log "渲染失败：$tmpl"
		rm -f "$tmp"
		failed=1
		continue
	fi
	if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
		rm -f "$tmp"
	else
		chmod 0644 "$tmp" 2>/dev/null
		if ! mv -f "$tmp" "$dst"; then
			log "写入失败：$dst"
			rm -f "$tmp"
			failed=1
			continue
		fi
		echo "rendered: $dst"
	fi
	rendered=$((rendered + 1))
done

if [ "$rendered" -eq 0 ]; then
	log "WARN: $DIR 下没有 *.nft.tmpl"
	[ "$failed" -eq 0 ] && exit 1
fi

if [ "$failed" -ne 0 ]; then
	log "有片段渲染失败，请检查 $DIR"
	exit 1
fi

exit 0
