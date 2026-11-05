#!/bin/sh
# ac-3：/lib/preinit/79-btrfs 必须在 80_mount_root 之前把 btrfs 模块加载好、
# 只加载 btrfs 一个模块、失败也不阻断启动。
#
# 全程离线：不碰真实内核模块，也不用宿主的 /proc/filesystems。
# 行为断言靠一个"迷你 /etc/preinit"：按字典序 source <preinit 目录>/*（上游语义），
# 再用 boot_hook_add/boot_run_hook 的替身按注册顺序执行 preinit_main 钩子。
# 因此"早于 80_mount_root"是用真实排序规则跑出来的，不是抄一份期望顺序自证。
set -u
. "$(dirname "$0")/lib-assert.sh"

TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
SRC=$REPO/files/lib/preinit/79-btrfs
NAME=$(basename "$SRC")

SB_ROOT=$(mktemp -d "/tmp/sb-preinit.XXXXXX" 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 2
}

echo "== 静态结构 =="
if [ -f "$SRC" ]; then
	ok "存在 $SRC"
else
	bad "缺少 files/lib/preinit/79-btrfs"
fi
TEXT=$(cat "$SRC" 2>/dev/null)
if [ -n "$TEXT" ]; then ok "非空（$(printf '%s' "$TEXT" | wc -l | tr -d ' ') 行）"; else bad "文件为空或不存在"; fi
contains "注册 preinit_main 钩子" 'boot_hook_add preinit_main' "$TEXT"
contains "注释说明为什么必须早于 80_mount_root" '80_mount_root' "$TEXT"
contains "失败路径 return 0" 'return 0' "$TEXT"
eq "只 modprobe btrfs（去重后的模块名集合）" 'btrfs' \
	"$(printf '%s\n' "$TEXT" | grep -Eo 'modprobe [a-zA-Z0-9_.-]+' | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
not_contains "没有走 kmodloader insmod 退化路径" 'insmod' "$TEXT"
eq "被 source 后不留副作用（无 sleep/reboot/exit 命令）" '' \
	"$(printf '%s\n' "$TEXT" | grep -E '^[[:space:]]*(sleep|reboot|exit)[[:space:]]' | tr -d '\t' | tr '\n' ' ' | sed 's/ $//')"
if sh -n "$SRC" 2>/dev/null; then ok "语法正确（sh -n）"; else bad "sh -n 报语法错误"; fi

echo "== 字典序：仓库里每个 btrfs preinit 脚本都必须排在 80_mount_root 之前 =="
# 名字从目录里取（不是抄 SRC 的字面量）：改名/多一个 btrfs preinit 脚本都会被这条抓到。
PREINIT_DIR=$REPO/files/lib/preinit
BTRFS_SCRIPTS=$(ls "$PREINIT_DIR" 2>/dev/null | grep -i btrfs)
eq "只有一个 btrfs preinit 脚本，且叫 79-btrfs" '79-btrfs' \
	"$(printf '%s' "$BTRFS_SCRIPTS" | tr '\n' ' ' | sed 's/ $//')"
for _n in $BTRFS_SCRIPTS; do
	# 用真实 sort 规则算位次（LC_ALL=C 与内核/ash 的字节序一致），1 = 排最前
	_pos=$(printf '%s\n' "$_n" 79_move_config 80_mount_root | LC_ALL=C sort | grep -n -x -- "$_n" | cut -d: -f1)
	eq "'$_n' 在 sort(79-btrfs 79_move_config 80_mount_root) 里的位次" '1' "$_pos"
done

# ---------------------------------------------------------------------------
# 迷你 preinit 世界
#   <case>/bin/{modprobe,logger}   桩：记录调用并可用 env 控制退出码
#   <case>/preinit/*               被测文件 + 上游同名脚本桩（79_move_config 等）
#   <case>/proc/filesystems        伪 /proc/filesystems（实例化用例可读写）
#   <case>/trace.log               唯一的执行轨迹（source/hook/命令都落这里）
# ---------------------------------------------------------------------------

write_world() { # <case 名>
	CASE=$SB_ROOT/$1
	TRACE=$CASE/trace.log
	LOGGERLOG=$CASE/logger.log
	KMSG=$CASE/kmsg
	FS=$CASE/proc/filesystems
	mkdir -p "$CASE/bin" "$CASE/preinit" "$CASE/proc"
	: >"$TRACE"
	: >"$LOGGERLOG"
	: >"$KMSG"
	: >"$FS"

	# modprobe 桩：记录参数；成功时把 btrfs 写进伪 /proc/filesystems
	# （真内核也是这样：模块一加载，文件系统类型就出现在 /proc/filesystems）
	cat >"$CASE/bin/modprobe" <<'EOS'
#!/bin/sh
printf 'modprobe %s\n' "$*" >>"$TRACE"
[ "${STUB_MODPROBE_RC:-0}" = 0 ] || exit "${STUB_MODPROBE_RC}"
if [ -n "${STUB_FS:-}" ] && ! grep -qs btrfs "$STUB_FS"; then
	printf 'nodev\tbtrfs\n' >>"$STUB_FS"
fi
exit 0
EOS
	cat >"$CASE/bin/logger" <<'EOS'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$STUB_LOGGER_LOG"
exit "${STUB_LOGGER_RC:-0}"
EOS
	chmod +x "$CASE/bin/modprobe" "$CASE/bin/logger"

	# 被测文件按仓库里的真实文件名落位，排序由它的名字本身决定
	cp "$SRC" "$CASE/preinit/$NAME" 2>/dev/null

	# 上游同名脚本桩：注册 preinit_main 钩子，执行时只往 trace 里记一行
	for _up in 79_move_config 80_mount_root 85_btrfs_scan_post; do
		_fn=upstream_$(printf '%s' "$_up" | tr -c 'a-zA-Z0-9' '_')
		{
			printf '#!/bin/sh\n'
			printf '%s() { printf "ran %s\\n" >>"$TRACE"; }\n' "$_fn" "$_up"
			printf 'boot_hook_add preinit_main %s\n' "$_fn"
		} >"$CASE/preinit/$_up"
	done

	cat >"$CASE/harness.sh" <<'EOS'
#!/bin/sh
# 迷你 /etc/preinit：字典序 source 全部 preinit 脚本，再 boot_run_hook preinit_main。
# boot_hook_add 追加、boot_run_hook 按注册顺序执行 —— 与上游 /etc/preinit 一致。
set -u
LC_ALL=C
HOOKS=
boot_hook_add() {
	HOOKS="$HOOKS $2"
	printf 'add_hook %s %s\n' "$1" "$2" >>"$TRACE"
}
boot_run_hook() {
	for _h in $HOOKS; do
		"$_h"
		printf 'hook_rc %s %s\n' "$_h" "$?" >>"$TRACE"
	done
	printf 'hook_done %s\n' "$1" >>"$TRACE"
}
for _f in "$PREINIT_DIR"/*; do
	. "$_f"
	printf 'sourced %s\n' "${_f##*/}" >>"$TRACE"
done
boot_run_hook preinit_main
printf 'preinit_done\n' >>"$TRACE"
EOS
}

run_world() { # [额外 env 赋值...]：跑一次迷你 preinit，输出合并的 stdout+stderr
	env PREINIT=1 \
		PATH="$CASE/bin:$PATH" \
		TRACE="$TRACE" PREINIT_DIR="$CASE/preinit" \
		PROC_FILESYSTEMS="$FS" PREINIT_KMSG="$KMSG" \
		STUB_FS="$FS" STUB_LOGGER_LOG="$LOGGERLOG" \
		"$@" sh "$CASE/harness.sh" 2>&1
}

lines() { # <文件> <模式>：匹配行数（无匹配输出 0）
	grep -c -- "$2" "$1" 2>/dev/null || true
}

nth_line() { # <文件> <模式>：首条匹配的行号（无匹配为空）
	grep -n -- "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1
}

# 钩子函数名从 trace 里取（不硬编码实现里的函数名）：第一条注册到 preinit_main 的钩子是
# 本文件注册的（它文件名排最前），后续才是 79_move_config/80_mount_root 桩。
hook_fn() { grep '^add_hook preinit_main' "$TRACE" 2>/dev/null | head -n1 | awk '{print $3}'; }
# 本文件注册的钩子条数 = 非上游桩（upstream_*）的 add_hook 条数
own_hooks() { grep '^add_hook preinit_main' "$TRACE" 2>/dev/null | grep -v 'upstream_' | wc -l | tr -d ' '; }
hook_rc_line() { grep "^hook_rc $1 " "$TRACE" 2>/dev/null; }

echo "== 行为：正常加载 =="
write_world normal
OUT=$(run_world STUB_MODPROBE_RC=0); RC=$?
eq "迷你 preinit 退出 0" '0' "$RC"
contains "加载成功后写日志（kmsg 优先）" 'btrfs' "$(cat "$KMSG" 2>/dev/null)"
eq "只注册了一个 preinit_main 钩子" '1' "$(own_hooks)"
eq "modprobe 只被调用一次" '1' "$(lines "$TRACE" '^modprobe')"
eq "调用内容逐字为 btrfs" 'modprobe btrfs' "$(grep '^modprobe' "$TRACE")"
FN=$(hook_fn)
if [ -n "$FN" ]; then ok "钩子函数名解析到 [$FN]"; else bad "trace 里没有 preinit_main 钩子注册记录"; fi
eq "钩子返回 0" "hook_rc $FN 0" "$(hook_rc_line "$FN")"
LAST_SRC=$(nth_line "$TRACE" '^sourced ')
FIRST_MOD=$(nth_line "$TRACE" '^modprobe')
# 首个 modprobe 必须晚于"最后一个 source"：source 阶段本身不许加载模块（无阻塞副作用）
SOURCE_N=$(grep -c '^sourced ' "$TRACE" 2>/dev/null || true)
if [ -n "${FIRST_MOD:-}" ] && [ -n "${LAST_SRC:-}" ] && [ "$FIRST_MOD" -gt "$LAST_SRC" ]; then
	ok "source 阶段不加载模块（modprobe 在第 $FIRST_MOD 行，最后一个 source 在第 $LAST_SRC 行，共 $SOURCE_N 个）"
else
	bad "modprobe 出现在 source 阶段（modprobe=[${FIRST_MOD:-}] last_sourced=[${LAST_SRC:-}]）"
fi
eq "钩子执行的第一条命令就是加载 btrfs" 'modprobe btrfs' \
	"$(grep -E '^(modprobe |ran )' "$TRACE" | head -n1)"
not_contains "第一个注册的钩子不是上游桩（即本文件排最前）" 'upstream_' \
	"$(grep '^add_hook' "$TRACE" | head -n1)"
BTRFS_LINE=$(grep -n '^modprobe btrfs$' "$TRACE" | head -n1 | cut -d: -f1)
MOUNT_LINE=$(grep -n '^ran 80_mount_root$' "$TRACE" | head -n1 | cut -d: -f1)
if [ -n "${BTRFS_LINE:-}" ] && [ -n "${MOUNT_LINE:-}" ] && [ "$BTRFS_LINE" -lt "$MOUNT_LINE" ]; then
	ok "btrfs 加载（第 $BTRFS_LINE 行）早于 80_mount_root（第 $MOUNT_LINE 行）"
else
	bad "btrfs 未在 80_mount_root 之前加载（btrfs=[${BTRFS_LINE:-}] mount_root=[${MOUNT_LINE:-}]）"
fi
contains "preinit 跑完整（钩子没有 exit）" 'preinit_done' "$(cat "$TRACE")"
eq "kmsg 可写时不再重复调 logger" '0' "$(lines "$LOGGERLOG" 'logger')"

echo "== 行为：幂等（btrfs 已在 /proc/filesystems 时不重复 modprobe） =="
# 同一个世界再跑一遍：桩 modprobe 首次成功后会把 btrfs 写进伪 /proc/filesystems（真内核同构），
# 所以第二次必须直接跳过 modprobe。
OUT=$(run_world STUB_MODPROBE_RC=0); RC=$?
eq "第二次执行退出码 0" '0' "$RC"
eq "跨两次执行仍只加载一次" '1' "$(lines "$TRACE" '^modprobe')"
write_world preloaded
printf 'nodev\tbtrfs\n' >"$FS"
OUT=$(run_world STUB_MODPROBE_RC=0); RC=$?
eq "已加载时退出 0" '0' "$RC"
eq "已加载时一次也不 modprobe" '0' "$(lines "$TRACE" '^modprobe')"
eq "已加载时不写告警" '0' "$(lines "$KMSG" 'WARN')"

echo "== 行为：modprobe 失败必须 return 0 且留日志 =="
write_world failing
OUT=$(run_world STUB_MODPROBE_RC=1); RC=$?
eq "modprobe 失败时 preinit 仍退出 0" '0' "$RC"
eq "modprobe 确实失败过（只试 btrfs）" 'modprobe btrfs' "$(grep '^modprobe' "$TRACE")"
eq "钩子失败后仍返回 0" "hook_rc $(hook_fn) 0" "$(hook_rc_line "$(hook_fn)")"
contains "失败留日志（走 kmsg）" 'WARN' "$(cat "$KMSG" 2>/dev/null)"
contains "日志说明退化为内部 overlay" 'overlay' "$(cat "$KMSG" 2>/dev/null)"
contains "后续 preinit 钩子照常执行（80_mount_root）" 'ran 80_mount_root' "$(cat "$TRACE")"
contains "preinit 跑完整（钩子没有 exit）" 'preinit_done' "$(cat "$TRACE")"
not_contains "无 stderr 噪音" 'command not found' "$OUT"

echo "== 行为：/dev/kmsg 不可写时退化到 logger，再失败也不报错 =="
write_world fallback
OUT=$(run_world STUB_MODPROBE_RC=1 PREINIT_KMSG="$CASE/no-such-dir/kmsg" STUB_LOGGER_RC=0); RC=$?
eq "kmsg 不可写时退出 0" '0' "$RC"
contains "退化写入 logger" 'WARN' "$(cat "$LOGGERLOG" 2>/dev/null)"
eq "logger 只调一次" '1' "$(lines "$LOGGERLOG" 'logger')"
write_world fallback2
OUT=$(run_world STUB_MODPROBE_RC=1 PREINIT_KMSG="$CASE/no-such-dir/kmsg" STUB_LOGGER_RC=1); RC=$?
eq "kmsg 与 logger 都失败时仍退出 0" '0' "$RC"
contains "两种日志都不可用时 preinit 跑完整" 'preinit_done' "$(cat "$TRACE")"
eq "两种日志都失败也不影响钩子返回值" "hook_rc $(hook_fn) 0" "$(hook_rc_line "$(hook_fn)")"

finish BTRFS-PREINIT
