#!/bin/sh
# 首次启动执行一次（uci-defaults 语义：成功后自动删除）。
# 设计原则：无外网也可完成；重复执行结果一致；不碰数据盘。

LOGFILE=/etc/config/uci-defaults-log.txt
log() { echo "$(date '+%F %T') $*" >>"$LOGFILE" 2>/dev/null; }

log "=== 99-custom start ==="

# ---- 1. 扩容（按挂载点反查，见 /usr/sbin/rootfs-expand）----
if [ -x /usr/sbin/rootfs-expand ]; then
	/usr/sbin/rootfs-expand >>"$LOGFILE" 2>&1 || log "rootfs-expand 执行异常，见 /etc/config/rootfs-expand.log"
else
	log "WARN: 缺少 /usr/sbin/rootfs-expand，跳过扩容"
fi

# ---- 2. 端口角色 ----
# 开机时 /etc/init.d/portmap 已按 PCI 顺序把物理口固定成 eth0..eth3，
# network 配置静态引用它们，这里不再动态改 UCI，避免解析失败把桥清空。
log "ports: $(ip -o link show 2>/dev/null | awk -F': ' '/eth/{printf "%s ", $2}')"

# ---- 3. 管理地址（可用 custom_router_ip.txt 覆盖）----
IP_FILE=/etc/config/custom_router_ip.txt
if [ -f "$IP_FILE" ]; then
	IP=$(cat "$IP_FILE" | tr -d ' \n')
else
	IP=192.168.100.1
fi
case "$IP" in
	*[!0-9.]*|"") IP=192.168.100.1 ;;
esac
uci set network.lan.ipaddr="$IP"
uci commit network
log "lan ip = $IP"

# ---- 4. WAN 出厂保持关闭，等用户配置或 profile 切换 ----
# WAN 保持 auto=0：认证与取地址由用户显式启用，避免无网阶段刷日志
uci set network.wan.auto='0'
uci set network.wan6.auto='0'
uci commit network

# ---- 5. 管理面可达性：ttyd/ssh 不绑接口，root 可登录 ----
uci -q delete ttyd.@ttyd[0].interface
uci set dropbear.@dropbear[0].Interface=''
uci commit

# ---- 6. 主机名与时间 ----
uci set system.@system[0].hostname='ImmortalWrt'
uci commit system

# 安卓 TV 时间服务器映射（保留原仓库行为）
uci -q delete dhcp.androidtime
uci add dhcp domain >/dev/null
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"
uci commit dhcp

# ---- 7. docker 区域（装了 dockerd 才加）----
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

# ---- 8. 关闭 i226 的 EEE（稳定性基线）----
for i in $(ls /sys/class/net | grep -E '^eth'); do
	if command -v ethtool >/dev/null 2>&1; then
		ethtool --set-eee "$i" eee off >/dev/null 2>&1 && log "eee off on $i"
	fi
done

# ---- 9. swapfile（可调，默认 4G；zram 由包自带）----
/usr/sbin/swapctl apply >>"$LOGFILE" 2>&1 || log "swapctl not available"

log "=== 99-custom done ==="
exit 0
