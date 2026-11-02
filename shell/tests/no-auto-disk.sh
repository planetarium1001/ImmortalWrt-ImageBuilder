#!/bin/sh
# ac-13：固件不自动格式化/挂载任何数据盘
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

# 1. 首启脚本不得格式化任何设备、不得挂载任何 /dev/*
if grep -nE 'mkfs\.|mkfs |mount /dev|parted .*mklabel|wipefs' \
	"$ROOT/files/etc/uci-defaults/99-custom.sh" >/tmp/nad.out 2>/dev/null; then
	echo "FAIL: 首启脚本出现格式化/挂载动作:"; cat /tmp/nad.out; FAIL=1
else
	echo "ok: 首启脚本无 mkfs/mount/wipefs"
fi

# 1b. 分区操作只能作用于"根所在磁盘"变量，不能写死 /dev/sdX
if grep -nE '(parted|sfdisk).*/dev/(sd|nvme|vd)' "$ROOT/files/etc/uci-defaults/99-custom.sh" >/tmp/nad2.out 2>/dev/null; then
	echo "FAIL: 分区操作写死了设备路径:"; cat /tmp/nad2.out; FAIL=1
else
	echo "ok: 分区操作只作用于根磁盘变量"
fi

# 2. 首启脚本里的 growpart/resize2fs 必须只针对根分区变量
if grep -q 'resize2fs "/dev/\$devname"' "$ROOT/files/usr/sbin/rootfs-expand"; then
	echo "ok: resize2fs 仅作用于反查到的分区"
else
	echo "FAIL: resize2fs 目标不明确"; FAIL=1
fi

# 3. 全仓不得有 storage-init 之类的自动格式化脚本
if find "$ROOT/files" -name 'storage-init*' | grep -q .; then
	echo "FAIL: 存在 storage-init 脚本（按用户要求应移除）"; FAIL=1
else
	echo "ok: 无 storage-init 脚本"
fi

# 4. swapctl 只写配置指定的 swapfile，不猜测数据盘路径
if grep -qE 'mkswap[[:space:]]+/dev/' "$ROOT/files/usr/sbin/swapctl"; then
	echo "FAIL: swapctl 对块设备做 mkswap"; FAIL=1
else
	echo "ok: swapctl 只用 swapfile"
fi

[ "$FAIL" = "0" ] && echo "NO-AUTO-DISK OK" || echo "NO-AUTO-DISK FAILED"
exit $FAIL
