#!/bin/sh
# ac-10：x86 sysupgrade 的分区写入分支判定（离线）。
#
# 做法：把**上游原文件**（shell/tests/fixtures/sysupgrade/{common,platform}.sh，
# provenance 见同目录 PROVENANCE.md）source 进来，只替换硬件/IO 相关函数
# （get_partitions / get_image_dd / export_bootdevice / export_partdevice / mount /
#   umount / partx / grub-bios-setup / v / ask_bool），然后真跑 platform_do_upgrade，
# 断言它走哪条分支、把镜像写到了哪些设备。
#
# 断言的核心不变量（platform.sh:81-104）：
#   diff = 镜像有、盘上没有的分区行（`grep -F -x -v -f 盘 镜像`，**单向**）
#   diff 非空 → get_image_dd of="/dev/<整盘>" bs=4096（整盘覆写）
#   diff 为空 → 逐分区 get_image_dd of="/dev/<分区>"（盘上多出来的分区一个字节都不写）
#
# 本用例能证明的：分支决策与"写哪些设备"。
# 本用例**不能**证明的：真机上 get_partitions 对真实 GPT 的解析结果（依赖 busybox
# hexdump 的字节序语义，在 macOS/BSD hexdump 下无法复现）——那条交给真机 ac-12。
set -u
. "$(dirname "$0")/lib-assert.sh"

FIX="$(cd "$(dirname "$0")/fixtures/sysupgrade" && pwd)"
WORK=$(mktemp -d "/tmp/sb-sysup-XXXXXX" 2>/dev/null) || { bad "无法创建临时目录"; exit 1; }
TRACE="$WORK/trace.log"

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

# ---------------------------------------------------------------- 场景夹具
# 盘：p1 512/65536、p2 66048/614400、p3 680448/267755008（128 GiB 盘上占满剩余）
disk_partmap() {
	cat >"$WORK/partmap.bootdisk" <<'EOF'
 1   512   65536
 2 66048  614400
 3 680448 267755008
EOF
}
# 镜像 A：stock 两分区，几何与盘上一致（本任务交付的形态）
img_stock() {
	cat >"$WORK/partmap.image" <<'EOF'
 1   512   65536
 2 66048  614400
EOF
}
# 镜像 B：把 p3 预置进镜像（尺寸被构建期冻结，与盘上扩满的 p3 必然不等）
img_prep3() {
	cat >"$WORK/partmap.image" <<'EOF'
 1   512   65536
 2 66048  614400
 3 680448 262144
EOF
}
# 镜像 C：换了 ROOTFS_PARTSIZE（p2 变大）
img_2g() {
	cat >"$WORK/partmap.image" <<'EOF'
 1   512   65536
 2 66048 4194304
EOF
}

# ---------------------------------------------------------------- 被跑的真函数
run_platform() { # <场景名> <partmap 生成函数>
	disk_partmap
	"$2"
	: >"$TRACE"
	(
		set -u
		VERBOSE=1; INTERACTIVE=0; SAVE_CONFIG=1
		export SAVE_PARTITIONS=1
		# procd 会按 json 里的 save_partitions 注入这个环境变量（默认 1）；
		# 离线跑时自己给，否则 platform.sh 里 `[ "$UPGRADE_OPT_SAVE_PARTITIONS" = 1 ]` 在 set -u 下报错。
		export UPGRADE_OPT_SAVE_PARTITIONS=1
		. "$FIX/common.sh"
		. "$FIX/platform.sh"

		# ---- 只替换 IO/硬件，其余（diff 判定、分支、写入循环）保持上游原样 ----
		v() { :; }
		ask_bool() { return 1; }               # 非交互：永远不 Abort
		sync() { :; }
		sleep() { :; }
		mount() { printf 'mount %s\n' "$*" >>"$TRACE"; return 0; }
		umount() { printf 'umount %s\n' "$*" >>"$TRACE"; return 0; }
		partx() { printf 'partx %s\n' "$*" >>"$TRACE"; return 0; }
		grub-bios-setup() { printf 'grub-bios-setup %s\n' "$*" >>"$TRACE"; return 0; }
		part_magic_fat() { return 1; }
		part_magic_efi() { return 1; }          # 只用来跳过 grub 尾部改写，不影响分支
		get_magic_word() { printf 'eb63'; }
		export_bootdevice() { diskdev="sda"; return 0; }
		# part=0 时上游期望拿到"整盘"设备名；分区号从 1 开始
		export_partdevice() {
			if [ "$2" = 0 ]; then eval "$1=sda"; else eval "$1=\"sda$2\""; fi
			return 0
		}
		get_partitions() { cp "$WORK/partmap.$2" "/tmp/partmap.$2"; }
		get_image_dd() {                        # 记录一切；绝不写块设备
			printf 'get_image_dd %s\n' "$*" >>"$TRACE"
			case " $* " in
				*" of=/dev/"*) return 0 ;;
			esac
			return 0
		}
		platform_do_upgrade "$WORK/fake.img" >/dev/null 2>&1
	)
}

echo "== 分支判定：盘上 p3 是否会被写 =="
run_platform stock img_stock
grep -q 'of=/dev/sda1' "$TRACE" && ok "stock 镜像写了 p1" || bad "stock 镜像没写 p1"
grep -q 'of=/dev/sda2' "$TRACE" && ok "stock 镜像写了 p2" || bad "stock 镜像没写 p2"
grep -q 'of=/dev/sda  *bs=4096\|of=/dev/sda bs=4096' "$TRACE" && bad "stock 镜像走了整盘覆写（p3 会丢）" || ok "stock 镜像未整盘覆写"
grep -q 'bs=4096' "$TRACE" && bad "出现 bs=4096 的整盘写" || ok "没有整盘写（无 bs=4096）"
grep -q 'partx -d' "$TRACE" && bad "stock 镜像重建了分区表（partx -d）" || ok "stock 镜像未重建分区表"
grep -q 'of=/dev/sda3' "$TRACE" && bad "stock 镜像写了 p3" || ok "stock 镜像没碰 p3（p3 与快照可存活）"
grep -q 'skip=440 count=4 seek=440' "$TRACE" && ok "逐分区路径照旧回写 4 字节磁盘签名" || bad "缺磁盘签名回写"

echo "== 反例：镜像预置 p3（尺寸冻结）必须走整盘覆写 =="
run_platform prep3 img_prep3
grep -q 'bs=4096' "$TRACE" && ok "预置 p3 的镜像触发整盘覆写（符合 design 取舍）" || bad "预置 p3 却未整盘覆写（判定逻辑变了）"
grep -q 'partx -d' "$TRACE" && ok "整盘覆写后重建分区表（partx -d/-a）" || bad "整盘覆写后未重建分区表"

echo "== 反例：换 ROOTFS_PARTSIZE 必须走整盘覆写 =="
run_platform 2g img_2g
grep -q 'bs=4096' "$TRACE" && ok "p2 几何变化触发整盘覆写" || bad "p2 几何变化未触发整盘覆写"

echo "== diff 方向：只报\"镜像有、盘上没有\"的行 =="
disk_partmap; img_stock
d=$(grep -F -x -v -f "$WORK/partmap.bootdisk" "$WORK/partmap.image" 2>/dev/null)
[ -z "$d" ] && ok "盘上多出的 p3 不进入 diff（单向比较）" || bad "diff 方向反了：$d"

echo "== platform_check_image 对布局变化只告警、不阻断 =="
(
	set -u
	VERBOSE=1; INTERACTIVE=0
	. "$FIX/common.sh"
	. "$FIX/platform.sh"
	disk_partmap; img_prep3
	: >"$WORK/check.log"
	v() { printf '%s\n' "$*" >>"$WORK/check.log"; }
	ask_bool() { return 1; }
	part_magic_efi() { return 0; }
	get_magic_word() { printf 'eb63'; }
	export_bootdevice() { diskdev="sda"; return 0; }
	export_partdevice() { if [ "$2" = 0 ]; then eval "$1=sda"; else eval "$1=\"sda$2\""; fi; return 0; }
	get_partitions() { cp "$WORK/partmap.$2" "/tmp/partmap.$2"; }
	get_image_dd() { printf 'get_image_dd %s\n' "$*" >>"$WORK/check.log"; }
	platform_check_image "$WORK/fake.img"
	printf 'rc=%d\n' $? >>"$WORK/check.log"
) >/dev/null 2>&1
grep -q 'Partition layout has changed' "$WORK/check.log" && ok "布局变化有告警" || bad "缺少 layout changed 告警"
grep -q 'rc=0' "$WORK/check.log" && ok "非交互下 check_image 返回 0（不阻断）" || bad "check_image 非交互下阻断了"

rm -rf "$WORK"
echo "---"
if [ "$fail" = 0 ]; then
	echo "SYSUPGRADE-LAYOUT OK"
	exit 0
fi
echo "SYSUPGRADE-LAYOUT FAILED"
exit 1
