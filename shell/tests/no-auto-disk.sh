#!/bin/sh
# 磁盘策略：不格式化、不自动挂载、不自动扩容
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/etc/uci-defaults/99-custom.sh"
FAIL=0

grep -nE 'mkfs\.|mkfs |mount /dev|wipefs|resize2fs|parted' "$S" >/tmp/nad.out 2>/dev/null \
	&& { echo "FAIL: 首启出现磁盘操作:"; cat /tmp/nad.out; FAIL=1; } \
	|| echo "ok: 首启无磁盘操作"

[ -e "$ROOT/files/usr/sbin/rootfs-expand" ] && { echo "FAIL: 仍有自动扩容脚本"; FAIL=1; } || echo "ok: 无自动扩容脚本"
find "$ROOT/files" -name 'storage-init*' | grep -q . && { echo "FAIL: 存在 storage-init"; FAIL=1; } || echo "ok: 无 storage-init"

grep -qE 'mkswap[[:space:]]+/dev/' "$ROOT/files/usr/sbin/swapctl" && { echo "FAIL: swapctl 对块设备 mkswap"; FAIL=1; } || echo "ok: swapctl 只用 swapfile"

[ "$FAIL" = "0" ] && echo "NO-AUTO-DISK OK" || echo "NO-AUTO-DISK FAILED"
exit $FAIL
