#!/bin/sh
# 首次启动执行一次（uci-defaults 语义：成功后自删）。
# 设计原则与上游一致：只改必要的 UCI，不整份覆盖 network/dhcp/firewall。
# 失败不阻断启动——最坏情况退回 OpenWrt 默认（LAN 192.168.1.1），仍可登录。

LOGFILE=/etc/config/uci-defaults-log.txt
log() { echo "$(date '+%F %T') $*" >>"$LOGFILE" 2>/dev/null; }

log "=== 99-custom start ==="

# ---- 1. 枚举物理网口（上游式：首个为 WAN，其余全部入桥）----
ifnames=""
for iface in /sys/class/net/*; do
	name=$(basename "$iface")
	[ -e "$iface/device" ] || continue
	case "$name" in eth*|en*) ifnames="$ifnames $name" ;; esac
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')
count=$(echo "$ifnames" | wc -w | tr -d ' ')
log "physical interfaces: [$ifnames] count=$count"

if [ "$count" -eq 1 ]; then
	# 单网口：按旁路由处理，LAN 走 DHCP
	uci set network.lan.proto='dhcp'
	uci -q delete network.lan.ipaddr
	uci -q delete network.lan.netmask
	log "single-port mode: lan=dhcp"
elif [ "$count" -gt 1 ]; then
	wan_if=$(echo "$ifnames" | awk '{print $1}')
	lan_ifs=$(echo "$ifnames" | cut -d ' ' -f2-)

	uci set network.wan=interface
	uci set network.wan.device="$wan_if"
	uci set network.wan.proto='dhcp'

	uci set network.wan6=interface
	uci set network.wan6.device="$wan_if"
	uci set network.wan6.proto='dhcpv6'

	sec=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
	[ -n "$sec" ] || sec="br_lan"
	uci -q delete "network.$sec.ports"
	for p in $lan_ifs; do uci add_list "network.$sec.ports=$p"; done

	# 管理地址
	IP_FILE=/etc/config/custom_router_ip.txt
	if [ -f "$IP_FILE" ]; then IP=$(tr -d ' \n' <"$IP_FILE"); else IP=192.168.100.1; fi
	case "$IP" in *[!0-9.]*|"") IP=192.168.100.1 ;; esac
	uci set network.lan.ipaddr="$IP"
	uci set network.lan.netmask='255.255.255.0'
	log "multi-port: wan=$wan_if lan=[$lan_ifs] ip=$IP"
else
	log "WARN: 未发现物理网口，保持 OpenWrt 默认"
fi
uci commit network

# ---- 2. IPv6 模式（默认 nat66，可用 ipv6mode 切换）----
if [ -x /usr/sbin/ipv6mode ]; then
	/usr/sbin/ipv6mode nat66 >>"$LOGFILE" 2>&1 || log "WARN: ipv6mode 执行失败"
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

# ---- 7. 接口名与配置对齐（不重命名，只写真实名字）----
[ -x /usr/sbin/nicsync ] && /usr/sbin/nicsync >>"$LOGFILE" 2>&1 || log "WARN: nicsync 执行异常"

log "=== 99-custom done ==="
exit 0
