#!/bin/sh
# ac-1 / ac-2：files/lib/preinit/80_mount_root
#   根已经是我们 initramfs 合成的 overlay（`/` 行是 overlay 且 lowerdir=/lower +
#   upperdir=/overlay/upper）时**不注册** fstools 的 do_mount_root —— 否则 ramoverlay()
#   会拿 tmpfs 顶掉写层，写入重启即失；其余情况与上游逐字等价（注册 → mount_root start +
#   boot_run_hook preinit_mount_root + sysupgrade 配置恢复），上游 $INITRAMFS 守卫原样保留。
#
# 两条主线：
#   1. 上游等价性：与 shell/tests/fixtures/preinit/80_mount_root.r38135（真机 /rom 原文）做
#      diff，**唯一允许的删除行**就是被替换的那行守卫；上游关键行逐条 grep -F 复核。
#   2. 行为：迷你 /etc/preinit 里 source 被测文件，再 boot_run_hook preinit_main 按注册顺序
#      执行钩子。全程离线：PROC_MOUNTS / PREINIT_KMSG / STUB_CMDLINE 注入，mount_root、
#      logger、cat、sleep、reboot、mount 全是沙盒桩，不碰真 /proc、不碰真 /dev/kmsg。
set -u
. "$(dirname "$0")/lib-assert.sh"

TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
SRC=$REPO/files/lib/preinit/80_mount_root
FIXTURE=$REPO/shell/tests/fixtures/preinit/80_mount_root.r38135

# 上游 do_mount_root 里有一段 sysupgrade 配置恢复：只要宿主上存在 /sysupgrade.tgz 或
# /tmp/sysupgrade.tar，它就会 cp /etc/{passwd,group,shadow} 到 /tmp、cd / 并解包。
# 用例必须先确认这两个路径不存在，否则宁可不跑（PEND）也绝不拿宿主 /etc 冒险。
if [ -e /sysupgrade.tgz ] || [ -e /tmp/sysupgrade.tar ]; then
	printf 'PEND: 宿主存在 /sysupgrade.tgz 或 /tmp/sysupgrade.tar；上游配置恢复分支会被触发，拒绝在宿主上执行\n'
	exit 2
fi

SB_ROOT=$(mktemp -d "/tmp/sb-mount-root.XXXXXX" 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 2
}

# 基准文件必须逐字节等于真机原文：md5 是唯一能抓住"往 fixture 里加注释 / 改行尾"的断言。
# macOS 只有 `md5 -q`、busybox/Linux 只有 `md5sum`，两路都兼容；两个都没有就 PEND 并说清原因，
# 绝不静默跳过（否则基准悄悄漂移没人发现）。
fixture_md5() { # <文件>
	if command -v md5sum >/dev/null 2>&1; then
		md5sum "$1" 2>/dev/null | awk '{print $1}'
	elif command -v md5 >/dev/null 2>&1; then
		md5 -q "$1" 2>/dev/null
	fi
}
if [ -z "$(fixture_md5 /dev/null 2>/dev/null)" ]; then
	printf 'PEND: 宿主既没有 md5sum 也没有 md5，无法校验上游基准（80_mount_root.r38135）的逐字节一致性\n'
	exit 2
fi
FIXTURE_MD5_EXPECT=0f35638fbf8b1a18163be5d07e062f73

echo "== 静态结构：上游等价性（与真机 /rom 原文逐行比） =="
if [ -f "$SRC" ]; then
	ok "存在 $SRC"
else
	bad "缺少 files/lib/preinit/80_mount_root"
fi
if [ -f "$FIXTURE" ]; then
	ok "存在上游基准 $(basename "$FIXTURE")"
else
	bad "缺少 shell/tests/fixtures/preinit/80_mount_root.r38135"
fi
eq "上游基准逐字节等于真机原文（md5）" "$FIXTURE_MD5_EXPECT" "$(fixture_md5 "$FIXTURE")"
PROVENANCE=$FIXTURE.provenance
if [ -f "$PROVENANCE" ]; then
	ok "出处信息在旁文件 $(basename "$PROVENANCE")（基准文件本身不许夹带元信息）"
	PROV=$(cat "$PROVENANCE" 2>/dev/null)
	contains "出处写明真机路径" '/rom/lib/preinit/80_mount_root' "$PROV"
	contains "出处写明版本 ImmortalWrt 25.12.2 r38135" 'ImmortalWrt 25.12.2 r38135' "$PROV"
	contains "出处写明取回日期 2026-11-06" '2026-11-06' "$PROV"
	contains "出处写明 md5（与硬断言同一个值）" "$FIXTURE_MD5_EXPECT" "$PROV"
	contains "出处提醒上游没有 shebang（别顺手补）" '没有 shebang' "$PROV"
	contains "出处提醒不要补 shebang" '不要顺手补 `#!/bin/sh`' "$PROV"
else
	bad "缺少 ${PROVENANCE}（出处信息必须单独存放，不能写进基准文件）"
fi
not_contains "基准文件里没有夹带自述注释头" 'BEGIN UPSTREAM' "$(cat "$FIXTURE" 2>/dev/null)"
not_contains "基准文件没有被补 shebang（上游原文本来就没有）" '#!/bin/sh' "$(cat "$FIXTURE" 2>/dev/null)"
TEXT=$(cat "$SRC" 2>/dev/null)
if [ -n "$TEXT" ]; then ok "非空（$(printf '%s' "$TEXT" | wc -l | tr -d ' ') 行）"; else bad "文件为空或不存在"; fi
if sh -n "$SRC" 2>/dev/null; then ok "语法正确（sh -n）"; else bad "sh -n 报语法错误"; fi

# fixture 本身就是上游原文（无注释头），直接当基准用
UPSTREAM=$FIXTURE
eq "基准行数（r38135 = 54 行）" '54' "$(wc -l <"$UPSTREAM" 2>/dev/null | tr -d ' ')"

GUARD_LINE='[ "$INITRAMFS" = "1" ] || boot_hook_add preinit_main do_mount_root'
REMOVED=$(diff -u "$UPSTREAM" "$SRC" 2>/dev/null | grep '^-' | grep -v '^---' | sed 's/^-//')
eq "相对上游只有一行被替换（就是被改成条件块的那行守卫）" "$GUARD_LINE" "$REMOVED"
ADDED_N=$(diff -u "$UPSTREAM" "$SRC" 2>/dev/null | grep -c '^+[^+]' | tr -d ' ')
if [ "${ADDED_N:-0}" -gt 0 ]; then
	ok "新增 $ADDED_N 行（全部是文件头注释 / 三个辅助函数 / 守卫块）"
else
	bad "diff 里没有新行：辅助函数或守卫块丢了"
fi
# 上游关键行逐条复核：宁严勿松，丢一行就算 FAIL
for _l in \
	'# Copyright (C) 2006 OpenWrt.org' \
	'# Copyright (C) 2010 Vertical Communications' \
	'missing_lines() {' \
	'	local file1 file2 line' \
	'	grep -q "^$1:" "$file2" || echo "$line"' \
	'	done < "$file1"' \
	'# Rootfs mount options can be passed by declaring in the kernel' \
	'# rootfs_mount_options.compress_algorithm=zstd rootfs_mount_options.noinline_data' \
	'compose_rootfs_mount_options() {' \
	'	for cmdlinevar in $(cat /proc/cmdline); do' \
	'		if [ "$cmdlinevar" != "${cmdlinevar#rootfs_mount_options\.}" ]; then' \
	'			append mount_options "${cmdlinevar#rootfs_mount_options\.}"' \
	'	echo $mount_options' \
	'do_mount_root() {' \
	'	mount_root start "$(compose_rootfs_mount_options)"' \
	'	boot_run_hook preinit_mount_root' \
	'	[ -f /sysupgrade.tgz -o -f /tmp/sysupgrade.tar ] && {' \
	'		echo "- config restore -"' \
	'		cp /etc/passwd /etc/group /etc/shadow /tmp' \
	'		missing_lines /tmp/shadow /etc/shadow >> /etc/shadow' \
	'		rm /tmp/passwd /tmp/group /tmp/shadow' \
	'		# Prevent configuration corruption on a power loss' \
	'		sync'; do
	case "$TEXT" in
	*"$_l"*) ok "上游行仍在：$(printf '%s' "$_l" | sed 's/^\t//' | cut -c1-58)" ;;
	*) bad "上游行丢了：[$_l]" ;;
	esac
done
eq "守卫仍以上游那行开头（\$INITRAMFS = 1 时不注册）" '1' \
	"$(printf '%s\n' "$TEXT" | grep -cxF '[ "$INITRAMFS" = "1" ] || {' | tr -d ' ')"
not_contains "没有引入 FAILSAFE（这台上游用的是 \${INITRAMFS}，不是 \${FAILSAFE}）" 'FAILSAFE' "$TEXT"
eq "没有额外 source 任何库（/etc/preinit 已经 source 过，重复 source 会改行为面）" '' \
	"$(printf '%s\n' "$TEXT" | grep -E '^[[:space:]]*\. ' | tr -d '\t' | tr '\n' ' ' | sed 's/ $//')"
for _f in preinit_mount_root_log preinit_mount_root_line_is_ours preinit_mount_root_is_ours; do
	contains "辅助函数存在：$_f" "$_f() {" "$TEXT"
done
contains "判定要求 lowerdir=/lower（真机 extroot 的 / 行是 lowerdir=/，不能光看 upperdir）" 'lowerdir=/lower' "$TEXT"
contains "判定要求 upperdir=/overlay/upper" 'upperdir=/overlay/upper' "$TEXT"
contains "判定路径可注入（PROC_MOUNTS）" 'PROC_MOUNTS' "$TEXT"
contains "日志路径可注入（PREINIT_KMSG）" 'PREINIT_KMSG' "$TEXT"
eq "没有直接读写 /overlay/upper 的语句（只用 upperdir= 选项串判定）" '' \
	"$(printf '%s\n' "$TEXT" | awk 'index($0,"/overlay/upper") && $0 !~ /^[[:space:]]*#/ && index($0,"upperdir=/overlay/upper")==0 { print NR": "$0 }')"
eq "被 source 后不留副作用（无 sleep/reboot/exit 命令）" '' \
	"$(printf '%s\n' "$TEXT" | grep -E '^[[:space:]]*(sleep|reboot|exit)[[:space:]]' | tr -d '\t' | tr '\n' ' ' | sed 's/ $//')"
eq "source 期不做挂载（没有 mount(8) 调用行）" '' \
	"$(printf '%s\n' "$TEXT" | grep -E '^[[:space:]]*mount[[:space:]]' | tr -d '\t' | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------------------
# 迷你 preinit 世界
#   <case>/lib/functions.sh             /lib/functions.sh 替身（只装 append）
#   <case>/lib/functions/preinit.sh     boot_hook_add / boot_run_hook（分节、按注册顺序执行）
#   <case>/bin/{mount_root,logger,cat,sleep,reboot,mount}  桩
#   <case>/proc/mounts                  伪 /proc/mounts（用例自己写）
#   <case>/preinit/80_mount_root        被测文件（原样拷贝，没有任何路径改写）
#   <case>/trace.log                    唯一执行轨迹
# ---------------------------------------------------------------------------

write_world() { # <case 名>
	CASE=$SB_ROOT/$1
	TRACE=$CASE/trace.log
	KMSG=$CASE/kmsg
	LOGGERLOG=$CASE/logger.log
	MOUNTS=$CASE/proc/mounts
	mkdir -p "$CASE/bin" "$CASE/preinit" "$CASE/lib/functions" "$CASE/proc"
	: >"$TRACE"
	: >"$KMSG"
	: >"$LOGGERLOG"
	: >"$MOUNTS"

	# /lib/functions.sh 替身：compose_rootfs_mount_options 只用到 append（上游是空格分隔的累加）
	cat >"$CASE/lib/functions.sh" <<'EOS'
#!/bin/sh
append() {
	local _a_var=$1 _a_val=$2 _a_old
	eval "_a_old=\${$_a_var:-}"
	if [ -n "$_a_old" ]; then
		eval "$_a_var=\"\$_a_old \$_a_val\""
	else
		eval "$_a_var=\"\$_a_val\""
	fi
}
EOS

	# /lib/functions/preinit.sh 替身：boot_hook_add 追加到分节列表，boot_run_hook 按注册顺序执行
	cat >"$CASE/lib/functions/preinit.sh" <<'EOS'
#!/bin/sh
boot_hooks_preinit_main=
boot_hooks_preinit_mount_root=
boot_hook_add() {
	_bh_sec=$1
	eval "boot_hooks_$_bh_sec=\"\${boot_hooks_$_bh_sec} \${2}\""
	printf 'add_hook %s %s\n' "$1" "$2" >>"$TRACE"
}
boot_run_hook() {
	_bh_sec=$1
	shift
	printf 'run_hook %s\n' "$_bh_sec" >>"$TRACE"
	eval "set -- \${boot_hooks_$_bh_sec}"
	while [ $# -gt 0 ]; do
		"$1"
		printf 'hook_rc %s %s\n' "$1" "$?" >>"$TRACE"
		shift
	done
}
EOS

	# 真 mount_root 是 fstools 的二进制；桩只记 argc 与每个参数，绝不真挂东西
	cat >"$CASE/bin/mount_root" <<'EOS'
#!/bin/sh
{
	printf 'mount_root:argc=%s' "$#"
	for _a in "$@"; do printf ' [%s]' "$_a"; done
	printf '\n'
} >>"$TRACE"
exit "${STUB_MOUNT_ROOT_RC:-0}"
EOS
	cat >"$CASE/bin/logger" <<'EOS'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$STUB_LOGGER_LOG"
exit "${STUB_LOGGER_RC:-0}"
EOS
	# 上游 compose_rootfs_mount_options 硬编码读 /proc/cmdline；沙盒不能真读，
	# 故只对这一个路径返回 STUB_CMDLINE，其余参数原样交给真 cat。
	cat >"$CASE/bin/cat" <<'EOS'
#!/bin/sh
case "${1:-}" in
/proc/cmdline)
	printf '%s\n' "${STUB_CMDLINE:-}"
	exit 0
	;;
esac
exec /bin/cat "$@"
EOS
	# 危险命令桩：真被调用就在 trace 里留 called 行（用来断言"没被调用"）
	for _d in sleep reboot mount; do
		{
			printf '#!/bin/sh\n'
			printf 'printf "called %s %%s\\n" "$*" >>"$TRACE"\n' "$_d"
			printf 'exit 0\n'
		} >"$CASE/bin/$_d"
	done
	chmod +x "$CASE/bin/mount_root" "$CASE/bin/logger" "$CASE/bin/cat" \
		"$CASE/bin/sleep" "$CASE/bin/reboot" "$CASE/bin/mount"

	# 被测文件原样落位（它不 source 任何库，无需改写路径）
	cp "$SRC" "$CASE/preinit/80_mount_root" 2>/dev/null

	cat >"$CASE/harness.sh" <<'EOS'
#!/bin/sh
# 迷你 /etc/preinit：上游先 source /lib/functions.sh 与 /lib/functions/preinit.sh，
# 再按字典序 source /lib/preinit/*，最后 boot_run_hook preinit_main。这里只有一个被测文件。
set -u
# 上游 80_mount_root 直接读 $INITRAMFS，set -u 下必须给默认值
INITRAMFS=${INITRAMFS:-}
. "$LIBDIR/functions.sh"
. "$LIBDIR/functions/preinit.sh"
. "$PREINIT_DIR/80_mount_root"
printf 'sourced 80_mount_root\n' >>"$TRACE"
boot_run_hook preinit_main
printf 'preinit_done\n' >>"$TRACE"
EOS
}

run_world() { # [额外 env 赋值...]：跑一次迷你 preinit，输出合并的 stdout+stderr
	env INITRAMFS= \
		PATH="$CASE/bin:$PATH" \
		TRACE="$TRACE" PREINIT_DIR="$CASE/preinit" LIBDIR="$CASE/lib" \
		PROC_MOUNTS="$MOUNTS" PREINIT_KMSG="$KMSG" \
		STUB_LOGGER_LOG="$LOGGERLOG" STUB_CMDLINE= \
		"$@" sh "$CASE/harness.sh" 2>&1
}

lines() { # <文件> <模式>：匹配行数（无匹配输出 0）
	grep -c -- "$2" "$1" 2>/dev/null || true
}

nth_line() { # <文件> <模式>：首条匹配的行号（无匹配为空）
	grep -n -- "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1
}

MOUNTS_OURS='overlay / overlay rw,noatime,lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work,xino=off 0 0'
MOUNTS_SQUASHFS='/dev/root / squashfs ro,relatime 0 0'
# 真机 live 系统的 / 行原文（fstools extroot）：lowerdir=/ ⇒ 不是我们的合成根
MOUNTS_EXTROOT='overlayfs:/overlay / overlay rw,noatime,lowerdir=/,upperdir=/overlay/upper,workdir=/overlay/work,xino=off 0 0'

echo "== 行为：/ 是我们合成的 overlay ⇒ 不注册 do_mount_root，并留可判读日志 =="
write_world ours
printf '/dev/loop0 /rom squashfs ro,relatime 0 0\n%s\n' "$MOUNTS_OURS" >"$MOUNTS"
OUT=$(run_world); RC=$?
eq "迷你 preinit 退出 0" '0' "$RC"
eq "一条 preinit_main 钩子都没注册" '0' "$(lines "$TRACE" '^add_hook')"
eq "mount_root 一次都没被调用（压住了 ramoverlay）" '0' "$(lines "$TRACE" '^mount_root')"
eq "没有跑 preinit_mount_root 那批上游钩子" '0' "$(lines "$TRACE" '^run_hook preinit_mount_root')"
contains "日志写好（kmsg 优先，含 skip 字样，可 dmesg 取证）" 'skip fstools mount_root' "$(cat "$KMSG" 2>/dev/null)"
contains "日志带 upperdir=/overlay/upper" 'upperdir=/overlay/upper' "$(cat "$KMSG" 2>/dev/null)"
contains "日志带 80_mount_root 标签" '80_mount_root' "$(cat "$KMSG" 2>/dev/null)"
eq "kmsg 可写时不再重复调 logger" '0' "$(lines "$LOGGERLOG" 'logger')"
contains "preinit 跑完整（没有 exit/break 掉后续钩子）" 'preinit_done' "$(cat "$TRACE")"
for _d in sleep reboot mount; do
	eq "没有调用 $_d" '0' "$(lines "$TRACE" "^called $_d")"
done
eq "全程静默（无 stdout/stderr 噪音）" '' "$OUT"

echo "== 行为：/ 是 squashfs（现网形态）⇒ 与上游完全一致地注册 =="
write_world squashfs
printf '%s\n' "$MOUNTS_SQUASHFS" >"$MOUNTS"
OUT=$(run_world); RC=$?
eq "迷你 preinit 退出 0" '0' "$RC"
contains "注册了 do_mount_root" 'add_hook preinit_main do_mount_root' "$(cat "$TRACE")"
eq "只注册了一个钩子" '1' "$(lines "$TRACE" '^add_hook')"
eq "mount_root 被调用一次" '1' "$(lines "$TRACE" '^mount_root')"
contains "调用形态为 mount_root start + 空选项串（上游原样）" 'mount_root:argc=2 [start] []' "$(cat "$TRACE")"
contains "钩子里 boot_run_hook preinit_mount_root 照跑" 'run_hook preinit_mount_root' "$(cat "$TRACE")"
# 上游 do_mount_root 的最后一句就是 `[ -f /sysupgrade.tgz -o -f /tmp/sysupgrade.tar ] && {...}`，
# 没有升级包时整条 && 串返回 1 ⇒ 钩子正常（非升级）跑完时 rc 就是 1；boot_run_hook 不检查它。
eq "钩子执行完并如实记下 rc（上游末句是 sysupgrade 测试，非升级时为 1，不阻断）" \
	'hook_rc do_mount_root 1' "$(grep '^hook_rc do_mount_root' "$TRACE")"
eq "不写 skip 日志" '0' "$(lines "$KMSG" 'skip')"
SRC_LINE=$(nth_line "$TRACE" '^sourced ')
MR_LINE=$(nth_line "$TRACE" '^mount_root')
RH_LINE=$(nth_line "$TRACE" '^run_hook preinit_mount_root$')
if [ -n "${MR_LINE:-}" ] && [ -n "${RH_LINE:-}" ] && [ "$MR_LINE" -lt "$RH_LINE" ]; then
	ok "顺序正确：mount_root（第 $MR_LINE 行）早于 run_hook preinit_mount_root（第 $RH_LINE 行）"
else
	bad "顺序错误：mount_root=[${MR_LINE:-}] run_hook preinit_mount_root=[${RH_LINE:-}]"
fi
if [ -n "${MR_LINE:-}" ] && [ -n "${SRC_LINE:-}" ] && [ "$MR_LINE" -gt "$SRC_LINE" ]; then
	ok "source 阶段不动作：mount_root 在第 $MR_LINE 行，source 结束在第 $SRC_LINE 行"
else
	bad "source 阶段就动作了（mount_root=[${MR_LINE:-}] sourced=[${SRC_LINE:-}]）"
fi
contains "preinit 跑完整" 'preinit_done' "$(cat "$TRACE")"
for _d in sleep reboot mount; do
	eq "没有调用 $_d" '0' "$(lines "$TRACE" "^called $_d")"
done

echo "== 行为：cmdline 里的 rootfs_mount_options.* 原样透传给 mount_root（上游 compose 逻辑） =="
write_world cmdline
printf '%s\n' "$MOUNTS_SQUASHFS" >"$MOUNTS"
OUT=$(run_world STUB_CMDLINE='console=tty0 rootfs_mount_options.compress_algorithm=zstd rootfs_mount_options.noinline_data'); RC=$?
eq "退出 0" '0' "$RC"
contains "两个选项按空格累加后透传" 'mount_root:argc=2 [start] [compress_algorithm=zstd noinline_data]' "$(cat "$TRACE")"
eq "只调用一次 mount_root" '1' "$(lines "$TRACE" '^mount_root')"

echo "== 行为：真机 extroot 的 / 行（lowerdir=/, upperdir=/overlay/upper）⇒ 必须照常注册 =="
write_world extroot
printf '%s\n' "$MOUNTS_EXTROOT" >"$MOUNTS"
OUT=$(run_world); RC=$?
eq "迷你 preinit 退出 0" '0' "$RC"
contains "照常注册 do_mount_root" 'add_hook preinit_main do_mount_root' "$(cat "$TRACE")"
eq "mount_root 照常被调用一次" '1' "$(lines "$TRACE" '^mount_root')"
eq "不写 skip 日志（没有误跳过）" '0' "$(lines "$KMSG" 'skip')"
contains "preinit 跑完整" 'preinit_done' "$(cat "$TRACE")"

echo "== 行为：近似但不相等的 / 行 ⇒ 一律照常注册（判定要严） =="
write_world other_upper
printf '%s\n' 'overlay / overlay rw,lowerdir=/lower,upperdir=/ovl/upper,workdir=/ovl/work 0 0' >"$MOUNTS"
OUT=$(run_world)
contains "upperdir 不是 /overlay/upper 时仍注册" 'add_hook preinit_main do_mount_root' "$(cat "$TRACE")"
eq "upperdir 不是 /overlay/upper 时不跳过" '1' "$(lines "$TRACE" '^mount_root')"

write_world other_lower
printf '%s\n' 'overlay / overlay rw,lowerdir=/lower2,upperdir=/overlay/upper,workdir=/overlay/work 0 0' >"$MOUNTS"
OUT=$(run_world)
contains "lowerdir 是 /lower2 时仍注册（不能只做子串匹配）" 'add_hook preinit_main do_mount_root' "$(cat "$TRACE")"

write_world no_lower
printf '%s\n' 'overlay / overlay rw,upperdir=/overlay/upper,workdir=/overlay/work 0 0' >"$MOUNTS"
OUT=$(run_world)
contains "缺 lowerdir 时仍注册" 'add_hook preinit_main do_mount_root' "$(cat "$TRACE")"

write_world not_root
# 我们的选项串出现在别的挂载点上，不算数
printf '%s\n' 'overlay /data overlay rw,lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work 0 0' >"$MOUNTS"
printf '%s\n' "$MOUNTS_SQUASHFS" >>"$MOUNTS"
OUT=$(run_world)
contains "/ 行不是 overlay 时仍注册" 'add_hook preinit_main do_mount_root' "$(cat "$TRACE")"

write_world unreadable
OUT=$(run_world PROC_MOUNTS="$CASE/no-such-file"); RC=$?
eq "读不到 mounts 时退出 0" '0' "$RC"
contains "读不到 mounts 时退回上游行为（注册）" 'add_hook preinit_main do_mount_root' "$(cat "$TRACE")"
eq "读不到 mounts 时不写 skip 日志" '0' "$(lines "$KMSG" 'skip')"

echo "== 行为：上游 \$INITRAMFS 守卫优先（两种情形都不注册，且不得报错） =="
write_world initramfs_ours
printf '%s\n' "$MOUNTS_OURS" >"$MOUNTS"
OUT=$(run_world INITRAMFS=1); RC=$?
eq "INITRAMFS=1 + 我们的根：退出 0" '0' "$RC"
eq "INITRAMFS=1 + 我们的根：不注册钩子（上游守卫先短路）" '0' "$(lines "$TRACE" '^add_hook')"
eq "INITRAMFS=1 + 我们的根：不调用 mount_root" '0' "$(lines "$TRACE" '^mount_root')"
contains "INITRAMFS=1 + 我们的根：preinit 跑完整" 'preinit_done' "$(cat "$TRACE")"
eq "INITRAMFS=1 + 我们的根：没有任何输出/报错" '' "$OUT"

write_world initramfs_squashfs
printf '%s\n' "$MOUNTS_SQUASHFS" >"$MOUNTS"
OUT=$(run_world INITRAMFS=1); RC=$?
eq "INITRAMFS=1 + squashfs：退出 0" '0' "$RC"
eq "INITRAMFS=1 + squashfs：不注册钩子" '0' "$(lines "$TRACE" '^add_hook')"
eq "INITRAMFS=1 + squashfs：不调用 mount_root" '0' "$(lines "$TRACE" '^mount_root')"
eq "INITRAMFS=1 + squashfs：保持静默" '' "$OUT"

echo "== 行为：mount_root 失败也不阻断 preinit（ac-2） =="
write_world mr_fails
printf '%s\n' "$MOUNTS_SQUASHFS" >"$MOUNTS"
OUT=$(run_world STUB_MOUNT_ROOT_RC=1); RC=$?
eq "mount_root 返回 1 时 preinit 仍退出 0" '0' "$RC"
eq "mount_root 确实被调用过" '1' "$(lines "$TRACE" '^mount_root')"
contains "mount_root 失败后 do_mount_root 剩余部分照跑" 'run_hook preinit_mount_root' "$(cat "$TRACE")"
contains "后续 preinit 照常跑完" 'preinit_done' "$(cat "$TRACE")"

echo "== 行为：日志退化（kmsg 不可写 → logger；再失败也静默） =="
write_world log_fallback
printf '%s\n' "$MOUNTS_OURS" >"$MOUNTS"
OUT=$(run_world PREINIT_KMSG="$CASE/no-such-dir/kmsg" STUB_LOGGER_RC=0); RC=$?
eq "kmsg 不可写时退出 0" '0' "$RC"
contains "退化写入 logger，仍含 skip 字样" 'skip fstools mount_root' "$(cat "$LOGGERLOG" 2>/dev/null)"
eq "logger 只调一次" '1' "$(lines "$LOGGERLOG" 'logger')"
eq "仍然不注册钩子" '0' "$(lines "$TRACE" '^add_hook')"

write_world log_dead
printf '%s\n' "$MOUNTS_OURS" >"$MOUNTS"
OUT=$(run_world PREINIT_KMSG="$CASE/no-such-dir/kmsg" STUB_LOGGER_RC=1); RC=$?
eq "kmsg 与 logger 都失败时仍退出 0" '0' "$RC"
eq "两种日志都不可用时仍不注册钩子" '0' "$(lines "$TRACE" '^add_hook')"
contains "两种日志都不可用时 preinit 跑完整" 'preinit_done' "$(cat "$TRACE")"
not_contains "无 stderr 噪音" 'command not found' "$OUT"
not_contains "无重定向报错噪音" 'cannot create' "$OUT"

finish PREINIT-MOUNT-ROOT
