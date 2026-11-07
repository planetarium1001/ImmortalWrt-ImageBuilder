#!/bin/sh
# phase1/tools/image-selfcheck.sh —— 对产出的镜像做机械自检（CI 与本地共用同一份判据）
#
# 为什么单独成脚本：ac-2 / ac-3 / ac-4(dev) / ac-8 的判据必须**本地也能复跑**。
# 把它们内联在 CI 的 YAML 里，等于"只有 CI 能判定"，本地取证只能靠人手抄日志。
#
# 用法：
#   sudo sh phase1/tools/image-selfcheck.sh <img.gz|img> --mode dev|prod [--init-sha SHA] [--manifest-min N]
#
# 参数：
#   <img.gz|img>      产物（.gz 自动 gunzip 到临时目录；.img 直接挂）
#   --mode dev|prod   dev 必须有 /etc/DEV-IMAGE + /etc/uci-defaults/90-dev-image + firewall 里的 dev-open-wan
#                     + /etc/dropbear/authorized_keys（0700/0600，无外设设备的唯一登录通道）；
#                     prod 这些都不许有（含任何 SSH 公钥）
#   --init-sha SHA    期望的 initrd 内 /init 的 sha256（phase1/build.sh 打印的 INIT_SHA=<sha>）；
#                     给了就逐字比对，不给只打印（ac-3 的"与 initrd-build 证据一致"就靠这一条）
#   --manifest-min N  .ab-base-manifest 最少行数（默认 1000）
#   --keep            保留临时目录（排障用）
#
# 判据（全部 PASS/FAIL 行，任一 FAIL ⇒ exit 1）：
#   1 布局：p1 vfat 256M / p128 EF02 4M / p2 btrfs 到盘尾，且**物理顺序** p1 < p128 < p2
#   2 子卷：恰为 @root @overlay @docker @swap
#   3 内容：@root/etc/openwrt_release、manifest 行数、lib/preinit/80_mount_root 与仓库 HEAD 逐字节一致
#   4 引导：p1 的 boot/grub/grub.cfg（无 rootwait / 含 fstools_ignore_partname=1 与 panic=10 / 无 try-phase1）、
#           core.img 非空、serial.mod 与 terminal.mod 存在、grub-script-check 通过
#   5 initrd：p1 上有 initrd，解包后 /init 的 sha256 与 --init-sha 一致（给了才比）
#   6 dev/prod：见 --mode
#
# 需要：Linux + root + losetup/sgdisk/blkid/btrfs/python 之外只依赖 coreutils 与 btrfs-progs；
#       grub-script-check 与 cpio 缺失时对应检查记 FAIL（除非设 IMAGE_SELFCHECK_SOFT=1）。
set -u

PROG=phase1/tools/image-selfcheck.sh
REPO=$(cd "$(dirname "$0")/../.." && pwd)

die() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	[ "$#" -ge 2 ] && printf '  下一步: %s\n' "$2" >&2
	exit 2
}

IMG_SRC=''
MODE=''
INIT_SHA=''
MANIFEST_MIN=1000
KEEP=0
while [ "$#" -gt 0 ]; do
	case $1 in
	--mode)
		[ "$#" -ge 2 ] || die "--mode 需要值（dev|prod）"
		MODE=$2
		shift 2
		;;
	--init-sha)
		[ "$#" -ge 2 ] || die "--init-sha 需要值"
		INIT_SHA=$2
		shift 2
		;;
	--manifest-min)
		[ "$#" -ge 2 ] || die "--manifest-min 需要值"
		MANIFEST_MIN=$2
		shift 2
		;;
	--keep)
		KEEP=1
		shift
		;;
	-h | --help)
		sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		die "未知选项: $1"
		;;
	*)
		[ -z "$IMG_SRC" ] || die "多余的参数: $1（只接受一个镜像路径）"
		IMG_SRC=$1
		shift
		;;
	esac
done

[ -n "$IMG_SRC" ] || die "缺少镜像路径（看 --help）"
[ -f "$IMG_SRC" ] || die "镜像不存在: ${IMG_SRC}"
case $MODE in
dev | prod) ;;
'') die "必须给 --mode dev|prod（dev 与 prod 的判据不同）" ;;
*) die "--mode 只接受 dev|prod（给的是: ${MODE}）" ;;
esac
case $MANIFEST_MIN in
'' | *[!0-9]*) die "--manifest-min 必须是正整数" ;;
esac

if [ "$(uname -s 2>/dev/null)" != Linux ]; then
	printf 'PEND  %s 只能在 Linux 上跑（当前 %s）\n' "$PROG" "$(uname -s 2>/dev/null || echo unknown)"
	exit 2
fi
if [ "$(id -u 2>/dev/null)" != 0 ]; then
	printf 'PEND  %s 需要 root（losetup/mount）\n' "$PROG"
	exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/phase1-selfcheck.XXXXXX") || die "mktemp -d 失败"
LOOP=''
MNT_P1=$WORK/mnt-p1
MNT_P2=$WORK/mnt-p2
MNT_ROOT=$WORK/mnt-root
MNT_IR=$WORK/initrd-extract
FAILED=0
SOFT=${IMAGE_SELFCHECK_SOFT:-0}

pass() { printf 'PASS  %s\n' "$*"; }
note() { printf 'NOTE  %s\n' "$*"; }
fail() {
	if [ "$SOFT" = 1 ]; then
		printf 'NOTE(soft) %s\n' "$*"
	else
		printf 'FAIL  %s\n' "$*"
		FAILED=1
	fi
}

cleanup() {
	for _d in "$MNT_ROOT" "$MNT_P2" "$MNT_P1"; do
		[ -d "$_d" ] || continue
		umount "$_d" 2>/dev/null || umount -l "$_d" 2>/dev/null || true
	done
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
	if [ "$KEEP" = 1 ]; then
		printf 'NOTE  临时目录保留: %s\n' "$WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT INT TERM

mkdir -p "$MNT_P1" "$MNT_P2" "$MNT_ROOT" "$MNT_IR"

# ---- 0. 解压（.gz 就 gunzip 一份；解析后立刻 gzip -t 一次，ac-8 的一半）----
printf '=== 0. 产物 ===\n'
printf 'file  %s (%s)\n' "$IMG_SRC" "$(wc -c <"$IMG_SRC" | tr -d ' ') bytes"
case $IMG_SRC in
*.gz)
	if gzip -t "$IMG_SRC" 2>/dev/null; then
		pass "gzip -t 通过"
	else
		fail "gzip -t 失败（产物损坏）"
	fi
	IMG=$WORK/image.img
	gunzip -c "$IMG_SRC" >"$IMG" || fail "解压失败: ${IMG_SRC}"
	;;
*)
	IMG=$IMG_SRC
	;;
esac
if [ -s "$IMG" ]; then
	pass "镜像文件非空（$(wc -c <"$IMG" | tr -d ' ') bytes）"
else
	fail "镜像文件为空: ${IMG}"
fi

# ---- 1. 挂 loop ----
LOOP=$(losetup -fP --show "$IMG" 2>/dev/null) || LOOP=''
[ -n "$LOOP" ] || die "losetup 挂不上 ${IMG}" "确认 loop 模块可用（modprobe loop）"
partx -a "$LOOP" 2>/dev/null || partx -u "$LOOP" 2>/dev/null || true
_i=0
while [ "$_i" -lt 10 ]; do
	[ -b "${LOOP}p2" ] && break
	sleep 1
	_i=$((_i + 1))
done
printf 'loop  %s  分区: p1=%s p2=%s\n' "$LOOP" "${LOOP}p1" "${LOOP}p2"
[ -b "${LOOP}p1" ] || fail "镜像里没有 p1 分区节点"
[ -b "${LOOP}p2" ] || fail "镜像里没有 p2 分区节点"

# ---- 2. 布局与物理顺序 ----
printf '\n=== 1. 布局 ===\n'
TABLE=$(sgdisk -p "$LOOP" 2>/dev/null) || TABLE=''
printf '%s\n' "$TABLE"
if [ -z "$TABLE" ]; then
	fail "sgdisk -p 读不到分区表"
else
	TOTAL=$(blockdev --getsz "$LOOP" 2>/dev/null || echo 0)
	p1s=$(printf '%s\n' "$TABLE" | awk '$1 == 1 {print $2}')
	p1e=$(printf '%s\n' "$TABLE" | awk '$1 == 1 {print $3}')
	p128s=$(printf '%s\n' "$TABLE" | awk '$1 == 128 {print $2}')
	p128e=$(printf '%s\n' "$TABLE" | awk '$1 == 128 {print $3}')
	p128t=$(printf '%s\n' "$TABLE" | awk '$1 == 128 {print $6}')
	p2s=$(printf '%s\n' "$TABLE" | awk '$1 == 2 {print $2}')
	p2e=$(printf '%s\n' "$TABLE" | awk '$1 == 2 {print $3}')

	if [ -n "${p1e:-}" ] && [ -n "${p1s:-}" ] && [ "$((p1e - p1s + 1))" = 524288 ]; then
		pass "p1 = 256 MiB（524288 扇区）"
	else
		fail "p1 不是 256 MiB（start=${p1s:-?} end=${p1e:-?}）"
	fi
	if [ -n "${p128e:-}" ] && [ -n "${p128s:-}" ] && [ "$((p128e - p128s + 1))" = 8192 ] && [ "${p128t:-}" = EF02 ]; then
		pass "p128 = 4 MiB / EF02"
	else
		fail "p128 不符（start=${p128s:-?} end=${p128e:-?} type=${p128t:-?}）"
	fi
	if [ "${p2e:-0}" -ge "$((TOTAL - 40))" ] 2>/dev/null; then
		pass "p2 占到盘尾（end=${p2e} / total=${TOTAL}）"
	else
		fail "p2 没占到盘尾（end=${p2e:-?} / total=${TOTAL}）"
	fi
	# 物理顺序 = 首启扩容（10-grow-p2.sh）唯一的几何前提：p2 必须是最后一个
	if [ -n "${p1e:-}" ] && [ -n "${p128s:-}" ] && [ -n "${p2s:-}" ] &&
		[ "$p128s" -gt "$p1e" ] && [ "$p2s" -gt "$p128e" ]; then
		pass "物理顺序 p1 < p128 < p2（p2 最后，首启扩容只重建 p2）"
	else
		fail "物理顺序不是 p1 < p128 < p2（p1_end=${p1e:-?} p128=${p128s:-?}..${p128e:-?} p2_start=${p2s:-?}）"
	fi
fi
case $(blkid -s TYPE -o value "${LOOP}p1" 2>/dev/null) in
vfat) pass "p1 文件系统 = vfat" ;;
*) fail "p1 文件系统不是 vfat" ;;
esac
case $(blkid -s TYPE -o value "${LOOP}p2" 2>/dev/null) in
btrfs) pass "p2 文件系统 = btrfs" ;;
*) fail "p2 文件系统不是 btrfs" ;;
esac

# ---- 3. 子卷 ----
printf '\n=== 2. 子卷 ===\n'
if mount -o ro "${LOOP}p2" "$MNT_P2" 2>/dev/null; then
	SUBS=$(btrfs subvolume list "$MNT_P2" 2>/dev/null | awk '{print $NF}' | sed 's#.*/##' | sort | tr '\n' ' ')
	printf '子卷: [%s]\n' "$SUBS"
	if [ "$SUBS" = "@docker @overlay @root @swap " ]; then
		pass "子卷恰为 @root @overlay @docker @swap"
	else
		fail "子卷清单不符: [$SUBS]"
	fi
else
	fail "p2 无法只读挂载"
fi

# ---- 4. 内容 ----
printf '\n=== 3. 内容 ===\n'
if mount -o ro,subvol=@root "${LOOP}p2" "$MNT_ROOT" 2>/dev/null; then
	if [ -f "$MNT_ROOT/etc/openwrt_release" ]; then
		pass "@root/etc/openwrt_release 存在（$(awk -F= '/^PRETTY_NAME/ {print $2}' "$MNT_ROOT/etc/openwrt_release" 2>/dev/null)）"
	else
		fail "@root/etc/openwrt_release 缺失"
	fi
	if [ -f "$MNT_ROOT/.ab-base-manifest" ]; then
		_n=$(awk 'END {print NR}' "$MNT_ROOT/.ab-base-manifest")
		if [ "${_n:-0}" -ge "$MANIFEST_MIN" ]; then
			pass "@root/.ab-base-manifest 行数 ${_n}（>= ${MANIFEST_MIN}）"
		else
			fail "@root/.ab-base-manifest 行数 ${_n}（< ${MANIFEST_MIN}，基座疑似半残）"
		fi
	else
		fail "@root/.ab-base-manifest 缺失"
	fi
	if [ -f "$MNT_ROOT/lib/preinit/80_mount_root" ] &&
		cmp -s "$MNT_ROOT/lib/preinit/80_mount_root" "$REPO/files/lib/preinit/80_mount_root"; then
		pass "@root/lib/preinit/80_mount_root 与仓库 HEAD 逐字节一致（§O.1 补丁在）"
	else
		fail "@root/lib/preinit/80_mount_root 与仓库 files/lib/preinit/80_mount_root 不一致或缺失"
	fi

	# dev / prod 判据（ac-4）
	if [ "$MODE" = dev ]; then
		if [ -f "$MNT_ROOT/etc/DEV-IMAGE" ]; then
			pass "dev: /etc/DEV-IMAGE 存在"
			sed 's/^/       /' "$MNT_ROOT/etc/DEV-IMAGE" 2>/dev/null | head -6
			if grep -q '^type=dev' "$MNT_ROOT/etc/DEV-IMAGE" 2>/dev/null; then
				pass "dev: DEV-IMAGE 里 type=dev"
			else
				fail "dev: DEV-IMAGE 里没有 type=dev"
			fi
		else
			fail "dev: /etc/DEV-IMAGE 缺失"
		fi
		if [ -f "$MNT_ROOT/etc/uci-defaults/90-dev-image" ]; then
			pass "dev: /etc/uci-defaults/90-dev-image 存在"
			for _k in dev-open-wan src=wan proto=all target=ACCEPT; do
				if grep -q -- "$_k" "$MNT_ROOT/etc/uci-defaults/90-dev-image" 2>/dev/null; then
					pass "dev: 90-dev-image 含 ${_k}"
				else
					fail "dev: 90-dev-image 缺 ${_k}"
				fi
			done
		else
			fail "dev: /etc/uci-defaults/90-dev-image 缺失"
		fi
		# 镜像内的 firewall 必须**构建期**就带规则（90-dev-image 只是兜底）：
		# handoff §6 记录的判据缺口——dev 分支此前只断言首启脚本，没有断言镜像本体。
		if grep -q "option name 'dev-open-wan'" "$MNT_ROOT/etc/config/firewall" 2>/dev/null; then
			pass "dev: /etc/config/firewall 含 dev-open-wan（构建期写入）"
		else
			fail "dev: /etc/config/firewall 里没有 dev-open-wan（规则没在构建期写进镜像）"
		fi
		# 调试公钥：无外设设备唯一的登录通道，缺了就只能拔盘重写。
		# 路径语义见 .workflow/knowledge/fact/active/2026-11-07-openwrt-dropbear-root-etc-dropbear-autho.md
		if [ -d "$MNT_ROOT/etc/dropbear" ]; then
			_dperm=$(stat -c '%a' "$MNT_ROOT/etc/dropbear" 2>/dev/null || echo '?')
			if [ "$_dperm" = 700 ]; then
				pass "dev: /etc/dropbear 目录权限 0700"
			else
				fail "dev: /etc/dropbear 目录权限是 ${_dperm}（要求 0700，dropbear 拒绝 group/other 可写的目录）"
			fi
		else
			fail "dev: /etc/dropbear 目录缺失"
		fi
		AK=$MNT_ROOT/etc/dropbear/authorized_keys
		if [ -f "$AK" ]; then
			pass "dev: /etc/dropbear/authorized_keys 存在"
			_aperm=$(stat -c '%a' "$AK" 2>/dev/null || echo '?')
			if [ "$_aperm" = 600 ]; then
				pass "dev: authorized_keys 权限 0600"
			else
				fail "dev: authorized_keys 权限是 ${_aperm}（要求 0600）"
			fi
			if grep -qE '^(ssh-ed25519|ssh-rsa) AAAA' "$AK" 2>/dev/null; then
				pass "dev: authorized_keys 含合法公钥行"
			else
				fail "dev: authorized_keys 里没有 ssh-ed25519/ssh-rsa 公钥行"
			fi
			if cmp -s "$AK" "$REPO/phase1/dev/rootfs/etc/dropbear/authorized_keys"; then
				pass "dev: authorized_keys 与仓库 HEAD 逐字节一致"
			else
				fail "dev: authorized_keys 与仓库 phase1/dev/rootfs/etc/dropbear/authorized_keys 不一致"
			fi
		else
			fail "dev: /etc/dropbear/authorized_keys 缺失（刷到无外设设备上无法 SSH 登录）"
		fi
	else
		for _f in etc/DEV-IMAGE etc/uci-defaults/90-dev-image etc/dropbear/authorized_keys; do
			if [ -e "$MNT_ROOT/$_f" ]; then
				fail "prod: /${_f} 不该存在（prod 镜像不得带 dev 专有文件/认证材料）"
			else
				pass "prod: /${_f} 不存在"
			fi
		done
		if grep -rqs 'dev-open-wan' "$MNT_ROOT/etc" 2>/dev/null; then
			fail "prod: /etc 下出现 dev-open-wan"
		else
			pass "prod: /etc 下没有 dev-open-wan"
		fi
	fi
	# 首启扩容脚本两种类型都必须有
	if [ -f "$MNT_ROOT/etc/uci-defaults/10-grow-p2.sh" ]; then
		pass "${MODE}: /etc/uci-defaults/10-grow-p2.sh 存在"
	else
		fail "${MODE}: /etc/uci-defaults/10-grow-p2.sh 缺失（首启不会扩容）"
	fi
	umount "$MNT_ROOT" 2>/dev/null || true
else
	fail "@root 子卷无法只读挂载"
fi

# ---- 5. 引导分区 ----
printf '\n=== 4. 引导分区 ===\n'
if mount -o ro "${LOOP}p1" "$MNT_P1" 2>/dev/null; then
	CFG=$MNT_P1/boot/grub/grub.cfg
	if [ -f "$CFG" ]; then
		pass "p1 有 boot/grub/grub.cfg"
		if grep -q 'rootwait' "$CFG"; then
			fail "grub.cfg 含 rootwait（找不到根会无限等待，panic=10 永不触发）"
		else
			pass "grub.cfg 无 rootwait"
		fi
		grep -q 'fstools_ignore_partname=1' "$CFG" && pass "grub.cfg 含 fstools_ignore_partname=1" ||
			fail "grub.cfg 缺 fstools_ignore_partname=1"
		grep -q 'panic=10' "$CFG" && pass "grub.cfg 含 panic=10" || fail "grub.cfg 缺 panic=10"
		grep -q 'try-phase1' "$CFG" && fail "grub.cfg 含 try-phase1（最终镜像不该有试跑项）" ||
			pass "grub.cfg 不含 try-phase1"
		if grep -q '^menuentry ' "$CFG" && [ "$(grep -c '^menuentry ' "$CFG")" = 1 ]; then
			pass "grub.cfg 只有 1 个 menuentry（0 号项）"
		else
			fail "grub.cfg 的 menuentry 数量不是 1"
		fi
		if command -v grub-script-check >/dev/null 2>&1; then
			if grub-script-check "$CFG" 2>/dev/null; then
				pass "grub-script-check 通过"
			else
				fail "grub-script-check 失败"
			fi
		else
			fail "没有 grub-script-check（apt install grub-common）"
		fi
	else
		fail "p1 缺 boot/grub/grub.cfg"
	fi
	if [ -s "$MNT_P1/boot/grub/i386-pc/core.img" ]; then
		pass "p1 有 boot/grub/i386-pc/core.img（$(wc -c <"$MNT_P1/boot/grub/i386-pc/core.img" | tr -d ' ') bytes）"
	else
		fail "p1 缺 boot/grub/i386-pc/core.img（p128 EF02 装不上）"
	fi
	for _m in serial.mod terminal.mod; do
		[ -f "$MNT_P1/boot/grub/i386-pc/$_m" ] && pass "p1 有 grub 模块 ${_m}" ||
			fail "p1 缺 grub 模块 ${_m}"
	done

	# ---- 6. initrd 里的 /init ----
	printf '\n=== 5. initrd ===\n'
	IR=''
	for _c in "$MNT_P1"/boot/*initrd*.cpio.gz "$MNT_P1"/boot/*.cpio.gz; do
		if [ -f "$_c" ]; then
			IR=$_c
			break
		fi
	done
	if [ -z "$IR" ]; then
		fail "p1 的 boot/ 下没有 initrd（*.cpio.gz）"
	elif ! command -v cpio >/dev/null 2>&1; then
		fail "没有 cpio（apt install cpio），无法复核 initrd 内 /init"
	else
		pass "p1 有 initrd: ${IR##*/}（$(wc -c <"$IR" | tr -d ' ') bytes）"
		if (cd "$MNT_IR" && gzip -dc "$IR" | cpio -idm --quiet) 2>/dev/null; then
			if [ -f "$MNT_IR/init" ]; then
				_sha=$(sha256sum "$MNT_IR/init" | awk '{print $1}')
				chmod +x "$MNT_IR/init" 2>/dev/null
				pass "initrd 内 /init 可解出，sha256=${_sha}"
				if [ -n "$INIT_SHA" ]; then
					if [ "$_sha" = "$INIT_SHA" ]; then
						pass "initrd 内 /init 的 sha256 与构建打印的 INIT_SHA 一致"
					else
						fail "initrd 内 /init 的 sha256（${_sha}）与 INIT_SHA（${INIT_SHA}）不一致"
					fi
				else
					note "没有给 --init-sha，只打印不比对"
				fi
				# 判据必须是 /init 文件里**真的有**的东西：
				#   rdinit= 是 grub 传给内核的参数，不在 /init 文本里（上一版写错过，白挂了一轮 CI）。
				for _k in phase1_dev phase1_overlay phase1_bootsub; do
					grep -q "$_k" "$MNT_IR/init" && pass "initrd 内 /init 含 ${_k}" ||
						fail "initrd 内 /init 缺 ${_k}（可能打包了上游 /init）"
				done
				# /init 必须是本仓库模板渲染出来的（占位符已替换、无残留 @KEY@）
				if grep -qE '@[A-Z][A-Z0-9_]*@' "$MNT_IR/init"; then
					fail "initrd 内 /init 仍有未替换的占位符"
				else
					pass "initrd 内 /init 无残留占位符"
				fi
			else
				fail "initrd 解包后没有 /init"
			fi
		else
			fail "initrd 解包失败"
		fi
	fi
	umount "$MNT_P1" 2>/dev/null || true
else
	fail "p1 无法只读挂载"
fi

printf '\n=== 汇总 ===\n'
if [ "$FAILED" = 0 ]; then
	printf 'SELFCHECK OK（mode=%s）\n' "$MODE"
	exit 0
fi
printf 'SELFCHECK FAILED（mode=%s）\n' "$MODE"
exit 1
