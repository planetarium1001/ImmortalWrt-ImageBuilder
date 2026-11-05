#!/bin/sh
# 磁盘策略回归：
#   1) 99-custom.sh 仍然**没有**任何磁盘操作（不格式化、不挂数据盘、不自动扩容）；
#   2) 全仓只有首启 overlay-setup 动分区表/文件系统，且它只动 /rom 所在的那块**系统盘**
#      （不写死盘符、不按标签扫盘），绝不碰其它盘（数据盘）；
#   3) 不再存在"自动扩容 rootfs / 自动挂载存储"的脚本。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0
U="$ROOT/files/etc/uci-defaults/99-custom.sh"
O="$ROOT/files/usr/sbin/overlay-setup"

DISK_OPS='sgdisk|partx|mkfs\.btrfs|wipefs|parted|sfdisk|resize2fs'

echo "== 1. 99-custom.sh 无磁盘操作 =="
if grep -nE "$DISK_OPS|mount /dev|mkfs " "$U" >/tmp/nad.out 2>/dev/null; then
	echo "FAIL: 首启出现磁盘操作:"
	cat /tmp/nad.out
	FAIL=1
else
	echo "ok: 首启 99-custom.sh 无磁盘操作"
fi

echo "== 2. 只有 overlay-setup 动分区/文件系统 =="
got=$(grep -rlE "$DISK_OPS" "$ROOT/files" 2>/dev/null | sed "s#^$ROOT/##" | sort | tr '\n' ' ' | sed 's/ *$//')
if [ "$got" = "files/usr/sbin/overlay-setup" ]; then
	echo "ok: 唯一动盘脚本是 files/usr/sbin/overlay-setup"
else
	echo "FAIL: 动盘脚本不唯一或缺失 [$got]"
	FAIL=1
fi

echo "== 3. overlay-setup 只动系统盘（不写死盘符、不碰数据盘）=="
if [ -f "$O" ]; then
	hits=$(grep -nE '/dev/(sd|nvme|hd|vd)[a-z0-9]|/dev/disk/by-|sd[b-z][0-9]' "$O" 2>/dev/null)
	if [ -n "$hits" ]; then
		echo "FAIL: overlay-setup 里出现写死/猜的设备名:"
		echo "$hits"
		FAIL=1
	else
		echo "ok: 没有写死的盘符"
	fi
	if grep -q 'PROC_MOUNTS' "$O" && grep -q 'mountinfo' "$O" && grep -q 'SYS_BLOCK' "$O"; then
		echo "ok: 从 /rom 的挂载信息反查启动盘（mounts/mountinfo + sysfs）"
	else
		echo "FAIL: 没有从 /rom 反查启动盘"
		FAIL=1
	fi
	if grep -qE '(exit|die) 3' "$O"; then
		echo "ok: 整盘 root（无分区号）明确拒绝"
	else
		echo "FAIL: 缺少整盘 root 的拒绝分支"
		FAIL=1
	fi
	#只看代码行：注释里写着 "-a 与 -u 互斥" 不算违规
	code=$(grep -vE '^[[:space:]]*#' "$O")
	if printf '%s\n' "$code" | grep -qE 'PARTX.*-a "\$DISK_DEV"' &&
		! printf '%s\n' "$code" | grep -qE 'partx .*-a .*-u'; then
		echo "ok: partx 用 -a 单独调用（-a -u 互斥）"
	else
		echo "FAIL: partx 调用形态不对（-a 与 -u 不能连用）"
		FAIL=1
	fi
else
	echo "FAIL: 缺少 $O"
	FAIL=1
fi

echo "== 4. 没有自动扩容/自动挂载存储的残留 =="
[ -e "$ROOT/files/usr/sbin/rootfs-expand" ] && { echo "FAIL: 仍有自动扩容脚本"; FAIL=1; } || echo "ok: 无自动扩容脚本"
find "$ROOT/files" -name 'storage-init*' | grep -q . && { echo "FAIL: 存在 storage-init"; FAIL=1; } || echo "ok: 无 storage-init"

grep -qE 'mkswap[[:space:]]+/dev/' "$ROOT/files/usr/sbin/swapctl" && { echo "FAIL: swapctl 对块设备 mkswap"; FAIL=1; } || echo "ok: swapctl 只用 swapfile"

[ "$FAIL" = "0" ] && echo "NO-AUTO-DISK OK" || echo "NO-AUTO-DISK FAILED"
exit $FAIL
