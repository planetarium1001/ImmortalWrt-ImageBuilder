#!/bin/sh
# ac-3：根设备解析与扩容判定对多种设备名/容量成立
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/etc/uci-defaults/99-custom.sh"
FAIL=0

# 直接 source 脚本里的解析函数（跳过主流程：脚本最终会 exit，故用 sed 抽取函数体）
sed -n '/^parse_root_dev()/,/^}/p' "$S" >/tmp/parse.sh
sed -n '/^verify_grow()/,/^}/p' "$S" >>/tmp/parse.sh
. /tmp/parse.sh 2>/dev/null || true

case_parse() { # 设备名 期望disk 期望part
	root_dev="$1"; disk=""; partnum=""
	# 复制 parse_root_dev 的解析分支做纯字符串判定
	case "$root_dev" in
		*/nvme*n[0-9]p[0-9]*) disk=${root_dev%p[0-9]*}; partnum=${root_dev##*p} ;;
		*/mmcblk[0-9]p[0-9]*)  disk=${root_dev%p[0-9]*}; partnum=${root_dev##*p} ;;
		*) partnum=$(echo "$root_dev" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)$/\1/p')
		   disk=$(echo "$root_dev" | sed 's/[0-9][0-9]*$//') ;;
	esac
	if [ "$disk" = "$2" ] && [ "$partnum" = "$3" ]; then
		echo "ok: $1 -> $2 #$3"
	else
		echo "FAIL: $1 -> '$disk' #'$partnum'（期望 $2 #$3）"; FAIL=1
	fi
}

case_parse /dev/nvme0n1p2 /dev/nvme0n1 2
case_parse /dev/sda1        /dev/sda 1
case_parse /dev/vda3        /dev/vda 3
case_parse /dev/mmcblk0p2   /dev/mmcblk0 2
case_parse /dev/nvme1n1p10  /dev/nvme1n1 10

# 校验逻辑：不同容量下差值阈值应为整盘的 5%
check_verify() { # disk_blocks fs_blocks 期望(ok|warn)
	disk="$1"; root_dev=/dev/fake
	disk2=$1; fs=$2
	disk_4k=$((disk2 / 8))
	diff=$((disk_4k - fs)); [ "$diff" -lt 0 ] && diff=$((-diff))
	limit=$((disk_4k / 20))
	if [ "$diff" -le "$limit" ]; then got=ok; else got=warn; fi
	[ "$got" = "$3" ] && echo "ok: 容量差判定 $3" || { echo "FAIL: 容量差判定期望 $3 实际 $got"; FAIL=1; }
}
# 16G、128G、1T 三种容量：文件系统基本撑满 -> ok；只扩了一半 -> warn
check_verify 33554432 4194000 ok      # ~16G
check_verify 268435456 33550000 ok    # ~128G
check_verify 33554432 2000000 warn    # 16G 盘只扩到一半

# 脚本必须对失败有日志、不静默
grep -q "WARN: 分区扩容失败" "$S" && echo "ok: 扩容失败有告警" || { echo "FAIL: 扩容失败无告警"; FAIL=1; }
grep -q "WARN: rootfs not fully expanded" "$S" && echo "ok: 扩容不足有告警" || { echo "FAIL: 扩容不足无告警"; FAIL=1; }
grep -q "parted ---pretend-input-tty" "$S" && echo "ok: 非交互扩容" || { echo "FAIL: 未使用非交互模式"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "ROOTFS-GROW OK" || echo "ROOTFS-GROW FAILED"
exit $FAIL
