#!/bin/sh
# ac-6：phase1/assemble-image.sh 的 --dry-run 行为与静态安全约束。
#
# 断言：
#   * --dry-run 退出 0，输出含四个子卷、p1/p128 尺寸、manifest、@root 只读、grub、cmdline；
#   * --dry-run 输出里没有 rootwait，且真的没写任何文件；
#   * 缺参数 / 参数非法 / 互斥开关 → 非 0 且给可执行提示；
#   * 源码静态检查：无递归强制删除、无通配删除、有手工 yes 确认点、
#     破坏性命令只出现在 destructive_install() 里、解包排除挂载点、
#     无 GNU 专属选项与 bashism、$VAR 紧邻非 ASCII 时写成 ${VAR}。
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

AI=$REPO/phase1/assemble-image.sh

SB_ROOT=$(mktemp -d /tmp/phase1-dry.XXXXXX 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 1
}

echo "== 1. --dry-run 打印完整计划 =="
OUT=$SB_ROOT/plan.txt
sh "$AI" --dry-run --rootfs phase1-rootfs.tar.gz --kernel vmlinuz \
	--initrd initrd.cpio.gz --disk /dev/nvme9n1 >"$OUT" 2>&1
eq "退出码 0" 0 $?
PLAN=$(cat "$OUT")
contains "四个子卷之一 @root" '@root' "$PLAN"
contains "四个子卷之一 @overlay" '@overlay' "$PLAN"
contains "四个子卷之一 @docker" '@docker' "$PLAN"
contains "四个子卷之一 @swap" '@swap' "$PLAN"
contains "p1 尺寸 256M" '256M' "$PLAN"
contains "p128 尺寸 4M" '4M' "$PLAN"
contains "p128 是 EF02" 'EF02' "$PLAN"
contains "单块 btrfs 分区 p2" 'phase1-root' "$PLAN"
contains "manifest 计划" '/.ab-base-manifest' "$PLAN"
contains "@root 运行期只读 ro" '运行期只读 ro' "$PLAN"
contains "解包排除挂载点" '排除  : /proc /sys /dev /tmp /run /boot /rom /overlay /opt/docker /swap /data' "$PLAN"
contains "grub 安装步骤" 'grub-install --target=i386-pc' "$PLAN"
contains "cmdline 带 fstools_ignore_partname=1" 'fstools_ignore_partname=1' "$PLAN"
contains "cmdline 带 panic=10" 'panic=10' "$PLAN"
contains "试跑标记路径" '/boot/try-phase1' "$PLAN"
contains "明确声明没写盘" '没有对任何设备执行写操作' "$PLAN"
not_contains "计划里没有 rootwait" 'rootwait' "$PLAN"
not_contains "计划里没有 root=PARTUUID=" 'root=PARTUUID=' "$PLAN"

echo "== 2. --dry-run 不落任何文件 =="
mkdir -p "$SB_ROOT/empty"
_before=$(ls -A "$SB_ROOT/empty" | tr '\n' ' ')
(
	cd "$SB_ROOT/empty" && sh "$AI" --dry-run --rootfs r.tar.gz --disk /dev/nvme9n1 >/dev/null 2>&1
)
_after=$(ls -A "$SB_ROOT/empty" | tr '\n' ' ')
eq "工作目录没有被写入" "$_before" "$_after"
[ -e /mnt/phase1-boot ] && bad "dry-run 竟然创建了 /mnt/phase1-boot" || ok "没有创建装机挂载点"

echo "== 3. --dry-run --trial 打印试跑项 =="
sh "$AI" --dry-run --rootfs r.tar.gz --kernel vmlinuz --initrd i.cpio.gz \
	--disk /dev/nvme9n1 --trial >"$SB_ROOT/plan-trial.txt" 2>&1
eq "退出码 0" 0 $?
TRIALPLAN=$(cat "$SB_ROOT/plan-trial.txt")
contains "试跑项带 phase1_dev=" 'phase1_dev=/dev/nvme9n1p2' "$TRIALPLAN"
contains "试跑项带 phase1_lower=" 'phase1_lower=@root' "$TRIALPLAN"
contains "试跑项带 rdinit=/init" 'rdinit=/init' "$TRIALPLAN"
contains "试跑项带 phase1_bootsub=boot" 'phase1_bootsub=boot' "$TRIALPLAN"

echo "== 4. 缺参数/非法参数必须非 0 且给提示 =="
sh "$AI" >"$SB_ROOT/noargs.log" 2>&1
ne "一个参数都不给 → 非 0" 0 $?
contains "给出用法提示" '用法: sh phase1/assemble-image.sh --help' "$(cat "$SB_ROOT/noargs.log")"

sh "$AI" --dry-run --rootfs r.tar.gz >"$SB_ROOT/nodisk.log" 2>&1
ne "--dry-run 缺 --disk → 非 0" 0 $?
contains "提示要写清目标盘" '--disk' "$(cat "$SB_ROOT/nodisk.log")"

sh "$AI" --dry-run --rootfs r.tar.gz --disk nvme9n1 >"$SB_ROOT/baddisk.log" 2>&1
ne "--disk 不是 /dev/ 下设备 → 非 0" 0 $?

sh "$AI" --grub-dir "$SB_ROOT/x" --dry-run --rootfs r.tar.gz --disk /dev/nvme9n1 >"$SB_ROOT/mutex.log" 2>&1
ne "--grub-dir 与 --dry-run 互斥 → 非 0" 0 $?

sh "$AI" --nope >"$SB_ROOT/unknown.log" 2>&1
ne "未知参数 → 非 0" 0 $?

sh "$AI" --help >"$SB_ROOT/help.log" 2>&1
eq "--help 退出 0" 0 $?
contains "--help 讲了 --dry-run" '--dry-run' "$(cat "$SB_ROOT/help.log")"
contains "--help 讲了 --grub-dir" '--grub-dir' "$(cat "$SB_ROOT/help.log")"

echo "== 5. 源码静态约束 =="
SRC=$(cat "$AI")

sh -n "$AI" && ok "sh -n 通过" || bad "sh -n 失败"

# 5.1 不许递归强制删除 / 通配删除
if grep -n 'rm -rf' "$AI" >"$SB_ROOT/rmrf.log" 2>/dev/null; then
	bad "源码出现 rm -rf"
	sed 's/^/       /' "$SB_ROOT/rmrf.log"
else
	ok "没有 rm -rf"
fi
if grep -nE '(^|[^[:alnum:]_])rm[[:space:]]+-[a-zA-Z]*r' "$AI" >"$SB_ROOT/rmr.log" 2>/dev/null; then
	bad "源码出现 rm -r（递归删除）"
	sed 's/^/       /' "$SB_ROOT/rmr.log"
else
	ok "没有 rm -r"
fi
if grep -nE '(^|[^[:alnum:]_])rm[[:space:]][^|;&]*\*' "$AI" >"$SB_ROOT/rmglob.log" 2>/dev/null; then
	bad "源码出现通配删除（rm 带 *）"
	sed 's/^/       /' "$SB_ROOT/rmglob.log"
else
	ok "没有通配删除"
fi

# 5.2 必须有手工 yes 确认点（默认拒绝）
contains "有 yes 确认比较" '[ "$_ans" = "yes" ]' "$SRC"
contains "确认前提醒数据会丢" '原有数据全部丢失' "$SRC"
if printf '%s\n' "$SRC" | grep -qE '^[[:space:]]*yes[[:space:]]*\|'; then
	bad "存在 yes | 自动确认管道"
else
	ok "没有 yes | 自动确认"
fi

# 5.3 破坏性动作只在 destructive_install() 里
DESTRUCTIVE='^[[:space:]]*(sgdisk[[:space:]]+--(zap-all|set-alignment)|mkfs\.vfat|mkfs\.btrfs|btrfs[[:space:]]+subvolume[[:space:]]+create)'
# 两个已声明的破坏性入口：destructive_install()（整盘，需手工 yes）与 image_write()（镜像文件，无需 yes）。
# 除这两处之外出现 sgdisk/mkfs 一律算越界。
_total=$(grep -cE "$DESTRUCTIVE" "$AI")
_body=$(awk '/^destructive_install\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$AI")
_ibody=$(awk '/^image_write\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$AI")
_in_body=$(printf '%s\n%s\n' "$_body" "$_ibody" | grep -cE "$DESTRUCTIVE")
if [ "$_total" -ge 4 ] && [ "$_total" = "$_in_body" ]; then
	ok "破坏性命令全部在两个已声明入口里（disk+image $_in_body/$_total 条）"
else
	bad "破坏性命令跑出了已声明入口（body=$_in_body/总=${_total}）"
	printf '%s\n%s\n' "$_body" "$_ibody" | grep -nE "$DESTRUCTIVE" | sed 's/^/       body: /'
	grep -nE "$DESTRUCTIVE" "$AI" | sed 's/^/       all : /'
fi
contains "破坏性函数存在" 'destructive_install() {' "$SRC"
contains "镜像模式的破坏性入口存在" 'image_write() {' "$SRC"
# 镜像模式不需要手工 yes，但必须"先校验再写"：入口里 image_validate 必须在 image_write 之前
_vn=$(grep -nE '^[[:space:]]*image_validate$' "$AI" | head -1 | cut -d: -f1)
_wn=$(grep -n '^[[:space:]]*image_write$' "$AI" | head -1 | cut -d: -f1)
if [ -n "$_vn" ] && [ -n "$_wn" ] && [ "$_vn" -lt "$_wn" ]; then
	ok "镜像模式先 image_validate 再 image_write（第 $_vn / $_wn 行）"
else
	bad "镜像模式缺少 image_validate -> image_write 的顺序保障（validate=${_vn:-?} write=${_wn:-?}）"
fi

# 5.4 解包必须排除挂载点（decisions §O.2）
for _ex in ./proc ./sys ./dev ./tmp ./boot ./rom ./overlay ./opt/docker ./swap ./data; do
	contains "解包排除 --exclude=$_ex" "--exclude=$_ex" "$SRC"
done

# 5.5 分层校验三步都在
contains "分层校验用 sgdisk -p" 'sgdisk -p "$DISK"' "$SRC"
contains "分层校验用 blkid UUID" 'blkid -s UUID -o value' "$SRC"
contains "分层校验用 btrfs subvolume list" 'btrfs subvolume list' "$SRC"
contains "写 /.ab-base-manifest" '.ab-base-manifest' "$SRC"
contains "manifest 只收指定目录" 'etc usr lib sbin bin www' "$SRC"

# 5.6 不用 GNU 专属选项
for _g in 'sed -i' 'readlink -f' 'stat -c' 'dd status=' 'grep -P' 'find .*-printf'; do
	if grep -q -- "$_g" "$AI" 2>/dev/null; then
		bad "源码出现 GNU 专属选项: $_g"
	else
		ok "没有 GNU 专属选项: $_g"
	fi
done

# 5.7 无 bashism（macOS sh = bash 3.2 / busybox ash 都要能跑）
_code=$(printf '%s\n' "$SRC" | grep -vE '^[[:space:]]*#')
_no_bashism() { # <描述> <ERE>
	if printf '%s\n' "$_code" | grep -qE "$2"; then
		bad "源码出现非 POSIX 写法: $1"
		printf '%s\n' "$_code" | grep -nE "$2" | head -3 | sed 's/^/       /'
	else
		ok "没有非 POSIX 写法: $1"
	fi
}
_no_bashism 'bash [[ ... ]] 条件' '(^|[^[:alnum:]_])\[\[[[:space:]]'
_no_bashism 'function 关键字' '(^|[^[:alnum:]_])function[[:space:]]'
_no_bashism 'pipefail' 'set[[:space:]]+-o[[:space:]]+pipefail'
_no_bashism 'here-string <<<' '<<<'
_no_bashism '正则 =~' '=~'
_no_bashism 'source 内建' '(^|[^[:alnum:]_])source[[:space:]]'
_no_bashism 'declare/typeset' '(^|[^[:alnum:]_])(declare|typeset)[[:space:]]'
_no_bashism '算术 (( ))' '(^|[^[:alnum:]_$])\(\([[:space:]]*[A-Za-z_$]'

# 5.8 $VAR 紧邻非 ASCII 时必须写 ${VAR}（macOS bash 3.2 会吞掉变量名）
_bad_lines=$(perl -ne '
	next if /^\s*#/;
	print "$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]/;
' "$AI" 2>/dev/null)
if [ -z "$_bad_lines" ]; then
	ok '没有 $VAR 紧邻非 ASCII 的写法'
else
	bad '$VAR 紧邻非 ASCII（应写 ${VAR}）'
	printf '%s\n' "$_bad_lines" | sed 's/^/       /'
fi

echo "== 6. H3：装机几何（btrfs 标签 / @data）与 rootfs 基线拦截 =="
contains "dry-run 打印 --btrfs-label 的值" 'btrfs 标签    : phase1（--btrfs-label' "$PLAN"
not_contains "默认不建 @data（子卷段里没有 @data 行）" '  @data     → /data' "$PLAN"
contains "默认 @data 的从缺有说明" '（@data 不建' "$PLAN"

# 造两份假 rootfs：HEAD 时代（有 btrfs-subvols）与干净
mkdir -p "$SB_ROOT/fake-legacy/etc/init.d" "$SB_ROOT/fake-legacy/etc/config" "$SB_ROOT/fake-clean/etc"
printf '#!/bin/sh\n' >"$SB_ROOT/fake-legacy/etc/init.d/btrfs-subvols"
printf "config 'mount'\n\toption target '/overlay'\n" >"$SB_ROOT/fake-legacy/etc/config/fstab"
printf 'DISTRIB_ID="ImmortalWrt"\n' >"$SB_ROOT/fake-clean/etc/openwrt_release"
( cd "$SB_ROOT/fake-legacy" && tar -cf "$SB_ROOT/fake-legacy.tar" . )
( cd "$SB_ROOT/fake-clean" && tar -cf "$SB_ROOT/fake-clean.tar" . )

sh "$AI" --dry-run --rootfs "$SB_ROOT/fake-legacy.tar" --kernel vmlinuz \
	--initrd i.cpio.gz --disk /dev/nvme9n1 >"$SB_ROOT/legacy.log" 2>&1
ne "HEAD 时代 rootfs 默认硬失败（非 0）" 0 $?
contains "失败提示点名 fe53232 基线" 'fe53232' "$(cat "$SB_ROOT/legacy.log")"
contains "失败提示给出 --allow-legacy-rootfs 出路" '--allow-legacy-rootfs' "$(cat "$SB_ROOT/legacy.log")"
contains "失败提示同时给 --btrfs-label wrt-overlay" '--btrfs-label wrt-overlay' "$(cat "$SB_ROOT/legacy.log")"
contains "失败提示同时给 --with-data-subvol" '--with-data-subvol' "$(cat "$SB_ROOT/legacy.log")"

sh "$AI" --dry-run --rootfs "$SB_ROOT/fake-legacy" --kernel vmlinuz \
	--initrd i.cpio.gz --disk /dev/nvme9n1 >"$SB_ROOT/legacy-dir.log" 2>&1
ne "目录源同样被拦（非 0）" 0 $?

sh "$AI" --dry-run --rootfs "$SB_ROOT/fake-legacy.tar" --kernel vmlinuz --initrd i.cpio.gz \
	--disk /dev/nvme9n1 --allow-legacy-rootfs --btrfs-label wrt-overlay --with-data-subvol \
	>"$SB_ROOT/legacy-allow.log" 2>&1
eq "显式放行 + 对齐几何后能过（退出 0）" 0 $?
ALLOWPLAN=$(cat "$SB_ROOT/legacy-allow.log")
contains "放行后打印 --btrfs-label wrt-overlay" 'wrt-overlay' "$ALLOWPLAN"
contains "放行后子卷清单含 @data" '@data' "$ALLOWPLAN"
contains "放行时明确告警" '已用 --allow-legacy-rootfs 放行' "$ALLOWPLAN"

sh "$AI" --dry-run --rootfs "$SB_ROOT/fake-clean.tar" --kernel vmlinuz \
	--initrd i.cpio.gz --disk /dev/nvme9n1 >"$SB_ROOT/clean.log" 2>&1
eq "干净 rootfs 通过基线检查" 0 $?

echo "== 7. M2/M3：解包不吞退出码 + 目标盘占用硬失败 =="
contains "解包改成两段式（有临时 tar）" '.phase1-stage.tar' "$SRC"
if printf '%s\n' "$SRC" | grep -qE 'tar -cf - .*\| *tar -x'; then
	bad "还有 tar -c | tar -x 管道（源侧 rc 会被吞）"
else
	ok "没有 tar -c | tar -x 管道"
fi
contains "manifest 条目过少直接 fail（不再只 warn）" 'manifest 只有 $_n 条（<1000），基座疑似半残' "$SRC"
contains "有目标盘占用检查函数" 'assert_target_not_in_use() {' "$SRC"
contains "检查 /proc/mounts" '$1 ~ re { print "  " $1 " 已挂载在 " $2 }' "$SRC"
contains "检查 /proc/cmdline" '/proc/cmdline 里出现' "$SRC"
contains "检查 swapon -s" 'swap 在用: ' "$SRC"
_di=$(awk '/^destructive_install\(\) \{/{f=1; n=0} f{n++} f && /assert_target_not_in_use/{print n; exit}' "$AI")
if [ -n "$_di" ] && [ "$_di" -le 8 ]; then
	ok "destructive_install() 开头就检查目标盘占用（第 $_di 行）"
else
	bad "destructive_install() 里没有尽早检查目标盘占用（第 ${_di:-?} 行）"
fi
contains "preflight 也先查目标盘占用" '分层校验 0/3：目标盘是否正在被使用' "$SRC"

finish ASSEMBLE-DRY-RUN
