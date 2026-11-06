#!/bin/sh
# =============================================================================
# phase1/make-initramfs.sh —— Phase 1 initramfs 构建（cpio newc + gzip -9）
#
# 从设备取回的文件树（STAGE）里 stage 出最小载荷，渲染 phase1/initramfs/init
# 的占位符，打成内核能认的 newc + gzip 归档。
#
#   sh phase1/make-initramfs.sh --stage /path/to/stage --out /tmp/p1-initrd.cpio.gz
#   sh phase1/make-initramfs.sh --render-init-only /tmp/init.rendered     # 离线用例用，不要求 STAGE
#
# 选项（长选项 `--k v` / `--k=v`，或同名环境变量，环境变量优先级更低）：
#   --stage DIR              STAGE    设备取回的文件树（全量构建必需）
#   --out FILE               OUT      产物路径（默认 ${TMPDIR:-/tmp}/phase1-initrd.cpio.gz）
#   --kver VER               KVER     内核版本 = 模块目录名      默认 6.12.103
#   --rootdev DEV            ROOTDEV  btrfs 根所在分区           默认 /dev/nvme0n1p3
#   --bootdev DEV            BOOTDEV  p1（vfat，写持久日志）     默认 /dev/nvme0n1p1
#   --bootsub DIR            BOOTSUB  p1 内的引导目录            默认 boot（空 = 引导文件直放 p1 根）
#                                     ⇒ 标记/日志 = <p1>/<bootsub>/try-phase1|phase1-boot.log
#                                     （F-1：p1 根下有它自己的 boot/，不能拿 p1 根冒充 /boot）
#   --lower SUBVOL           LOWER    @root 子卷名（ro lower）   默认 @root
#   --overlay SUBVOL         OVL      @overlay 子卷名（写层）    默认 @overlay
#   --work DIR               WORK     构建临时目录（默认 mktemp -d）
#   --allow-missing-xattr    ALLOW_MISSING_XATTR=1  缺 getfattr/setfattr 也继续（应急，见下）
#   --render-init-only FILE  只渲染 /init，不打包、不要求 STAGE
#   --help
#
# 载荷（N.7 + 真机血泪坑）：
#   bin/busybox、lib/{libc.so, ld-musl-x86_64.so.1, libubox.so.<版本日期>, libgcc_s.so.1}、
#   sbin/kmodloader（+ modprobe/insmod/rmmod/lsmod 软链）、
#   lib/modules/$KVER/ 的 10 个 btrfs 依赖 ko + modules.builtin（.modinfo 可选）、
#   vfat/fat/nls_cp437/nls_iso8859-1/nls_utf8（写 p1 日志必需，v4/v5 就是缺它才"零痕迹"）、
#   usr/bin/{getfattr,setfattr}（N.3 要求：共享 upper 换 lower 要判 opaque/whiteout）
#
# 硬事实（别改回去）：
#   * 内核 initramfs 只支持 gzip（gunzip 在，unxz/unzstd/unlz4/unlzo 全不在）
#   * 归档内**不放**设备节点：本内核 CONFIG_DEVTMPFS=n，/init 自己 mount tmpfs /dev + mknod
#   * 设备上没有 cpio applet ⇒ 只能在宿主机侧打包（本脚本 macOS bsdcpio / Linux GNU cpio 都过）
# =============================================================================
set -eu

# ----------------------------- 1. 默认值 ------------------------------------
KVER=${KVER:-6.12.103}
ROOTDEV=${ROOTDEV:-/dev/nvme0n1p3}
BOOTDEV=${BOOTDEV:-/dev/nvme0n1p1}
BOOTSUB=${BOOTSUB:-boot}
LOWER=${LOWER:-@root}
OVL=${OVL:-@overlay}
STAGE=${STAGE:-}
OUT=${OUT:-}
WORK=${WORK:-}
ALLOW_MISSING_XATTR=${ALLOW_MISSING_XATTR:-0}
RENDER_ONLY=''
XATTR_BINS='getfattr setfattr'

# btrfs 的 10 个依赖 ko（拓扑序，依赖在前；modprobe 靠 .modinfo depends= 自动解析，
# 这个顺序只用于文档与 insmod 退化路径）
MODULES_BTRFS='xxhash zstd_common zstd_compress zstd_decompress raid6_pq lzo_compress lzo_decompress xor libcrc32c btrfs'
# 写 p1（vfat）日志用的模块：缺了日志就写不出来
MODULES_FS='vfat fat nls_cp437 nls_iso8859-1 nls_utf8'

REPO=$(cd "$(dirname "$0")/.." && pwd)
INIT_TMPL=$REPO/phase1/initramfs/init

# ----------------------------- 2. 日志 --------------------------------------
log()  { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
die()  { printf 'build: ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
	sed -n '2,46p' "$0" | sed -e 's|^# \{0,1\}||'
}

# ----------------------------- 3. 参数 --------------------------------------
apply_opt() { # <键(不带 --)> <值>
	case $1 in
		stage)               STAGE=$2 ;;
		out)                 OUT=$2 ;;
		kver)                KVER=$2 ;;
		rootdev)             ROOTDEV=$2 ;;
		bootdev)             BOOTDEV=$2 ;;
		bootsub)             BOOTSUB=$2 ;;
		lower)               LOWER=$2 ;;
		overlay)             OVL=$2 ;;
		work)                WORK=$2 ;;
		allow-missing-xattr) ALLOW_MISSING_XATTR=1 ;;
		render-init-only)    RENDER_ONLY=$2 ;;
		help)                usage; exit 0 ;;
		*)                   die "未知选项: --$1（--help 看用法）" ;;
	esac
}

while [ "$#" -gt 0 ]; do
	case $1 in
		--help|-h) usage; exit 0 ;;
		--allow-missing-xattr) apply_opt allow-missing-xattr 1; shift ;;
		--*=*)
			_k=${1#--}
			apply_opt "${_k%%=*}" "${_k#*=}"
			shift ;;
		--*)
			_k=${1#--}
			case $_k in
				stage|out|kver|rootdev|bootdev|bootsub|lower|overlay|work|render-init-only) ;;
				*) die "未知选项: --${_k}（--help 看用法）" ;;
			esac
			shift
			[ "$#" -gt 0 ] || die "选项 --$_k 缺少值（--help 看用法）"
			apply_opt "$_k" "$1"
			shift ;;
		*) die "多余的位置参数: $1（--help 看用法）" ;;
	esac
done

[ -n "$KVER" ] || die "KVER 不能为空"
[ -n "$ROOTDEV" ] || die "ROOTDEV 不能为空"
[ -n "$BOOTDEV" ] || die "BOOTDEV 不能为空"
[ -n "$LOWER" ] || die "LOWER 不能为空"
[ -n "$OVL" ] || die "OVL 不能为空"

# ----------------------------- 4. 小工具 ------------------------------------
sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "需要 sha256sum 或 shasum"
	fi
}

file_size() { wc -c < "$1" | tr -d ' '; }

sha256_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	else
		die "需要 sha256sum 或 shasum"
	fi
}

cpio_flavour() {
	if cpio --version 2>&1 | head -1 | grep -qi 'bsdcpio'; then
		printf 'bsdcpio/libarchive'
	else
		printf 'GNU cpio'
	fi
}

count_entries() { # <tar-list 文件>
	wc -l < "$1" | tr -d ' '
}

# ===========================================================================
# 5. 渲染 /init（--render-init-only 也走这里）
#    占位符只允许大写：@ROOTDEV@ @BOOTDEV@ @LOWER@ @OVL@
#    （/init 里的 '@docker' '@swap' 是小写子卷名，不是占位符）
# ===========================================================================
render_init() { # <输出文件>
	_out=$1
	[ -f "$INIT_TMPL" ] || die "缺少 /init 模板: $INIT_TMPL"
	mkdir -p "$(dirname "$_out")" || die "mkdir -p $(dirname "$_out") 失败"
	sed -e "s|@ROOTDEV@|$ROOTDEV|g" \
	    -e "s|@BOOTDEV@|$BOOTDEV|g" \
	    -e "s|@BOOTSUB@|$BOOTSUB|g" \
	    -e "s|@LOWER@|$LOWER|g" \
	    -e "s|@OVL@|$OVL|g" \
	    "$INIT_TMPL" > "$_out" || die "渲染 /init 失败（sed）"
	chmod 755 "$_out" || die "chmod 755 $_out 失败"
	_left=$(grep -Eo '@[A-Z][A-Z0-9_]*@' "$_out" 2>/dev/null | sort -u | tr '\n' ' ' || true)
	if [ -n "$_left" ]; then
		die "渲染后仍有未替换的占位符: ${_left}（模板与 make-initramfs.sh 的键名不一致？）"
	fi
	sh -n "$_out" || die "渲染后的 /init 语法错误（sh -n）: $_out"
	log "render: $INIT_TMPL"
	log "        -> $_out  (dev=$ROOTDEV boot=$BOOTDEV bootsub=${BOOTSUB:-<p1 根>} lower=$LOWER overlay=$OVL)"
}

if [ -n "$RENDER_ONLY" ]; then
	step "render-init-only"
	render_init "$RENDER_ONLY"
	printf 'rendered: %s\n' "$RENDER_ONLY"
	exit 0
fi

# ===========================================================================
# 6. 输入核对（全量构建）
# ===========================================================================
[ -n "$STAGE" ] || die "需要 --stage（或 STAGE=...）：设备取回的文件树，含 bin/busybox、lib/、sbin/kmodloader、lib/modules/$KVER/*.ko、usr/bin/{getfattr,setfattr}"
[ -d "$STAGE" ] || die "STAGE 不存在: $STAGE"

if [ -z "$OUT" ]; then
	OUT=${TMPDIR:-/tmp}/phase1-initrd.cpio.gz
fi
mkdir -p "$(dirname "$OUT")" || die "mkdir -p $(dirname "$OUT") 失败"

CLEAN_WORK=0
if [ -z "$WORK" ]; then
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/phase1-initramfs.XXXXXX") || die "mktemp -d 失败"
	CLEAN_WORK=1
else
	mkdir -p "$WORK" || die "mkdir -p $WORK 失败"
fi
cleanup() { [ "$CLEAN_WORK" = 1 ] && [ "${KEEP_WORK:-0}" != 1 ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM

step "0. 输入核对"
log "REPO    = $REPO"
log "STAGE   = $STAGE"
log "OUT     = $OUT"
log "WORK    = $WORK"
log "KVER    = $KVER   ROOTDEV=$ROOTDEV   BOOTDEV=$BOOTDEV   BOOTSUB=${BOOTSUB:-<p1 根>}"
log "LOWER   = $LOWER   OVL=$OVL"
log "cpio    = $(cpio_flavour)"

_missing=''
for _f in bin/busybox sbin/kmodloader \
          lib/libc.so lib/ld-musl-x86_64.so.1 lib/libgcc_s.so.1 \
          "lib/modules/$KVER/modules.builtin"; do
	[ -e "$STAGE/$_f" ] || _missing="$_missing $_f"
done
# libubox 的文件名带版本日期（libubox.so.<日期>），**不能改名**：kmodloader 的 DT_NEEDED 就是它自己
# 那一版的 soname，改了名动态链接器就找不到库，initrd 里连模块都加载不起来。所以这里按 glob 认。
_lu=''
for _c in "$STAGE"/lib/libubox.so.*; do
	if [ -e "$_c" ]; then
		_lu=$_c
	fi
done
[ -n "$_lu" ] || _missing="$_missing lib/libubox.so.<版本>"
# modules.builtin.modinfo 在裁剪过的 rootfs 里常被剥掉（只有 modules.builtin 是 kmodloader 必需）：
# 缺了只告警，不拦构建。
if [ ! -e "$STAGE/lib/modules/$KVER/modules.builtin.modinfo" ]; then
	log "WARN: STAGE 没有 lib/modules/$KVER/modules.builtin.modinfo（可选文件，继续）"
fi
for _m in $MODULES_BTRFS $MODULES_FS; do
	[ -f "$STAGE/lib/modules/$KVER/$_m.ko" ] || _missing="$_missing lib/modules/$KVER/$_m.ko"
done
if [ -n "$_missing" ]; then
	die "STAGE 缺少以下输入:$_missing
    取回方式（设备上）：apk add --no-network 不必；这些文件本来就在 live 系统里：
      /bin/busybox /sbin/kmodloader /lib/libc.so /lib/ld-musl-x86_64.so.1
      /lib/libubox.so.20260213 /lib/libgcc_s.so.1 /lib/modules/$KVER/*.ko
      （10 个 btrfs 依赖: ${MODULES_BTRFS}）
      （vfat 日志用: ${MODULES_FS}）"
fi
log "输入齐全：busybox + kmodloader + 3 个运行库 + $(( $(echo $MODULES_BTRFS | wc -w) + $(echo $MODULES_FS | wc -w) )) 个 .ko + modules.builtin(.modinfo)"

# ---- xattr 工具（N.3 必需项）----------------------------------------------
step "1. xattr 工具（getfattr/setfattr）"
_xmiss=''
for _b in $XATTR_BINS; do
	[ -f "$STAGE/usr/bin/$_b" ] || _xmiss="$_xmiss $_b"
done
if [ -n "$_xmiss" ]; then
	if [ "$ALLOW_MISSING_XATTR" = 1 ]; then
		log "WARN: ALLOW_MISSING_XATTR=1 —— 载荷缺少$_xmiss"
		log "      （应急产物：Phase 3 的 ab scrub 判 opaque/whiteout 时会没有 xattr 工具）"
		XATTR_STATE="MISSING(allowed:$_xmiss)"
	else
		die "载荷缺少 usr/bin/{getfattr,setfattr}（缺:${_xmiss}）
    这是 N.3 的必需项（共享 upper 换 lower 要判 opaque 目录/孤儿 whiteout）。
    补法：在设备上 apk add attr，然后取回
      /usr/bin/getfattr /usr/bin/setfattr   -> 放进 $STAGE/usr/bin/
      /usr/lib/libattr.so*（若有）           -> 放进 $STAGE/usr/lib/
    再重跑本脚本。应急（不推荐）：--allow-missing-xattr / ALLOW_MISSING_XATTR=1"
	fi
else
	XATTR_STATE='ok(usr/bin/getfattr + usr/bin/setfattr)'
	log "xattr: usr/bin/{getfattr,setfattr} 已就位"
fi

# ===========================================================================
# 7. 组装 rootfs
# ===========================================================================
step "2. 组装 rootfs"
ROOT=$WORK/rootfs
rm -rf "$ROOT"
mkdir -p "$ROOT"
cp -Rp "$STAGE/." "$ROOT/" || die "cp -Rp $STAGE -> $ROOT 失败"

# kmodloader 不依赖 libkmod（真机实测），带上只会白占体积
rm -f "$ROOT/usr/lib/libkmod.so.2" "$ROOT/usr/lib/libkmod.so.2.4.2"
rmdir "$ROOT/usr/lib" 2>/dev/null || true
rmdir "$ROOT/usr" 2>/dev/null || true

# /sbin/{modprobe,insmod,rmmod,lsmod} 是 kmodloader 的软链：行为由 argv[0] 决定。
# 只调 modprobe（`kmodloader <名字>` 是 rc=0 的静默假成功，别用）。
for _a in modprobe insmod rmmod lsmod; do
	rm -f "$ROOT/sbin/$_a"
	ln -s kmodloader "$ROOT/sbin/$_a" || die "ln -s kmodloader $ROOT/sbin/$_a 失败"
done

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/tmp" "$ROOT/boot" \
         "$ROOT/lower" "$ROOT/overlay" "$ROOT/newroot" || die "mkdir -p 载荷目录失败"
chmod 755 "$ROOT" "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/boot" \
          "$ROOT/lower" "$ROOT/overlay" "$ROOT/newroot" "$ROOT/bin" "$ROOT/sbin" "$ROOT/lib"
chmod 1777 "$ROOT/tmp"
log "rootfs: $(cd "$ROOT" && find . -mindepth 1 -print | wc -l | tr -d ' ') 个条目（不含 .）"

# ---- 渲染 /init 进 rootfs --------------------------------------------------
render_init "$ROOT/init"
[ -x "$ROOT/init" ] || die "rootfs/init 不可执行"

# ---- mtime 归一（两次构建的归档只差 newc 的 inode 字段，便于人眼/工具比对）----
PHASE1_MTIME=${PHASE1_MTIME:-202611060000.00}
find "$ROOT" -exec touch -h -t "$PHASE1_MTIME" {} + 2>/dev/null || true
log "mtime 归一: ${PHASE1_MTIME}（cpio newc 的 inode 号仍随构建变，sha256 只作产物标识）"

# ===========================================================================
# 8. 打包：cpio newc + gzip -9
# ===========================================================================
step "3. 打包（cpio newc --owner 0:0 + gzip -9）"
LIST=$WORK/filelist.txt
( cd "$ROOT" && find . -print | sed -e 's|^\.$||' -e 's|^\./||' | sed -e '/^$/d' | LC_ALL=C sort ) > "$LIST" \
	|| die "生成 filelist 失败"
[ -s "$LIST" ] || die "filelist 为空"

RAWCPIO=$WORK/initrd.cpio
( cd "$ROOT" && cpio -o --format newc --owner 0:0 --quiet < "$LIST" > "$RAWCPIO" ) \
	|| die "cpio -o 失败（$(cpio_flavour)）"
[ -s "$RAWCPIO" ] || die "cpio 归档为空"
gzip -9 -n -c "$RAWCPIO" > "$OUT" || die "gzip -9 失败"

RAW=$(file_size "$RAWCPIO")
GZ=$(file_size "$OUT")
SHA=$(sha256_file "$OUT")
log "raw  cpio : $RAW bytes"
log "gzip -9   : $GZ bytes  -> $OUT"

# ===========================================================================
# 9. 静态自检（解包后逐项断言，任何一项不过就非 0 退出）
# ===========================================================================
step "4. 静态自检"

gzip -t "$OUT" || die "gzip -t 失败：产物不是有效 gzip"
log "gzip -t   : OK"

gzip -dc "$OUT" | cpio -itv 2>/dev/null > "$WORK/list.txt" || die "cpio -itv 失败"
ENTRIES=$(count_entries "$WORK/list.txt")
log "entries   : $ENTRIES"

# 4.1 归档内不许有字符/块设备节点（CONFIG_DEVTMPFS=n 由 /init 自己 mknod）
if grep -E '^[cb][-rwx]' "$WORK/list.txt" > "$WORK/devnodes.txt"; then
	die "归档内有设备节点（必须由 /init 的 mknod 建，绝不能进归档）:
$(cat "$WORK/devnodes.txt")"
fi
log "device 节点: 无（OK：/init 自己 mknod）"

# 4.2 解包 + init 属性 + 软链
EX=$WORK/extract
rm -rf "$EX"
mkdir -p "$EX"
gzip -dc "$OUT" > "$WORK/unpack.cpio"
( cd "$EX" && cpio -id --quiet < "$WORK/unpack.cpio" ) || die "解包失败"
[ -f "$EX/init" ] || die "解包后没有 /init"
sh -n "$EX/init" || die "解包后 sh -n init 失败（POSIX 语法）"
log "sh -n init: OK"

INIT_PERM=$(ls -l "$EX/init" | cut -c1-10)
[ "$INIT_PERM" = '-rwxr-xr-x' ] || die "/init 权限不是 0755（实际 ${INIT_PERM}）"
log "init 模式 : 0755"

for _l in lib/ld-musl-x86_64.so.1 sbin/modprobe sbin/insmod sbin/rmmod sbin/lsmod; do
	[ -L "$EX/$_l" ] || die "归档里 $_l 不是软链（argv[0] 分派靠它）"
done
[ "$(readlink "$EX/sbin/modprobe")" = 'kmodloader' ] || die "sbin/modprobe 没有指向 kmodloader"
[ "$(readlink "$EX/lib/ld-musl-x86_64.so.1")" = 'libc.so' ] || die "ld-musl-x86_64.so.1 没有指向 libc.so"
log "软链      : ld-musl-x86_64.so.1 -> libc.so, sbin/{modprobe,insmod,rmmod,lsmod} -> kmodloader"

# 4.3 无残留占位符（大写 @XXX@；@docker/@swap 是小写子卷名，不算）
if grep -Eq '@[A-Z][A-Z0-9_]*@' "$EX/init"; then
	die "归档里的 /init 仍有未替换占位符: $(grep -Eo '@[A-Z][A-Z0-9_]*@' "$EX/init" | sort -u | tr '\n' ' ')"
fi
log "占位符    : 无残留"

# 4.4 载荷清单逐项在归档里（10 个 ko + vfat/nls）
for _m in $MODULES_BTRFS $MODULES_FS; do
	[ -f "$EX/lib/modules/$KVER/$_m.ko" ] || die "归档里缺模块: lib/modules/$KVER/$_m.ko"
done
[ -f "$EX/lib/modules/$KVER/modules.builtin" ] || die "归档里缺 modules.builtin"
_lu_ex=''
for _c in "$EX"/lib/libubox.so.*; do
	if [ -e "$_c" ]; then
		_lu_ex=$_c
	fi
done
[ -n "$_lu_ex" ] || die "归档里缺 lib/libubox.so.<版本>（kmodloader 的 soname 依赖）"
if [ ! -e "$EX/lib/modules/$KVER/modules.builtin.modinfo" ]; then
	log "WARN: 归档里没有 modules.builtin.modinfo（可选）"
fi
for _b in $XATTR_BINS; do
	if [ -f "$EX/usr/bin/$_b" ]; then
		log "xattr bin : usr/bin/$_b"
	elif [ "$ALLOW_MISSING_XATTR" = 1 ]; then
		log "xattr bin : usr/bin/$_b 缺失（ALLOW_MISSING_XATTR=1，已放行）"
	else
		die "归档里缺 usr/bin/${_b}（不该走到这里：上面已检查过）"
	fi
done
log "模块      : $MODULES_BTRFS"
log "            $MODULES_FS"

# 4.5 ELF 依赖闭包（启发式、只告警）：.dynstr 里出现的 lib*.so* 是否都在归档里
if command -v file >/dev/null 2>&1; then
	_present=$( cd "$EX" && find . \( -type f -o -type l \) -print | sed 's|.*/||' | LC_ALL=C sort -u )
	_unresolved=''
	for _f in $( cd "$EX" && find . -type f -print ); do
		file -b "$EX/$_f" 2>/dev/null | grep -q 'ELF' || continue
		for _so in $(LC_ALL=C grep -a -oE 'lib[a-zA-Z0-9_.+-]+\.so(\.[0-9]+)*' "$EX/$_f" 2>/dev/null | LC_ALL=C sort -u); do
			printf '%s\n' "$_present" | grep -qx -- "$_so" || _unresolved="$_unresolved $_f:$_so"
		done
	done
	if [ -n "$_unresolved" ]; then
		log "WARN: ELF 依赖闭包（启发式）有未能解析的库：$_unresolved"
		log "      若真机上相关二进制起不来，把对应 .so 取回 STAGE 再重建（attr 常见缺 libattr.so.1）"
	else
		log "ELF 闭包  : OK（启发式，未发现缺库）"
	fi
else
	log "ELF 闭包  : SKIP（宿主机没有 file 命令）"
fi

# ---- 4.6 载荷清单指纹：把"路径 + 每文件 sha256"排序后整体再哈希 ----
# 这是可复现的：同一份 STAGE 内容必然得到同一个值（不同于归档的 sha256，
# 后者含 cpio newc 的 inode 字段，随每次构建变化）。tm-03 用它对账"是不是同一份载荷"。
MANIFEST=$( cd "$ROOT" && find . -type f -print | LC_ALL=C sort | while IFS= read -r _f; do
	printf '%s  %s\n' "$(sha256_file "$_f")" "${_f#./}"
done )
MANIFEST_SHA=$(printf '%s\n' "$MANIFEST" | sha256_stdin)
MANIFEST_N=$(printf '%s\n' "$MANIFEST" | wc -l | tr -d ' ')
log "载荷指纹  : ${MANIFEST_SHA}（$MANIFEST_N 个文件，路径+每文件 sha256 排序后整体哈希；可复现）"

# ===========================================================================
# 10. 汇总
# ===========================================================================
step "summary"
cat <<EOF
initrd      : $OUT
raw  cpio   : $RAW bytes
gz   bytes  : $GZ bytes
sha256      : $SHA
gzip -t     : OK
entries     : $ENTRIES
init        : 0755, sh -n OK, 无残留占位符
symlinks    : ld-musl-x86_64.so.1->libc.so, sbin/{modprobe,insmod,rmmod,lsmod}->kmodloader
devnodes    : 归档内无（/init 自己 mknod）
xattr       : $XATTR_STATE
payload     : $MANIFEST_N 个文件, 指纹 ${MANIFEST_SHA}（可复现）
reproducible: mtime 已归一为 ${PHASE1_MTIME}；sha256 仅作产物标识（newc inode 号随构建变，同机重跑值会变）
kver        : $KVER
cmdline 默认 : phase1_dev=$ROOTDEV phase1_boot=$BOOTDEV phase1_bootsub=${BOOTSUB:-\<p1 根\>}
               phase1_lower=$LOWER phase1_overlay=$OVL
标记/日志    : <p1>/${BOOTSUB:-}<try-phase1|phase1-boot.log>   (F-1)
EOF
