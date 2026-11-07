#!/bin/sh
# ac-3：initramfs/init 必须在 switch_root **之前**为新根建好 /proc /sys /dev /tmp。
#
# 为什么（2026-11-07 真机事故的第二个缺陷）：镜像的 @root 用 `tar --exclude=./proc ...` 打包，
# GNU tar 的 exclude 会把目录本体一起排掉 ⇒ 新根里没有这四个目录。procd 的 early_mounts()
# 用裸 mount(2) 挂 proc/sysfs/tmpfs/devtmpfs，既不 mkdir 也不检查返回值 ⇒ 全部 ENOENT 静默失败
# ⇒ 用户态没有 /proc /sys /dev ⇒ netifd 读不到 /sys/class/net ⇒ 一个网口都不配置。
# 判据只看行为顺序（行号先后），不看注释怎么写。
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

INIT=$REPO/phase1/initramfs/init
SB_ROOT=$(mktemp -d /tmp/phase1-newroot.XXXXXX 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 1
}

echo "== 1. 四个挂载点都被建 =="
for d in proc sys dev tmp; do
	if grep -q "for _d in .*proc.*sys.*dev.*tmp" "$INIT" && grep -q 'mkdir -p "\$P1_NEWROOT/\$_d"' "$INIT"; then
		ok "循环里 mkdir \$P1_NEWROOT/\${_d}（覆盖 ${d}）"
		break
	fi
done
grep -q 'for _d in proc sys dev tmp' "$INIT" &&
	ok "循环变量恰为 proc sys dev tmp" || bad "没找到 proc sys dev tmp 的循环"

echo "== 2. 缺一个就 die（不静默吞掉）=="
grep -q 'die newroot-mounts' "$INIT" &&
	ok "有 die newroot-mounts 兜底" || bad "没有 die 兜底"
grep -q 'mkdir -p "\$P1_NEWROOT/\$_d" ||' "$INIT" &&
	ok "mkdir 与 die 用 || 串联（失败即中止）" || bad "mkdir 失败没有被检查"

echo "== 3. 顺序：mkdir 必须在 exec switch_root 之前 =="
_mk_line=$(grep -n 'for _d in proc sys dev tmp' "$INIT" | head -1 | cut -d: -f1)
_switch_line=$(grep -n '^exec /bin/busybox switch_root' "$INIT" | head -1 | cut -d: -f1)
if [ -n "$_mk_line" ] && [ -n "$_switch_line" ]; then
	if [ "$_mk_line" -lt "$_switch_line" ]; then
		ok "mkdir(第 ${_mk_line} 行) 在 switch_root(第 ${_switch_line} 行) 之前"
	else
		bad "mkdir(第 ${_mk_line} 行) 在 switch_root(第 ${_switch_line} 行) 之后 —— 切根后再建没有意义"
	fi
else
	bad "没能定位 mkdir 或 switch_root 所在行（mkdir=${_mk_line:-空} switch_root=${_switch_line:-空}）"
fi

echo "== 3b. 顺序：mkdir 必须在 overlay 挂载**之后**（否则建在 initramfs 自己的 ramfs 上，切根即消失）=="
_ovl_line=$(grep -n 'mount -t overlay -o "\$P1_OVL_OPTS"' "$INIT" | head -1 | cut -d: -f1)
if [ -n "$_mk_line" ] && [ -n "$_ovl_line" ]; then
	if [ "$_mk_line" -gt "$_ovl_line" ]; then
		ok "mkdir(第 ${_mk_line} 行) 在 overlay 挂载(第 ${_ovl_line} 行) 之后 —— 建在写层上"
	else
		bad "mkdir(第 ${_mk_line} 行) 在 overlay 挂载(第 ${_ovl_line} 行) 之前 —— 目录会被 overlay 覆盖掉，等于没修"
	fi
else
	bad "没能定位 mkdir 或 overlay 挂载行（mkdir=${_mk_line:-空} overlay=${_ovl_line:-空}）"
fi

echo "== 4. 建的是新根（\${P1_NEWROOT}），不是 initramfs 自己的根 =="
grep -q 'mkdir -p "\$P1_NEWROOT/\$_d"' "$INIT" &&
	ok "目标是 \$P1_NEWROOT/\$_d" || bad "目标不是 \${P1_NEWROOT}（建到 initramfs 自己的根上等于没修）"
grep -n 'mkdir -p /proc /sys /dev /tmp ' "$INIT" >/dev/null 2>&1 &&
	ok "initramfs 自己的根仍由早期那句 mkdir 负责（两件事分开）" ||
	ok "早期 mkdir 形态变了（不强求，主判据是上面这条）"

echo "== 5. sh -n 语法 =="
sh -n "$INIT" && ok "phase1/initramfs/init 语法通过" || bad "phase1/initramfs/init 语法错误"

finish phase1-newroot-mountpoints
