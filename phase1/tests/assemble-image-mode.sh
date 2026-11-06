#!/bin/sh
# ac-1 / ac-2：phase1/assemble-image.sh 的镜像文件模式（--image OUT.img --size SIZE）。
#
# 三层断言，前两层离线（macOS 也能跑），第三层必须在 Linux + root 下真跑：
#   1. 参数校验：--image/--size 必填、互斥开关、尺寸格式与下限、拒绝设备与目录、
#      缺 rootfs/内核/initrd 时非 0 且给可执行提示；
#   2. --dry-run --image 打印**同一套**计划（truncate/losetup/sgdisk/mkfs/子卷/grub-install/
#      manifest/清理 trap），且真的一个字节都不写；
#   3. PHASE1_IMAGE_REAL=1（Linux + root + 工具齐全）时从零造一个真镜像，再 loop 挂回去
#      验布局 / 子卷 / manifest / grub.cfg —— 这就是"从零产出镜像"的机械证据。
#
# 第 3 层默认不跑（macOS 没有 losetup，也绝不能碰宿主磁盘）：此时记 PEND 理由后按通过处理，
# 真正的落地证据由 CI（ubuntu-22.04）跑同一个脚本给出。
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

AI=$REPO/phase1/assemble-image.sh
NAME=ASSEMBLE-IMAGE-MODE

[ -f "$AI" ] || {
	echo "  FAIL 缺少 $AI"
	finish "$NAME"
}
SRC=$(cat "$AI")

SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/phase1-image.XXXXXX" 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 1
}

run_ai() { # <日志名> [参数...]：跑脚本，非 0 也不让 set -u 之外的东西炸掉
	_log=$SB_ROOT/$1.log
	shift
	if sh "$AI" "$@" >"$_log" 2>&1; then _rc=0; else _rc=$?; fi
	return 0
}
log_of() { cat "$SB_ROOT/$1.log"; }

# 假的 rootfs / 内核 / initrd：--dry-run 与参数校验只做静态检查，不读内容
ROOTFS=$SB_ROOT/fake-rootfs
mkdir -p "$ROOTFS/etc"
printf 'DISTRIB_ID="ImmortalWrt"\n' >"$ROOTFS/etc/openwrt_release"
KERNEL=$SB_ROOT/vmlinuz
INITRD=$SB_ROOT/initrd.cpio.gz
printf 'fake-kernel\n' >"$KERNEL"
printf 'fake-initrd\n' >"$INITRD"
IMG=$SB_ROOT/out.img

echo "== 1. 参数校验（fail-closed）=="
run_ai nosize --image "$IMG" --rootfs "$ROOTFS" --kernel "$KERNEL" --initrd "$INITRD"
ne "缺 --size 非 0 退出" 0 "$_rc"
contains "缺 --size 提示点名 --size" '--size' "$(log_of nosize)"

run_ai noimage --size 8G --dry-run --rootfs "$ROOTFS" --kernel "$KERNEL" --initrd "$INITRD"
ne "只给 --size 非 0 退出" 0 "$_rc"

run_ai both --image "$IMG" --size 8G --disk /dev/nvme9n1 --rootfs "$ROOTFS" \
	--kernel "$KERNEL" --initrd "$INITRD"
ne "--image 与 --disk 互斥" 0 "$_rc"
contains "互斥提示点名 --disk" '--disk' "$(log_of both)"

run_ai grubdir --image "$IMG" --size 8G --grub-dir "$SB_ROOT/gd" --rootfs "$ROOTFS" \
	--kernel "$KERNEL" --initrd "$INITRD"
ne "--image 与 --grub-dir 互斥" 0 "$_rc"

run_ai trial --image "$IMG" --size 8G --trial --rootfs "$ROOTFS" \
	--kernel "$KERNEL" --initrd "$INITRD"
ne "--image 与 --trial 互斥" 0 "$_rc"

run_ai badsize --image "$IMG" --size 8X --rootfs "$ROOTFS" --kernel "$KERNEL" --initrd "$INITRD"
ne "尺寸格式非法非 0 退出" 0 "$_rc"
contains "尺寸格式提示给出合法写法" '8G' "$(log_of badsize)"

run_ai tinysize --image "$IMG" --size 1G --rootfs "$ROOTFS" --kernel "$KERNEL" --initrd "$INITRD"
ne "尺寸低于下限非 0 退出" 0 "$_rc"
contains "尺寸下限提示写明下限" '下限' "$(log_of tinysize)"

run_ai devpath --image /dev/sda1 --size 8G --rootfs "$ROOTFS" --kernel "$KERNEL" --initrd "$INITRD"
ne "拒绝把 /dev 当输出文件" 0 "$_rc"
contains "拒绝 /dev 输出时点名普通文件" '普通文件' "$(log_of devpath)"

printf 'old-content\n' >"$SB_ROOT/occupied.img"
run_ai occupied --dry-run --image "$SB_ROOT/occupied.img" --size 8G --rootfs "$ROOTFS" \
	--kernel "$KERNEL" --initrd "$INITRD"
ne "已存在的非空镜像默认拒绝覆盖" 0 "$_rc"
contains "拒绝覆盖时点名 --force-overwrite" '--force-overwrite' "$(log_of occupied)"
run_ai occupied_force --dry-run --image "$SB_ROOT/occupied.img" --size 8G --rootfs "$ROOTFS" \
	--kernel "$KERNEL" --initrd "$INITRD" --force-overwrite
eq "--force-overwrite 放行" 0 "$_rc"
eq "dry-run 没动已存在的文件" 'old-content' "$(cat "$SB_ROOT/occupied.img")"

mkdir -p "$SB_ROOT/adir"
run_ai outdir --image "$SB_ROOT/adir" --size 8G --rootfs "$ROOTFS" --kernel "$KERNEL" --initrd "$INITRD"
ne "拒绝目录作为输出" 0 "$_rc"

run_ai norootfs --image "$IMG" --size 8G --kernel "$KERNEL" --initrd "$INITRD"
ne "缺 --rootfs 非 0 退出" 0 "$_rc"
contains "缺 --rootfs 提示点名 --rootfs" '--rootfs' "$(log_of norootfs)"

run_ai nokernel --image "$IMG" --size 8G --rootfs "$ROOTFS" --initrd "$INITRD"
ne "缺 --kernel 非 0 退出" 0 "$_rc"

run_ai noinitrd --image "$IMG" --size 8G --rootfs "$ROOTFS" --kernel "$KERNEL"
ne "缺 --initrd 非 0 退出" 0 "$_rc"

echo "== 2. --dry-run --image 打印同一套计划，且不写盘 =="
run_ai plan --dry-run --image "$IMG" --size 8G --rootfs "$ROOTFS" --kernel "$KERNEL" --initrd "$INITRD"
eq "计划退出码 0" 0 "$_rc"
PLAN=$(log_of plan)

contains "计划里有 truncate" 'truncate -s 8G' "$PLAN"
contains "计划里有 losetup 挂镜像" 'losetup' "$PLAN"
contains "计划里 losetup 带分区扫描（-P/--partscan）" 'partscan' "$PLAN"
contains "计划里有 sgdisk 重建分区表" 'sgdisk --zap-all' "$PLAN"
contains "计划里有 p1 vfat 256M" '256M' "$PLAN"
contains "计划里有 p128 EF02 4M" 'EF02' "$PLAN"
contains "计划里有 p2 btrfs 名称" 'phase1-root' "$PLAN"
contains "计划里有 mkfs.vfat" 'mkfs.vfat -F 32 -n PHASE1BOOT' "$PLAN"
contains "计划里有 mkfs.btrfs 标签" 'mkfs.btrfs -f -L' "$PLAN"
contains "计划里有四个子卷" '@root @overlay @docker @swap' "$PLAN"
contains "计划里有 manifest" '/.ab-base-manifest' "$PLAN"
contains "计划里有 grub-install" 'grub-install --target=i386-pc' "$PLAN"
contains "计划里有 loop 清理" 'losetup -d' "$PLAN"
contains "计划里声明没有创建试跑标记" '试跑标记' "$PLAN"
contains "计划里声明不写盘" '没有对任何设备或文件执行写操作' "$PLAN"
not_contains "计划里没有 rootwait" 'rootwait' "$PLAN"
not_contains "计划里没有 root=PARTUUID=" 'root=PARTUUID=' "$PLAN"
if [ -e "$IMG" ]; then
	bad "dry-run 之后输出文件不该存在"
else
	ok "dry-run 之后输出文件不存在"
fi

echo "== 3. 源码静态约束（镜像模式）=="
contains "有专门的镜像写入函数" 'image_write() {' "$SRC"
contains "有镜像模式清理函数" 'image_teardown() {' "$SRC"
contains "清理注册在 EXIT 上" 'trap image_teardown EXIT' "$SRC"
contains "INT 走 130（中断不能退化成成功）" "trap 'image_teardown 130' INT" "$SRC"
contains "TERM/HUP 走 143" "trap 'image_teardown 143' TERM HUP" "$SRC"
contains "teardown 里 rc=0 时强制非 0" '_rc=1' "$SRC"
contains "覆盖已有文件要 --force-overwrite" '--force-overwrite' "$SRC"
contains "挂载点被占用时硬失败" '已被占用（并发构建或上次失败的残留）' "$SRC"
contains "镜像模式拒绝 /dev 输出" '必须是普通文件路径' "$SRC"
contains "镜像模式检查是否 root" '镜像模式需要 root' "$SRC"
contains "镜像模式要求 Linux" 'losetup' "$SRC"
contains "grub 模块含 serial" 'serial' "$SRC"
contains "grub 模块含 terminal" 'terminal' "$SRC"
if grep -qE '(^|[^[:alnum:]_])rm[[:space:]]+-[a-zA-Z]*r' "$AI"; then
	bad "源码出现 rm -r（递归删除）"
else
	ok "没有 rm -r"
fi
if grep -qE '(^|[^[:alnum:]_])rm[[:space:]][^|;&]*\*' "$AI"; then
	bad "源码出现通配删除（rm 带 *）"
else
	ok "没有通配删除"
fi

echo "== 4. 失败也要把 loop 拆掉（桩驱动，离线可跑）=="
# 用桩把"平台/权限/分区"三件事骗过去，让流程走到 sgdisk 失败，
# 断言：非 0 退出、错误点名 sgdisk、trap 里真的执行了 losetup -d。
# 这样即使没有 Linux/macOS 的 loop 设备，也能证明 fail-closed 与清理路径存在。
STUB=$SB_ROOT/stubs
mkdir -p "$STUB"
cat >"$STUB/uname" <<'EOS'
#!/bin/sh
printf 'Linux\n'
EOS
cat >"$STUB/id" <<'EOS'
#!/bin/sh
printf '0\n'
EOS
cat >"$STUB/losetup" <<EOS
#!/bin/sh
printf '%s\\n' "losetup \$*" >>"$SB_ROOT/stub.log"
case "\$1" in
--find | -f) printf '/dev/loop99\\n' ;;
esac
exit 0
EOS
cat >"$STUB/partx" <<EOS
#!/bin/sh
printf '%s\\n' "partx \$*" >>"$SB_ROOT/stub.log"
exit 0
EOS
cat >"$STUB/sgdisk" <<EOS
#!/bin/sh
printf '%s\\n' "sgdisk \$*" >>"$SB_ROOT/stub.log"
exit 1
EOS
# 其余"工具存在性检查"用的桩：不会被真的执行（sgdisk 先失败），只为了让 check_tools 过关
for _t in mkfs.vfat mkfs.btrfs btrfs grub-install mount umount; do
	cat >"$STUB/$_t" <<EOS
#!/bin/sh
printf '%s\\n' "$_t \$*" >>"$SB_ROOT/stub.log"
exit 0
EOS
done
chmod +x "$STUB"/*

FAILIMG=$SB_ROOT/fail.img
if PATH="$STUB:$PATH" sh "$AI" --image "$FAILIMG" --size 3G --rootfs "$ROOTFS" \
	--kernel "$KERNEL" --initrd "$INITRD" >"$SB_ROOT/failrun.log" 2>&1; then
	bad "sgdisk 失败时脚本仍然返回 0"
else
	ok "sgdisk 失败时脚本非 0 退出"
fi
contains "失败提示点名 sgdisk" 'sgdisk' "$(cat "$SB_ROOT/failrun.log" 2>/dev/null)"
_fsz=$(ls -ln "$FAILIMG" 2>/dev/null | awk '{print $5}')
eq "truncate 按 --size 建了 3G 的镜像文件" 3221225472 "${_fsz:-0}"
contains "losetup 带 --partscan 挂镜像" 'losetup --find --show --partscan' "$(cat "$SB_ROOT/stub.log" 2>/dev/null)"
contains "失败后 trap 执行 losetup -d" 'losetup -d /dev/loop99' "$(cat "$SB_ROOT/stub.log" 2>/dev/null)"
contains "失败提示给下一步" '下一步' "$(cat "$SB_ROOT/failrun.log" 2>/dev/null)"

echo "== 5. 真跑（Linux + root 才执行；其余记 PEND 理由）=="
if [ "${PHASE1_IMAGE_REAL:-0}" != 1 ]; then
	ok "跳过真跑：未设置 PHASE1_IMAGE_REAL=1（macOS 无 losetup，落地证据由 CI 提供）"
else
	_os=$(uname -s 2>/dev/null || echo unknown)
	_uid=$(id -u 2>/dev/null || echo 1)
	if [ "$_os" != Linux ] || [ "$_uid" != 0 ]; then
		bad "PHASE1_IMAGE_REAL=1 但环境不是 Linux+root（${_os} uid=${_uid}）"
	else
		# 夹具 rootfs 必须有 >=1000 个文件，否则 manifest 的"半残基座"闸门会（正确地）拦住
		REAL=$SB_ROOT/real
		mkdir -p "$REAL/rootfs/etc" "$REAL/rootfs/usr/bin" "$REAL/rootfs/lib"
		printf 'DISTRIB_ID="ImmortalWrt"\nDISTRIB_RELEASE="25.12.2"\n' >"$REAL/rootfs/etc/openwrt_release"
		i=1
		while [ "$i" -le 1100 ]; do
			printf 'x\n' >"$REAL/rootfs/usr/bin/f$i"
			i=$((i + 1))
		done
		printf 'fake-kernel-%s\n' "$$" >"$REAL/vmlinuz"
		printf 'fake-initrd-%s\n' "$$" >"$REAL/initrd.cpio.gz"

		RIMG=$REAL/real.img
		if sh "$AI" --image "$RIMG" --size 3G --rootfs "$REAL/rootfs" \
			--kernel "$REAL/vmlinuz" --initrd "$REAL/initrd.cpio.gz" \
			>"$REAL/build.log" 2>&1; then
			ok "从零产出镜像退出码 0"
		else
			bad "从零产出镜像失败（见下）"
			tail -12 "$REAL/build.log" | sed 's/^/       /'
		fi

		if [ -f "$RIMG" ] && [ "$(wc -c <"$RIMG")" -ge 1000000 ]; then
			ok "镜像文件存在且 >=1MB"
		else
			bad "镜像文件不存在或过小"
		fi

		# 挂回去验布局（只读挂载，验完立刻拆）
		LOOP=$(losetup -fP --show "$RIMG" 2>/dev/null || true)
		if [ -n "$LOOP" ]; then
			partx -u "$LOOP" 2>/dev/null || true
			sleep 1
			LAYOUT=$(sgdisk -p "$LOOP" 2>/dev/null || true)
			contains "镜像有 p1" '1 ' "$LAYOUT"
			contains "镜像有 p2" '2 ' "$LAYOUT"
			if [ -b "${LOOP}p2" ]; then
				mkdir -p "$REAL/mnt"
				if mount -o ro "${LOOP}p2" "$REAL/mnt" 2>/dev/null; then
					SUBS=$(btrfs subvolume list "$REAL/mnt" 2>/dev/null | awk '{print $NF}' | sed 's#.*/##' | sort | tr '\n' ' ')
					eq "子卷恰为 @docker @overlay @root @swap" '@docker @overlay @root @swap ' "$SUBS"
					umount "$REAL/mnt" || true
				else
					bad "p2 无法只读挂载"
				fi
				if mount -o ro,subvol=@root "${LOOP}p2" "$REAL/mnt" 2>/dev/null; then
					_n=$(wc -l <"$REAL/mnt/.ab-base-manifest" 2>/dev/null || echo 0)
					if [ "$_n" -ge 1000 ]; then
						ok "manifest 条目 >=1000（${_n}）"
					else
						bad "manifest 条目不足（${_n}）"
					fi
					umount "$REAL/mnt" || true
				else
					bad "@root 子卷无法只读挂载"
				fi
			else
				bad "镜像里没有 ${LOOP}p2 分区节点"
			fi
			if [ -b "${LOOP}p1" ]; then
				if mount -o ro "${LOOP}p1" "$REAL/mnt" 2>/dev/null; then
					CFG=$REAL/mnt/boot/grub/grub.cfg
					if [ -f "$CFG" ]; then
						ok "p1 上有 boot/grub/grub.cfg"
						not_contains "grub.cfg 无 rootwait" 'rootwait' "$(cat "$CFG")"
						contains "grub.cfg 含 fstools_ignore_partname=1" 'fstools_ignore_partname=1' "$(cat "$CFG")"
						contains "grub.cfg 含 panic=10" 'panic=10' "$(cat "$CFG")"
					else
						bad "p1 上没有 boot/grub/grub.cfg"
					fi
					umount "$REAL/mnt" || true
				else
					bad "p1 无法只读挂载"
				fi
			else
				bad "镜像里没有 ${LOOP}p1 分区节点"
			fi
			losetup -d "$LOOP" 2>/dev/null || true
		else
			bad "losetup 无法挂上产出的镜像"
		fi
	fi
fi

finish "$NAME"
