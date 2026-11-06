#!/bin/sh
# ac-4：phase1/make-initramfs.sh 的静态/离线产物断言。
#
#   * --render-init-only 离线渲染 /init：无残留占位符、可 sh -n、0755、默认值与覆盖都生效
#   * 缺 usr/bin/{getfattr,setfattr} 时**必须**非 0 退出并给出 "apk add attr" 的可执行提示；
#     --allow-missing-xattr 是唯一放行方式（应急，语义写在提示里）
#   * 载荷清单：10 个 btrfs 依赖 ko + vfat/fat/nls_*（写 p1 日志）+ modules.builtin(.modinfo)
#   * 产物是 cpio newc + gzip -9；解包后 init 0755、软链正确、归档内无设备节点
#   * STAGE 缺输入时非 0 退出且列出缺哪个文件
#
# 全部离线：用一个"假 STAGE"（小文本文件冒充 busybox/ko）真的跑一遍 cpio+gzip，
# 这样验的是脚本的真实行为，不是抄一份期望值自证。不碰任何设备。
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

MK=$REPO/phase1/make-initramfs.sh
TM=$REPO/phase1/initramfs/init
KVER_DEF=6.12.103
NAME='phase1-make-initramfs-static'

[ -f "$MK" ] || { echo "  FAIL 缺少 $MK"; finish "$NAME"; }
[ -f "$TM" ] || { echo "  FAIL 缺少 $TM"; finish "$NAME"; }
MKTEXT=$(cat "$MK")

SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sb-mkinitrd.XXXXXX" 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 2
}

MODS_BTRFS='xxhash zstd_common zstd_compress zstd_decompress raid6_pq lzo_compress lzo_decompress xor libcrc32c btrfs'
MODS_FS='vfat fat nls_cp437 nls_iso8859-1 nls_utf8'

run_mk() { # [env 赋值...] -- [参数...]：跑构建脚本，合并输出
	_out=$SB_ROOT/out.log
	if sh "$MK" "$@" >"$_out" 2>&1; then _rc=0; else _rc=$?; fi
	cat "$_out"
	return 0
}

echo "== 静态：载荷清单写在脚本里（可 grep，不靠记忆）=="
for _m in $MODS_BTRFS; do
	contains "载荷常量含 btrfs 依赖 $_m" "$_m" "$(grep -E '^MODULES_BTRFS=' "$MK")"
done
eq "btrfs 依赖恰好 10 个（含容易漏的 xxhash）" '10' \
	"$(grep -E '^MODULES_BTRFS=' "$MK" | sed -e "s/.*='//" -e "s/'$//" | wc -w | tr -d ' ')"
for _m in $MODS_FS; do
	contains "载荷常量含 p1 日志用模块 $_m" "$_m" "$(grep -E '^MODULES_FS=' "$MK")"
done
contains "归档格式 newc" '--format newc' "$MKTEXT"
contains "owner 归一 0:0" '--owner 0:0' "$MKTEXT"
contains "gzip -9（内核 initramfs 只认 gzip）" 'gzip -9' "$MKTEXT"
contains "自带 gzip -t 自检" 'gzip -t' "$MKTEXT"
contains "解包后 sh -n init 自检" 'sh -n "$EX/init"' "$MKTEXT"
contains "init 0755 断言" "-rwxr-xr-x" "$MKTEXT"
contains "归档内无设备节点断言（CONFIG_DEVTMPFS=n）" "'^[cb][-rwx]'" "$MKTEXT"
contains "无残留占位符断言" '@[A-Z][A-Z0-9_]*@' "$MKTEXT"
contains "缺 xattr 时提示 apk add attr" 'apk add attr' "$MKTEXT"
contains "提供应急开关 --allow-missing-xattr" 'allow-missing-xattr' "$MKTEXT"
contains "支持 --render-init-only" 'render-init-only' "$MKTEXT"
contains "支持 --bootsub（p1 内引导目录，F-1）" 'bootsub' "$MKTEXT"
contains "默认引导目录是 boot 子目录（不是 p1 根）" 'BOOTSUB=${BOOTSUB:-boot}' "$MKTEXT"
for _k in ROOTDEV BOOTDEV BOOTSUB LOWER OVL; do
	contains "渲染占位符 @${_k}@" "@${_k}@" "$MKTEXT"
done

echo "== --render-init-only：真渲染，无残留占位符 =="
R=$SB_ROOT/init.rendered
unset STAGE 2>/dev/null || true
if sh "$MK" --render-init-only "$R" >"$SB_ROOT/r1.log" 2>&1; then
	ok "--render-init-only 不需要 STAGE 就能跑（rc=0）"
else
	bad "--render-init-only 失败：$(tail -2 "$SB_ROOT/r1.log" | tr '\n' ' ')"
fi
if [ -f "$R" ]; then ok "产出 $R"; else bad "没有产出文件"; fi
eq "无残留 @大写@ 占位符" '' "$(grep -Eo '@[A-Z][A-Z0-9_]*@' "$R" 2>/dev/null | sort -u | tr '\n' ' ')"
if sh -n "$R" 2>/dev/null; then ok "渲染结果 sh -n 通过"; else bad "渲染结果有语法错误"; fi
eq "渲染结果权限 0755" '-rwxr-xr-x' "$(ls -l "$R" | cut -c1-10)"
contains "默认 phase1_dev" "DEF_DEV='/dev/nvme0n1p3'" "$(cat "$R")"
contains "默认 phase1_boot" "DEF_BOOT='/dev/nvme0n1p1'" "$(cat "$R")"
contains "默认 phase1_lower" "DEF_LOWER='@root'" "$(cat "$R")"
contains "默认 phase1_overlay" "DEF_OVL='@overlay'" "$(cat "$R")"
contains "默认 phase1_bootsub" "DEF_BOOTSUB='boot'" "$(cat "$R")"

R2=$SB_ROOT/init.override
ROOTDEV=/dev/sdz9 BOOTDEV=/dev/sdz1 LOWER=@rootA OVL=@ovlB KVER=9.9.9 \
	sh "$MK" --render-init-only "$R2" >"$SB_ROOT/r2.log" 2>&1
contains "环境变量覆盖 ROOTDEV" "DEF_DEV='/dev/sdz9'" "$(cat "$R2")"
contains "环境变量覆盖 BOOTDEV" "DEF_BOOT='/dev/sdz1'" "$(cat "$R2")"
contains "环境变量覆盖 LOWER" "DEF_LOWER='@rootA'" "$(cat "$R2")"
contains "环境变量覆盖 OVL" "DEF_OVL='@ovlB'" "$(cat "$R2")"
R3=$SB_ROOT/init.opt
sh "$MK" --render-init-only "$R3" --rootdev=/dev/sdq3 --lower=@rootX --overlay=@ovlX \
	--bootdev /dev/sdq1 >"$SB_ROOT/r3.log" 2>&1
contains "--key=value 形式生效" "DEF_DEV='/dev/sdq3'" "$(cat "$R3")"
contains "--key value 形式生效" "DEF_BOOT='/dev/sdq1'" "$(cat "$R3")"
contains "--lower= 形式生效" "DEF_LOWER='@rootX'" "$(cat "$R3")"
eq "--render-init-only 走覆盖后仍无占位符" '' \
	"$(grep -Eo '@[A-Z][A-Z0-9_]*@' "$R3" 2>/dev/null | sort -u | tr '\n' ' ')"

echo "== 未知选项/缺值必须非 0 =="
if sh "$MK" --render-init-only "$SB_ROOT/x" --no-such-option >"$SB_ROOT/r4.log" 2>&1; then
	bad "未知选项竟然 rc=0"
else
	contains "未知选项报错可读" '未知选项' "$(cat "$SB_ROOT/r4.log")"
fi
if sh "$MK" --render-init-only >"$SB_ROOT/r5.log" 2>&1; then
	bad "--render-init-only 缺值竟然 rc=0"
else
	contains "缺值报错可读" '缺少值' "$(cat "$SB_ROOT/r5.log")"
fi

# ---------------------------------------------------------------------------
# 假 STAGE：小文本文件冒充 busybox/kmodloader/ko，验证的是脚本行为本身
# ---------------------------------------------------------------------------
mk_fake_stage() { # <目录> <kver> [with_xattr=1]
	_d=$1
	_k=$2
	_x=${3:-0}
	rm -rf "$_d"
	mkdir -p "$_d/bin" "$_d/sbin" "$_d/lib/modules/$_k"
	printf 'fake-busybox-payload\n' >"$_d/bin/busybox"
	printf 'fake-kmodloader-payload\n' >"$_d/sbin/kmodloader"
	printf 'fake-libc\n' >"$_d/lib/libc.so"
	ln -s libc.so "$_d/lib/ld-musl-x86_64.so.1"
	printf 'fake-libubox\n' >"$_d/lib/libubox.so.20260213"
	printf 'fake-libgcc\n' >"$_d/lib/libgcc_s.so.1"
	printf 'fake-builtin\n' >"$_d/lib/modules/$_k/modules.builtin"
	printf 'fake-builtin-modinfo\n' >"$_d/lib/modules/$_k/modules.builtin.modinfo"
	for _m in $MODS_BTRFS $MODS_FS; do
		printf 'fake-ko %s\n' "$_m" >"$_d/lib/modules/$_k/$_m.ko"
	done
	if [ "$_x" = 1 ]; then
		mkdir -p "$_d/usr/bin"
		printf 'fake-getfattr\n' >"$_d/usr/bin/getfattr"
		printf 'fake-setfattr\n' >"$_d/usr/bin/setfattr"
	fi
}

check_archive() { # <cpio.gz>：解包后逐项检查
	_gz=$1
	if gzip -t "$_gz" 2>/dev/null; then ok "gzip -t 通过"; else bad "gzip -t 失败"; fi
	_lst=$SB_ROOT/list.txt
	gzip -dc "$_gz" | cpio -itv 2>/dev/null >"$_lst"
	eq "归档内没有设备节点" '' "$(grep -E '^[cb][-rwx]' "$_lst" 2>/dev/null | tr '\n' ' ')"
	_ex=$SB_ROOT/ex
	rm -rf "$_ex"
	mkdir -p "$_ex"
	gzip -dc "$_gz" >"$SB_ROOT/unpack.cpio"
	( cd "$_ex" && cpio -id --quiet <"$SB_ROOT/unpack.cpio" ) 2>/dev/null
	eq "解包后 /init 权限 0755" '-rwxr-xr-x' "$(ls -l "$_ex/init" 2>/dev/null | cut -c1-10)"
	if sh -n "$_ex/init" 2>/dev/null; then ok "解包后 /init sh -n 通过"; else bad "解包后 /init 语法错误"; fi
	eq "解包后 /init 无占位符" '' "$(grep -Eo '@[A-Z][A-Z0-9_]*@' "$_ex/init" 2>/dev/null | sort -u | tr '\n' ' ')"
	eq "sbin/modprobe -> kmodloader" 'kmodloader' "$(readlink "$_ex/sbin/modprobe" 2>/dev/null)"
	eq "sbin/insmod -> kmodloader" 'kmodloader' "$(readlink "$_ex/sbin/insmod" 2>/dev/null)"
	eq "sbin/rmmod -> kmodloader" 'kmodloader' "$(readlink "$_ex/sbin/rmmod" 2>/dev/null)"
	eq "sbin/lsmod -> kmodloader" 'kmodloader' "$(readlink "$_ex/sbin/lsmod" 2>/dev/null)"
	eq "lib/ld-musl-x86_64.so.1 -> libc.so" 'libc.so' "$(readlink "$_ex/lib/ld-musl-x86_64.so.1" 2>/dev/null)"
	for _m in $MODS_BTRFS $MODS_FS; do
		if [ -f "$_ex/lib/modules/$KVER_DEF/$_m.ko" ]; then
			ok "归档含 ko: $_m"
		else
			bad "归档缺 ko: $_m"
		fi
	done
	for _f in lib/modules/$KVER_DEF/modules.builtin lib/modules/$KVER_DEF/modules.builtin.modinfo \
	          bin/busybox sbin/kmodloader proc sys dev tmp boot lower overlay newroot; do
		if [ -e "$_ex/$_f" ]; then ok "归档含 $_f"; else bad "归档缺 $_f"; fi
	done
	eq "libkmod 未被打进载荷（kmodloader 不依赖它）" 'absent' \
		"$( [ -e "$_ex/usr/lib/libkmod.so.2" ] && echo present || echo absent )"
}

echo "== 缺 xattr：必须非 0 且提示 apk add attr =="
FS1=$SB_ROOT/stage-noxattr
mk_fake_stage "$FS1" "$KVER_DEF" 0
OUT1=$SB_ROOT/out-noxattr.cpio.gz
if sh "$MK" --stage "$FS1" --out "$OUT1" >"$SB_ROOT/b1.log" 2>&1; then
	bad "缺 getfattr/setfattr 时构建竟然成功"
else
	ok "缺 xattr 时构建非 0 退出"
fi
contains "报错给出 apk add attr 的补法" 'apk add attr' "$(cat "$SB_ROOT/b1.log")"
contains "报错点名缺哪个二进制" 'getfattr' "$(cat "$SB_ROOT/b1.log")"
contains "报错给出应急开关" '--allow-missing-xattr' "$(cat "$SB_ROOT/b1.log")"
eq "失败时没有产出归档" 'no' "$( [ -f "$OUT1" ] && echo yes || echo no )"

echo "== --allow-missing-xattr：应急放行且产物能用 =="
if sh "$MK" --stage "$FS1" --out "$OUT1" --allow-missing-xattr >"$SB_ROOT/b2.log" 2>&1; then
	ok "--allow-missing-xattr 构建成功（rc=0）"
else
	bad "应急开关没生效：$(tail -2 "$SB_ROOT/b2.log" | tr '\n' ' ')"
fi
contains "应急产物在日志里显式标注 xattr 缺失" 'ALLOW_MISSING_XATTR=1' "$(cat "$SB_ROOT/b2.log")"
contains "汇总里打印 sha256" 'sha256' "$(cat "$SB_ROOT/b2.log")"
contains "汇总里打印 raw/gz 字节数" 'gz   bytes' "$(cat "$SB_ROOT/b2.log")"
check_archive "$OUT1"

echo "== 有 xattr 工具：不加开关也能构建，且二进制进载荷 =="
FS2=$SB_ROOT/stage-xattr
mk_fake_stage "$FS2" "$KVER_DEF" 1
OUT2=$SB_ROOT/out-xattr.cpio.gz
if sh "$MK" --stage "$FS2" --out "$OUT2" >"$SB_ROOT/b3.log" 2>&1; then
	ok "带 getfattr/setfattr 的 STAGE 构建成功（rc=0）"
else
	bad "带 xattr 的 STAGE 构建失败：$(tail -3 "$SB_ROOT/b3.log" | tr '\n' ' ')"
fi
gzip -dc "$OUT2" >"$SB_ROOT/u2.cpio" 2>/dev/null
eq "归档含 usr/bin/getfattr" 'yes' \
	"$( gzip -dc "$OUT2" | cpio -it 2>/dev/null | grep -qx 'usr/bin/getfattr' && echo yes || echo no )"
eq "归档含 usr/bin/setfattr" 'yes' \
	"$( gzip -dc "$OUT2" | cpio -it 2>/dev/null | grep -qx 'usr/bin/setfattr' && echo yes || echo no )"

echo "== STAGE 缺输入：非 0 且点名缺哪个文件 =="
FS3=$SB_ROOT/stage-noko
mk_fake_stage "$FS3" "$KVER_DEF" 1
rm -f "$FS3/lib/modules/$KVER_DEF/btrfs.ko"
if sh "$MK" --stage "$FS3" --out "$SB_ROOT/out-noko.cpio.gz" >"$SB_ROOT/b4.log" 2>&1; then
	bad "缺 btrfs.ko 竟然构建成功"
else
	ok "缺 btrfs.ko 时非 0 退出"
fi
contains "报错点名缺失的 ko" "lib/modules/$KVER_DEF/btrfs.ko" "$(cat "$SB_ROOT/b4.log")"

echo "== 无 STAGE：非 0 且提示需要 --stage =="
if env -u STAGE sh "$MK" --out "$SB_ROOT/nope.cpio.gz" >"$SB_ROOT/b5.log" 2>&1; then
	bad "没有 STAGE 竟然构建成功"
else
	ok "没有 STAGE 时非 0 退出"
fi
contains "报错提示 --stage" '--stage' "$(cat "$SB_ROOT/b5.log")"

echo "== 产物里的 /init 就是模板按默认值渲染的结果 =="
# 用文档里的默认值自己渲染一遍模板，与归档里的 /init 逐字比较：
# 脚本若少替换/多改写一个字都会被这条抓到（渲染逻辑不允许"顺手优化"）。
_ex=$SB_ROOT/ex
if [ -f "$_ex/init" ]; then
	sed -e "s|@ROOTDEV@|/dev/nvme0n1p3|g" \
	    -e "s|@BOOTDEV@|/dev/nvme0n1p1|g" \
	    -e "s|@BOOTSUB@|boot|g" \
	    -e "s|@LOWER@|@root|g" \
	    -e "s|@OVL@|@overlay|g" \
	    "$TM" >"$SB_ROOT/init.expected"
	if diff -q "$SB_ROOT/init.expected" "$_ex/init" >/dev/null 2>&1; then
		ok "归档里的 /init == 模板 + 5 个占位符替换（无其它改写）"
	else
		bad "归档里的 /init 与预期渲染结果不一致：$(diff "$SB_ROOT/init.expected" "$_ex/init" | head -4 | tr '\n' '|')"
	fi
fi

finish PHASE1-MAKE-INITRAMFS-STATIC
