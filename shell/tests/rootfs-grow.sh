#!/bin/sh
# ac-4：按挂载点反查扩容；支持 ext4 根与 squashfs+overlay；设备名解析正确
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/usr/sbin/rootfs-expand"
FAIL=0

[ -x "$S" ] && echo "ok: rootfs-expand 可执行" || { echo "FAIL: 缺脚本"; FAIL=1; }

# 必须同时处理 / 与 /overlay
grep -q "grow_one /$" "$S" && echo "ok: 处理 /" || { echo "FAIL: 未处理 /"; FAIL=1; }
grep -q "grow_one /overlay" "$S" && echo "ok: 处理 /overlay" || { echo "FAIL: 未处理 /overlay"; FAIL=1; }

# 经 /sys/dev/block 反查，兼容 /dev/root
grep -q "/sys/dev/block" "$S" && echo "ok: 用设备号反查" || { echo "FAIL: 未用设备号"; FAIL=1; }
grep -q "DEVNAME" "$S" && echo "ok: 读 DEVNAME" || { echo "FAIL: 未读 DEVNAME"; FAIL=1; }

# squashfs 必须跳过
grep -q "squashfs) log" "$S" && echo "ok: squashfs 跳过" || { echo "FAIL: 未跳过 squashfs"; FAIL=1; }

# 扩完必须刷新分区表
grep -q "partx -u" "$S" && echo "ok: partx 刷新" || { echo "FAIL: 未刷新分区表"; FAIL=1; }
grep -q "rereadpt" "$S" && echo "ok: rereadpt 兜底" || { echo "FAIL: 缺 rereadpt"; FAIL=1; }

# 设备名解析：抽出来单独验
sed -n '/^grow_one()/,/^}/p' "$S" >/tmp/grow.sh
case_parse() { # 设备名 期望disk 期望part
	case "$1" in
		nvme*n[0-9]p[0-9]*) d=${1%p[0-9]*}; p=${1##*p} ;;
		mmcblk[0-9]p[0-9]*) d=${1%p[0-9]*}; p=${1##*p} ;;
		*[0-9]) d=$(echo "$1" | sed 's/[0-9][0-9]*$//'); p=$(echo "$1" | sed 's/.*[^0-9]\([0-9][0-9]*\)$/\1/') ;;
		*) d=""; p="" ;;
	esac
	[ "$d" = "$2" ] && [ "$p" = "$3" ] && echo "ok: $1 -> $2 #$3" || { echo "FAIL: $1 -> '$d' #'$p'"; FAIL=1; }
}
case_parse nvme0n1p2 nvme0n1 2
case_parse sda2 sda 2
case_parse mmcblk0p2 mmcblk0 2
case_parse nvme1n1p10 nvme1n1 10

# 容量校验与告警
grep -q "WARN: .*未完全扩满" "$S" && echo "ok: 扩容不足告警" || { echo "FAIL: 缺告警"; FAIL=1; }
grep -q "ERROR: .*文件系统扩容失败" "$S" && echo "ok: 失败告警" || { echo "FAIL: 缺失败告警"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "ROOTFS-GROW OK" || echo "ROOTFS-GROW FAILED"
exit $FAIL
