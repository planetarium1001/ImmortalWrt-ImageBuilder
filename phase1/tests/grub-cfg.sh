#!/bin/sh
# ac-5：phase1/grub/grub.cfg.in 的渲染结果语义。
#
# 断言（brief 里列的每一条 + 两条负例）：
#   * 未 --trial 的渲染里没有试跑项，只有 1 个 menuentry；
#   * 任何 cmdline 都不出现 rootwait，也不出现 root=PARTUUID=；
#   * 每条 linux 行都含 fstools_ignore_partname=1 与 panic=10；
#   * `set fallback=0` 存在且 0 号项就是已知良好项；
#   * --trial 渲染里有 `[ -f /boot/try-phase1 ]` 守卫、`set default=1`、四个 phase1_* 键；
#   * 0 号项在两种渲染里逐字不变；
#   * 负例：cmdline 带 rootwait / 未知参数 → 非 0 退出。
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

AI=$REPO/phase1/assemble-image.sh
TPL=$REPO/phase1/grub/grub.cfg.in

SB_ROOT=$(mktemp -d /tmp/phase1-grub.XXXXXX 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 1
}
PLAIN=$SB_ROOT/plain
TRIAL=$SB_ROOT/trial

first_block() { # <grub.cfg>：打印第一个 menuentry 块（含 menuentry 行与 }），用于"逐字不变"比对
	awk '/^menuentry /{c++} c==1{print} c==1 && /^}/{exit}' "$1"
}

# md5：busybox/Linux 用 md5sum，macOS 用 md5 -q，再退 openssl；都没有时返回非 0（用例会 PEND）
md5_of() { # <文件>
	if command -v md5sum >/dev/null 2>&1; then
		md5sum "$1" | awk '{print $1}'
	elif command -v md5 >/dev/null 2>&1; then
		md5 -q "$1"
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -md5 "$1" | awk '{print $NF}'
	else
		return 1
	fi
}

echo "== 1. 模板本身 =="
[ -f "$TPL" ] && ok "模板存在" || bad "模板缺失: phase1/grub/grub.cfg.in"
[ -f "$AI" ] && ok "渲染器存在" || bad "渲染器缺失: phase1/assemble-image.sh"
contains "模板有试跑段落标记" '#@TRIAL_BEGIN@' "$(cat "$TPL" 2>/dev/null)"
contains "模板有标记守卫" 'if [ -f @MARKER@ ]; then' "$(cat "$TPL" 2>/dev/null)"
contains "模板有 fallback=0" 'set fallback=0' "$(cat "$TPL" 2>/dev/null)"
contains "模板默认项是 0" 'set default=0' "$(cat "$TPL" 2>/dev/null)"
contains "模板里 cmdline 用占位符" '@CMDLINE@' "$(cat "$TPL" 2>/dev/null)"

echo "== 2. 未 --trial 渲染（最终镜像形态）=="
sh "$AI" --grub-dir "$PLAIN" --kernel vmlinuz --initrd initrd.cpio.gz >"$SB_ROOT/plain.log" 2>&1
eq "渲染退出码 0" 0 $?
PC=$PLAIN/grub.cfg
if [ -f "$PC" ]; then
	ok "产出 $PC"
else
	bad "没有产出 grub.cfg"
	printf '       渲染输出: %s\n' "$(cat "$SB_ROOT/plain.log" | head -4 | tr '\n' '|')"
fi
PTXT=$(cat "$PC" 2>/dev/null)
not_contains "无 rootwait" 'rootwait' "$PTXT"
not_contains "无 root=PARTUUID=" 'root=PARTUUID=' "$PTXT"
contains "含 fstools_ignore_partname=1" 'fstools_ignore_partname=1' "$PTXT"
contains "含 panic=10" 'panic=10' "$PTXT"
contains "有 set fallback=0" 'set fallback=0' "$PTXT"
contains "0 号项是默认（set default=0）" 'set default=0' "$PTXT"
eq "只有 1 个 menuentry" 1 "$(grep -c '^menuentry ' "$PC" 2>/dev/null)"
not_contains "没有试跑标记逻辑" 'try-phase1' "$PTXT"
not_contains "没有试跑项 cmdline" 'phase1_dev=' "$PTXT"
contains "内核路径可逐字控制（/boot/vmlinuz）" 'linux /boot/vmlinuz ' "$PTXT"
contains "initrd 路径可逐字控制" 'initrd /boot/initrd.cpio.gz' "$PTXT"
# set default=0 必须在第一个 menuentry 之前（否则 0 号项不一定被选中）
_dl=$(grep -n '^set default=0$' "$PC" 2>/dev/null | head -1 | cut -d: -f1)
_ml=$(grep -n '^menuentry ' "$PC" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$_dl" ] && [ -n "$_ml" ] && [ "$_dl" -lt "$_ml" ]; then
	ok "set default=0 在第一个 menuentry 之前（指向 0 号项）"
else
	bad "set default=0 位置不对（default=$_dl menuentry=${_ml}）"
fi

echo "== 3. --trial 渲染（真机试跑形态）=="
sh "$AI" --grub-dir "$TRIAL" --kernel vmlinuz --initrd initrd.cpio.gz \
	--disk /dev/nvme9n1 --trial >"$SB_ROOT/trial.log" 2>&1
eq "渲染退出码 0" 0 $?
TC=$TRIAL/grub.cfg
if [ -f "$TC" ]; then
	ok "产出 $TC"
else
	bad "没有产出 grub.cfg（--trial）"
	printf '       渲染输出: %s\n' "$(cat "$SB_ROOT/trial.log" | head -4 | tr '\n' '|')"
fi
TTXT=$(cat "$TC" 2>/dev/null)
contains "主守卫 [ -f /boot/try-phase1 ]（= live /boot，p1:/boot/try-phase1）" '[ -f /boot/try-phase1 ]' "$TTXT"
contains "兜底守卫 [ -f /try-phase1 ]（grub root 指到分区根时才命中）" '[ -f /try-phase1 ]' "$TTXT"
eq "主守卫排在兜底之前" '/boot/try-phase1' \
	"$(printf '%s\n' "$TTXT" | grep -o '\[ -f /[a-z-]*/\?try-phase1 \]' | head -1 | sed -e 's/^\[ -f //' -e 's/ \]$//')"
contains "标记存在时默认项切到 1" 'set default=1' "$TTXT"
contains "试跑项带 phase1_dev=" 'phase1_dev=' "$TTXT"
contains "试跑项带 phase1_boot=" 'phase1_boot=' "$TTXT"
contains "试跑项带 phase1_bootsub=boot（= --boot-subdir）" 'phase1_bootsub=boot' "$TTXT"
contains "试跑项带 phase1_lower=" 'phase1_lower=' "$TTXT"
contains "试跑项带 phase1_overlay=" 'phase1_overlay=' "$TTXT"
contains "试跑项带 rdinit=/init" 'rdinit=/init' "$TTXT"
eq "有 2 个 menuentry" 2 "$(grep -c '^menuentry ' "$TC" 2>/dev/null)"
not_contains "试跑渲染也无 rootwait" 'rootwait' "$TTXT"
not_contains "试跑渲染无 root=PARTUUID=" 'root=PARTUUID=' "$TTXT"
eq "试跑项 phase1_dev 由 --disk 推出 p2" 'phase1_dev=/dev/nvme9n1p2' \
	"$(printf '%s\n' "$TTXT" | grep -o 'phase1_dev=/dev/[^ ]*' | head -1)"
eq "0 号项在两种渲染里逐字不变" "$(first_block "$PC")" "$(first_block "$TC")"

echo "== 4. 负例：不合格的 cmdline 必须被拒 =="
sh "$AI" --grub-dir "$SB_ROOT/bad1" --kernel vmlinuz --initrd initrd.cpio.gz \
	--cmdline 'fstools_ignore_partname=1 panic=10 rootwait' >"$SB_ROOT/bad1.log" 2>&1
ne "带 rootwait 的 cmdline 被拒（非 0）" 0 $?
[ -f "$SB_ROOT/bad1/grub.cfg" ] && bad "被拒时不该留下 grub.cfg" || ok "被拒时没有留下 grub.cfg"
contains "拒绝理由里点名 rootwait" 'rootwait' "$(cat "$SB_ROOT/bad1.log")"

sh "$AI" --grub-dir "$SB_ROOT/bad2" --kernel vmlinuz --initrd initrd.cpio.gz \
	--cmdline 'root=PARTUUID=deadbeef-0000 fstools_ignore_partname=1 panic=10' >"$SB_ROOT/bad2.log" 2>&1
ne "带 root=PARTUUID= 的 cmdline 被拒（非 0）" 0 $?

sh "$AI" --grub-dir "$SB_ROOT/bad3" --kernel vmlinuz --initrd initrd.cpio.gz \
	--cmdline 'panic=10' >"$SB_ROOT/bad3.log" 2>&1
ne "缺 fstools_ignore_partname=1 的 cmdline 被拒（非 0）" 0 $?

sh "$AI" --grub-dir >"$SB_ROOT/bad4.log" 2>&1
ne "缺参数（--grub-dir 没有值）非 0" 0 $?

echo "== 5. --preserve-existing（真机试跑：保留上游 squashfs 项当已知良好项）=="
FIX=$TS_DIR/fixtures/grub.cfg.device-r38135
PROV=$TS_DIR/fixtures/grub.cfg.device-r38135.provenance
PR=$SB_ROOT/preserve
# fixture 已匿名化（两块盘的 PARTUUID 换成 00000000-…-00000000000{1,2}）：
# 这里断言的是**匿名化后的固定 md5**，作用是"谁手改了 fixture 就红"，不再宣称等于设备原文件。
# 设备原文件 md5 只记录在 provenance 里供溯源（不在仓库里存设备标识）。
FIXTURE_MD5=1c52ef71d322462703cee86dd34acd50
[ -s "$FIX" ] && ok "fixture 存在: phase1/tests/fixtures/grub.cfg.device-r38135" || bad "fixture 缺失"
[ -s "$PROV" ] && ok "provenance 存在（来源/版本/时间/md5 记在 fixture 之外）" || bad "provenance 缺失"
contains "provenance 记了原始设备的 md5（供溯源）" "21d1397cca5289a8d30c8efff3c8d909" "$(cat "$PROV" 2>/dev/null)"
contains "provenance 说明 fixture 已匿名化" "匿名" "$(cat "$PROV" 2>/dev/null)"

# fixture 必须是真机原文的逐字节拷贝：摘要对不上就说明它被"美化"过，后面的"逐字保留"就没意义
_fix_md5=$(md5_of "$FIX" 2>/dev/null) || _fix_md5=''
if [ -z "$_fix_md5" ]; then
	printf '  PEND 这台机器上没有 md5sum / md5 / openssl，无法校验 fixture 摘要（不静默跳过）\n'
	printf '       需要的期望值: %s\n' "$FIXTURE_MD5"
	printf 'GRUB-CFG PENDING\n'
	exit 2
fi
eq "fixture 未被手改（匿名化后的固定 md5）" "$FIXTURE_MD5" "$_fix_md5"

sh "$AI" --grub-dir "$PR" --preserve-existing "$FIX" --kernel vmlinuz \
	--initrd initrd.cpio.gz --trial --disk /dev/nvme0n1 >"$SB_ROOT/preserve.log" 2>&1
eq "preserve 渲染退出码 0" 0 $?
PCC=$PR/grub.cfg
if [ -f "$PCC" ]; then
	ok "产出 $PCC"
else
	bad "没有产出 preserve 渲染结果"
	printf '       渲染输出: %s\n' "$(head -4 "$SB_ROOT/preserve.log" | tr '\n' '|')"
fi
PTXT=$(cat "$PCC" 2>/dev/null)

# 5.1 原文件每一非空行都必须逐字出现（与运行期断言同一个判据）
_miss=0
_checked=0
while IFS= read -r _l || [ -n "$_l" ]; do
	case $_l in
	'') continue ;;
	esac
	case $_l in
	*[![:space:]]*) ;;
	*) continue ;;
	esac
	_checked=$((_checked + 1))
	if ! grep -Fqx -e "$_l" "$PCC" 2>/dev/null; then
		bad "保留行缺失: [$_l]"
		_miss=1
	fi
done <"$FIX"
[ "$_miss" = 0 ] && ok "fixture 的 $_checked 个非空行全部逐字保留"

contains "上游项的内核行逐字保留（带 rootwait，保留行不参与硬规则）" \
	'linux /boot/vmlinuz root=PARTUUID=00000000-0000-4000-8000-000000000001 rootwait  console=tty1 console=ttyS0,115200n8 noinitrd' "$PTXT"
contains "failsafe 项的内核行逐字保留" \
	'linux /boot/vmlinuz failsafe=true root=PARTUUID=00000000-0000-4000-8000-000000000001 rootwait  console=tty1 console=ttyS0,115200n8 noinitrd' "$PTXT"
contains "spick 遗留的 TEST 项逐字保留（不改不删）" 'menuentry "TEST btrfs subvol root (initramfs)" {' "$PTXT"
contains "TEST 项内核行逐字保留（rootfstype/rootflags/rdinit 全在）" \
	'linux /boot/vmlinuz root=PARTUUID=00000000-0000-4000-8000-000000000002 rootwait rootfstype=btrfs rootflags=subvol=@root-test rdinit=/init fstools_ignore_partname=1 console=ttyS0,115200n8 console=tty1 panic=10' "$PTXT"
contains "TEST 项 initrd 行逐字保留" 'initrd /boot/test-initrd.cpio.gz' "$PTXT"
contains "search -l kernel -s root 逐字保留" 'search -l kernel -s root' "$PTXT"
contains "serial 设置逐字保留" 'terminal_input console serial; terminal_output console serial' "$PTXT"
contains 'set default="0" 仍在' 'set default="0"' "$PTXT"
contains "set timeout 逐字保留" 'set timeout="0"' "$PTXT"
_fix_men=$(grep -c '^menuentry' "$FIX")
_i=0
while IFS= read -r _m || [ -n "$_m" ]; do
	contains "原 menuentry 逐字保留: $_m" "$_m" "$PTXT"
	_i=$((_i + 1))
done <<EOF
$(grep '^menuentry' "$FIX")
EOF
eq "原 menuentry 条数与 fixture 一致" "$_fix_men" "$_i"
eq "fixture 有 3 条 menuentry（ImmortalWrt / failsafe / TEST）" 3 "$_fix_men"

# 5.2 守卫 + 试跑项
contains "主守卫插在 set default 之后（/boot/try-phase1，序号 = 原 menuentry 条数 = 3）" \
	'if [ -f /boot/try-phase1 ]; then set default=3; fi' "$PTXT"
contains "第二条守卫（兜底 /try-phase1）" \
	'if [ -f /try-phase1 ]; then set default=3; fi' "$PTXT"
eq "主守卫排在兜底之前（与 live /boot 一致的那条优先）" '/boot/try-phase1' \
	"$(printf '%s\n' "$PTXT" | grep 'then set default=3; fi' | head -1 | sed -e 's/^if \[ -f //' -e 's/ \].*//')"
contains "补了 set fallback=0（原文件没有）" 'set fallback=0' "$PTXT"
eq "menuentry 总数 = 原有 + 1" $((_fix_men + 1)) "$(grep -c '^menuentry ' "$PCC" 2>/dev/null)"
_trial_entry=$(awk '/^menuentry .*phase1 trial/{f=1} f{print}' "$PCC" 2>/dev/null)
contains "末尾追加了试跑项" 'phase1 trial' "$_trial_entry"
contains "试跑项带 phase1_dev=" 'phase1_dev=/dev/nvme0n1p2' "$_trial_entry"
contains "试跑项带 phase1_lower=" 'phase1_lower=@root' "$_trial_entry"
contains "试跑项带 phase1_overlay=" 'phase1_overlay=@overlay' "$_trial_entry"
contains "试跑项带 phase1_boot=" 'phase1_boot=/dev/nvme0n1p1' "$_trial_entry"
contains "试跑项带 rdinit=/init" 'rdinit=/init' "$_trial_entry"
contains "试跑项带 fstools_ignore_partname=1" 'fstools_ignore_partname=1' "$_trial_entry"
contains "试跑项带 phase1_bootsub=boot" 'phase1_bootsub=boot' "$_trial_entry"
not_contains "试跑项里没有 rootwait" 'rootwait' "$_trial_entry"
not_contains "试跑项里没有 root=PARTUUID=" 'root=PARTUUID=' "$_trial_entry"
# 守卫必须在第一个 menuentry 之前（否则 default 定了也没意义没关系，但要看得出顺序）
_gd=$(grep -n 'set default=' "$PCC" | head -1 | cut -d: -f1)
_gm=$(grep -n '^menuentry ' "$PCC" | head -1 | cut -d: -f1)
if [ -n "$_gd" ] && [ -n "$_gm" ] && [ "$_gd" -lt "$_gm" ]; then
	ok "守卫在第一个 menuentry 之前"
else
	bad "守卫位置不对（default=$_gd menuentry=${_gm}）"
fi

echo "== 6. preserve 模式：不加 --trial 时是纯保留 =="
PR2=$SB_ROOT/preserve-plain
sh "$AI" --grub-dir "$PR2" --preserve-existing "$FIX" --kernel vmlinuz \
	--initrd initrd.cpio.gz >"$SB_ROOT/preserve-plain.log" 2>&1
eq "退出码 0" 0 $?
P2=$PR2/grub.cfg
eq "与原文件逐字节一致" 0 "$(diff "$FIX" "$P2" 2>/dev/null | wc -l | tr -d ' ')"
not_contains "没有守卫行" 'try-phase1' "$(cat "$P2" 2>/dev/null)"
not_contains "没有试跑项" 'phase1_dev=' "$(cat "$P2" 2>/dev/null)"

echo "== 7. preserve 模式：TRIAL_INDEX 自动算 + 覆盖 + fail-closed =="
mkcfg() { # <路径> <menuentry 条数>
	{
		printf 'set default="0"\nset timeout="0"\nsearch -l kernel -s root\n'
		_n=0
		while [ "$_n" -lt "$2" ]; do
			printf 'menuentry "slot%s" {\n\tlinux /boot/vmlinuz slot=%s\n}\n' "$_n" "$_n"
			_n=$((_n + 1))
		done
	} >"$1"
}
for _want in 0 1 3; do
	mkcfg "$SB_ROOT/cfg-$_want" "$_want"
	sh "$AI" --grub-dir "$SB_ROOT/out-$_want" --preserve-existing "$SB_ROOT/cfg-$_want" \
		--kernel vmlinuz --initrd i.cpio.gz --trial --disk /dev/nvme0n1 \
		>"$SB_ROOT/out-$_want.log" 2>&1
	eq "N=$_want 时渲染成功" 0 $?
	contains "N=$_want ⇒ 试跑项序号 $_want" \
		"if [ -f /try-phase1 ]; then set default=$_want; fi" "$(cat "$SB_ROOT/out-$_want/grub.cfg" 2>/dev/null)"
done

sh "$AI" --grub-dir "$SB_ROOT/out-override" --preserve-existing "$FIX" \
	--kernel vmlinuz --initrd i.cpio.gz --trial --disk /dev/nvme0n1 --trial-index 7 \
	>"$SB_ROOT/out-override.log" 2>&1
eq "--trial-index 覆盖后渲染成功" 0 $?
contains "--trial-index 7 生效" "if [ -f /try-phase1 ]; then set default=7; fi" \
	"$(cat "$SB_ROOT/out-override/grub.cfg" 2>/dev/null)"

sh "$AI" --grub-dir "$SB_ROOT/out-bad" --preserve-existing "$FIX" \
	--kernel vmlinuz --initrd i.cpio.gz --trial --disk /dev/nvme0n1 \
	--cmdline 'fstools_ignore_partname=1 panic=10 rootwait' >"$SB_ROOT/out-bad.log" 2>&1
ne "试跑项带 rootwait ⇒ 非 0（保留行不参与，我们生成的项必须合规）" 0 $?
[ -f "$SB_ROOT/out-bad/grub.cfg" ] && bad "被拒时不该留下 grub.cfg" || ok "被拒时没有留下 grub.cfg"

sh "$AI" --grub-dir "$SB_ROOT/out-bad2" --preserve-existing "$FIX" \
	--kernel vmlinuz --initrd i.cpio.gz --trial --disk /dev/nvme0n1 \
	--cmdline 'root=PARTUUID=deadbeef fstools_ignore_partname=1 panic=10' >"$SB_ROOT/out-bad2.log" 2>&1
ne "试跑项带 root=PARTUUID= ⇒ 非 0" 0 $?

sh "$AI" --preserve-existing "$FIX" >"$SB_ROOT/out-alone.log" 2>&1
ne "--preserve-existing 不配 --grub-dir ⇒ 非 0" 0 $?
contains "提示要与 --grub-dir 一起用" '--grub-dir' "$(cat "$SB_ROOT/out-alone.log")"

sh "$AI" --grub-dir "$SB_ROOT/x" --preserve-existing "$FIX" --dry-run \
	--rootfs r.tar.gz --disk /dev/nvme0n1 >"$SB_ROOT/out-mutex.log" 2>&1
ne "--preserve-existing 与 --dry-run 互斥 ⇒ 非 0" 0 $?

sh "$AI" --grub-dir "$SB_ROOT/y" --preserve-existing "$SB_ROOT/does-not-exist" \
	--kernel vmlinuz --initrd i.cpio.gz --trial --disk /dev/nvme0n1 >"$SB_ROOT/out-nofile.log" 2>&1
ne "保留文件不存在 ⇒ 非 0" 0 $?

contains "源码里有运行期断言（保留行逐字出现）" 'assert_preserved_lines' "$(cat "$AI")"
contains "源码注释里写清：保留行不参与硬规则" '保留行不参与校验' "$(cat "$AI")"

echo "== 8. --boot-subdir ''（内核在引导分区根）与 phase1_bootsub 校验 =="
sh "$AI" --grub-dir "$SB_ROOT/nosub" --kernel vmlinuz --initrd i.cpio.gz \
	--trial --disk /dev/nvme0n1 --boot-subdir '' >"$SB_ROOT/nosub.log" 2>&1
eq "渲染退出码 0" 0 $?
NSTXT=$(cat "$SB_ROOT/nosub/grub.cfg" 2>/dev/null)
contains "内核路径落到分区根 /vmlinuz" 'linux /vmlinuz ' "$NSTXT"
contains "initrd 路径落到分区根 /i.cpio.gz" 'initrd /i.cpio.gz' "$NSTXT"
contains "phase1_bootsub 为空（= --boot-subdir ''）" 'phase1_bootsub= ' "$NSTXT"
eq "主/兜底路径相同时只出一条守卫" 1 "$(printf '%s\n' "$NSTXT" | grep -c 'try-phase1 \]; then')"

# 试跑项被塞进一个冲突的 phase1_bootsub ⇒ fail-closed
sh "$AI" --grub-dir "$SB_ROOT/badsub" --kernel vmlinuz --initrd i.cpio.gz \
	--trial --disk /dev/nvme0n1 \
	--cmdline 'fstools_ignore_partname=1 panic=10 phase1_bootsub=efi' >"$SB_ROOT/badsub.log" 2>&1
ne "phase1_bootsub 与 --boot-subdir 冲突 ⇒ 非 0" 0 $?
contains "拒绝理由点名 phase1_bootsub" 'phase1_bootsub' "$(cat "$SB_ROOT/badsub.log")"
[ -f "$SB_ROOT/badsub/grub.cfg" ] && bad "被拒时不该留下 grub.cfg" || ok "被拒时没有留下 grub.cfg"

finish GRUB-CFG
