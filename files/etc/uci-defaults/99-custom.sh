#!/bin/sh
# 首次启动执行一次（uci-defaults 语义：成功后自动删除）。
# 设计原则：无外网也可完成；重复执行结果一致；不碰数据盘。

LOGFILE=/etc/config/uci-defaults-log.txt
log() { echo "$(date '+%F %T') $*" >>"$LOGFILE" 2>/dev/null; }

log "=== 99-custom start ==="

# ---- 1. 根分区扩满系统盘（只动根分区，不碰任何其他磁盘）----
# 目标：任意容量的系统盘写入镜像后，首次开机自动扩满，随后即可正常登录。
# 约束：不扫描其它块设备、不 mkfs、不挂载数据盘。
# 实现：feed 里没有 growpart，busybox 也无该 applet，因此用 parted/sfdisk 扩分区 + resize2fs 在线扩文件系统。

# 从 /proc/mounts 反查根设备，并解析出磁盘与分区号
# 兼容 /dev/sda1、/dev/nvme0n1p2、/dev/mmcblk0p2、/dev/vda3
parse_root_dev() {
	src=$(sed -n 's/^[^ ]* \([^ ]*\) \/ .*/\1/p' /proc/mounts 2>/dev/null | head -n1)
	[ -n "$src" ] || return 1
	root_dev=$(readlink -f "$src" 2>/dev/null || echo "$src")
	case "$root_dev" in
		/dev/*) ;;
		*) return 1 ;;
	esac
	case "$root_dev" in
		# nvme / mmcblk 这类名字本身含数字，分区号跟在 p 后面
		*/nvme*n[0-9]p[0-9]*) disk=${root_dev%p[0-9]*}; partnum=${root_dev##*p} ;;
		*/mmcblk[0-9]p[0-9]*)  disk=${root_dev%p[0-9]*}; partnum=${root_dev##*p} ;;
		# sdX/vdX 这类：去掉末尾连续数字即为磁盘
		*) partnum=$(echo "$root_dev" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)$/\1/p')
		   disk=$(echo "$root_dev" | sed 's/[0-9][0-9]*$//') ;;
	esac
	[ -b "$disk" ] && [ -n "$partnum" ]
}

# 扩容结果校验：文件系统可用块与分区块数之差应在 5% 以内
verify_grow() {
	disk_blocks=$(cat "/sys/class/block/$(basename "$disk")/size" 2>/dev/null)
	fs_blocks=$(dumpe2fs -h "$root_dev" 2>/dev/null | sed -n 's/^Block count: *//p')
	[ -n "$disk_blocks" ] && [ -n "$fs_blocks" ] || return 0
	# fs 块按 4K 计，disk 块按 512B 计
	disk_4k=$((disk_blocks / 8))
	diff=$((disk_4k - fs_blocks))
	[ "$diff" -lt 0 ] && diff=$((-diff))
	limit=$((disk_4k / 20))
	if [ "$diff" -le "$limit" ]; then
		log "rootfs verified: fs=${fs_blocks} blocks, disk=${disk_4k} blocks"
	else
		log "WARN: rootfs not fully expanded (fs=${fs_blocks}, disk=${disk_4k}); 手工扩容见文档"
	fi
}

if parse_root_dev; then
	log "grow target: dev=$root_dev disk=$disk part=$partnum"
	grown=0
	if command -v parted >/dev/null 2>&1; then
		# ---pretend-input-tty 让 parted 在非交互环境自动回答 "Yes"
		parted ---pretend-input-tty "$disk" resizepart "$partnum" 100% >>"$LOGFILE" 2>&1 && grown=1
	fi
	if [ "$grown" != "1" ] && command -v sfdisk >/dev/null 2>&1; then
		# 回退：删除并按原起点重建分区（起点不变即数据安全）
		if echo ",+," | sfdisk --force --no-reread -N "$partnum" "$disk" >>"$LOGFILE" 2>&1; then
			grown=1
		fi
	fi
	if [ "$grown" = "1" ]; then
		blockdev --rereadpt "$disk" >>"$LOGFILE" 2>&1
		if resize2fs "$root_dev" >>"$LOGFILE" 2>&1; then
			log "rootfs expanded on $root_dev"
			verify_grow
		else
			log "ERROR: resize2fs failed on $root_dev（系统仍可启动，可手工扩容）"
		fi
	else
		log "WARN: 分区扩容失败，根分区保持镜像大小（可手工扩容）"
	fi
else
	log "WARN: 无法解析根设备，跳过扩容"
fi

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
