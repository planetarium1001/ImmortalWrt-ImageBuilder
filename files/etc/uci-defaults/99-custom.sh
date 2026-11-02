#!/bin/sh
# 首次启动执行一次（uci-defaults 语义：成功后自动删除）。
# 设计原则：无外网也可完成；重复执行结果一致；不碰数据盘。

LOGFILE=/etc/config/uci-defaults-log.txt
log() { echo "$(date '+%F %T') $*" >>"$LOGFILE" 2>/dev/null; }

log "=== 99-custom start ==="

# ---- 1. 根分区扩满系统盘（只动根分区，不碰其他盘）----
# 注意：immortalwrt 的 feed 里没有 growpart，busybox 也没有该 applet，
# 所以这里用 parted/sfdisk 扩分区，再 resize2fs 在线扩展文件系统。
root_src=$(sed -n 's/^[^ ]* \([^ ]*\) \/ .*/\1/p' /proc/mounts 2>/dev/null | head -n1)
root_dev=$(readlink -f "$root_src" 2>/dev/null || echo "$root_src")
case "$root_dev" in
	/dev/*)
		disk=$(echo "$root_dev" | sed 's/p\?[0-9]*$//')
		partnum=$(echo "$root_dev" | sed 's/.*[^0-9]\([0-9]\+\)$/\1/')
		if [ -n "$partnum" ] && [ -b "$disk" ]; then
			if command -v parted >/dev/null 2>&1; then
				parted -s "$disk" resizepart "$partnum" 100% >>"$LOGFILE" 2>&1
			elif command -v sfdisk >/dev/null 2>&1; then
				# 删分区再按原起点重建，起点不变即数据安全
				start=$(sfdisk -d "$disk" 2>/dev/null | sed -n "s/^.*${disk}p\?${partnum} *: *start= *\([0-9]*\).*/\1/p" | head -n1)
				if [ -n "$start" ]; then
					echo ",+," | sfdisk --force --no-reread -N "$partnum" "$disk" >>"$LOGFILE" 2>&1
				fi
			fi
			blockdev --rereadpt "$disk" >>"$LOGFILE" 2>&1
			resize2fs "$root_dev" >>"$LOGFILE" 2>&1 && log "rootfs expanded on $root_dev" \
				|| log "rootfs expand skipped or failed on $root_dev"
		fi
		;;
esac

# ---- 2. 端口角色按 MAC/PCI 固定 ----
if [ -x /usr/sbin/portmap ]; then
	/usr/sbin/portmap apply >>"$LOGFILE" 2>&1 || log "portmap apply failed, fallback eth0/eth1-3"
fi

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
uci set network.wan.auto='0'
uci set network.wan6.auto='0'
uci commit network

# ---- 5. 管理面可达性：ttyd/ssh 不绑接口，root 可登录 ----
uci -q delete ttyd.@ttyd[0].interface
uci set dropbear.@dropbear[0].Interface=''
uci commit

# ---- 6. 主机名与时间 ----
uci set system.@system[0].hostname='n5105-router'
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
