#!/bin/sh
# 首次启动执行一次（uci-defaults 语义：成功后自删；非 0 退出会在下次开机重试）。
# 设计原则与上游一致：只改必要的 UCI，不整份覆盖 network/dhcp/firewall。
# 端口分配本身不在这里实现——统一走 /lib/functions/netports.sh（单一真源）。

LOGFILE=/etc/config/uci-defaults-log.txt
log() { echo "$(date '+%F %T') $*" >>"$LOGFILE" 2>/dev/null; }

log "=== 99-custom start ==="

# ---- 1. 端口分配（单一真源：/lib/functions/netports.sh）----
# 枚举口径见 netports_phys：读 /sys/class/net/* 并按 PCI bus:dev.fn **数值**排序
# （字典序会让 eth10 < eth2、0000:9:00.0 排在 0000:10:00.0 之后）。
NETPORTS_LIB=${NETPORTS_LIB:-/lib/functions/netports.sh}
[ -r "$NETPORTS_LIB" ] || NETPORTS_LIB="$(dirname "$0")/../../lib/functions/netports.sh"
if [ ! -r "$NETPORTS_LIB" ]; then
	log "ERROR: 找不到 netports 库 [$NETPORTS_LIB]，不改端口，退出"
	exit 1
fi
. "$NETPORTS_LIB"

ifnames=$(netports_phys | tr '\n' ' ')
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')
count=$(echo "$ifnames" | wc -w | tr -d ' ')
log "physical interfaces: [$ifnames] count=$count"

# 管理地址（各分支共用）
IP_FILE=/etc/config/custom_router_ip.txt
if [ -f "$IP_FILE" ]; then IP=$(tr -d ' \n' <"$IP_FILE"); else IP=192.168.100.1; fi
case "$IP" in *[!0-9.]*|"") IP=192.168.100.1 ;; esac

if [ "$count" -eq 1 ]; then
	# 单网口：保持 LAN 静态（backlog C3）。切成 DHCP 客户端会让盒子在上级网段里
	# 既当 DHCP 客户端又当 DHCP 服务器（dhcp.lan 没有 ignore），且管理地址消失。
	# 旁路由场景请手动切换：uci set network.lan.proto='dhcp' + uci set dhcp.lan.ignore='1'。
	log "WARN: single-port, LAN=static: 只有 1 个物理口 [$ifnames], 保持 LAN 静态 IP=$IP; 如需 DHCP 客户端请手动切换, 并同时置 dhcp.lan.ignore=1"
elif [ "$count" -gt 1 ]; then
	wan_if=$(echo "$ifnames" | awk '{print $1}')
	lan_ifs=$(echo "$ifnames" | cut -d ' ' -f2-)
	# netports_apply 内部：先定位真实设备段（匿名的 config device 也能命中），
	# 定位失败即返回非 0 且一个端口都不改；写失败会自行回滚。
	if netports_apply "$wan_if" $lan_ifs; then
		log "multi-port: wan=$wan_if lan=[$lan_ifs] device=$NETPORTS_SEC"
	else
		# fail-closed：宁可留上游默认，也不要半套配置（端口重叠＝灯亮、拿不到地址）
		log "ERROR: 端口分配失败，端口保持上游默认，退出（下次开机重试）"
		exit 1
	fi
else
	log "WARN: 未发现物理网口，保持 OpenWrt 默认"
fi

if [ "$count" -ge 1 ]; then
	uci set network.lan.ipaddr="$IP"
	uci set network.lan.netmask='255.255.255.0'
	log "lan ip=$IP"
fi
uci commit network

# ---- 2. 默认 profile（campus：NAT66 + 防检测一档 + 认证自启）----
# 用 --no-reload：本脚本由 /etc/init.d/boot 的 uci_apply_defaults 执行（START=10），
# 此时 netifd/fw4 都没起来，reload 必然失败并把刚写的配置回滚掉（审计 P2）。
# 配置写完后由开机流程自己把网络与防火墙拉起来。
if [ -x /usr/sbin/netprofile ]; then
	/usr/sbin/netprofile --no-reload campus >>"$LOGFILE" 2>&1 ||
		log "WARN: netprofile campus 执行失败，配置保持上游默认"
fi

# ---- 3. 主机名 ----
uci set system.@system[0].hostname='ImmortalWrt'
uci commit system

# ---- 4. 管理面可达：ttyd/ssh 不绑接口 ----
uci -q delete ttyd.@ttyd[0].interface
uci set dropbear.@dropbear[0].Interface=''
uci commit

# ---- 5. docker 区域（只在装了 dockerd 时加）----
if command -v dockerd >/dev/null 2>&1; then
	uci -q delete firewall.docker
	uci set firewall.docker=zone
	uci set firewall.docker.name='docker'
	uci set firewall.docker.input='ACCEPT'
	uci set firewall.docker.output='ACCEPT'
	uci set firewall.docker.forward='ACCEPT'
	uci add_list firewall.docker.subnet='172.16.0.0/12'
	uci commit firewall
	log "docker zone ensured"
fi

# ---- 6. swap（swapfile + zram）----
[ -x /usr/sbin/swapctl ] && /usr/sbin/swapctl apply >>"$LOGFILE" 2>&1

# 端口对账不放在首启阶段：uci-defaults 由 /etc/init.d/boot 执行（START=10），
# netifd 还没起，`ip link show master br-lan` 恒为空，只会记一条假 WARN（backlog N5）。
# 首启之后用 `nicsync --check`（只读校验，不齐返回 2）或 `nicsync --fix` 复核。

log "=== 99-custom done ==="
exit 0
