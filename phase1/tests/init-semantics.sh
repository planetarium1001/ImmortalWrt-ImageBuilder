#!/bin/sh
# ac-3：phase1/initramfs/init 的引导链语义（全离线断言）。
#
# 断言的是"无显示器/无键盘 + panic=10 会反复重启"这个环境下的硬要求：
#   * 每个失败点都走 die()：写持久日志 -> 删 /boot/try-phase1 -> sync;sleep 5;reboot -f
#   * 看门狗超时 = 一次失败：必须与 die 同语义（也删标记），否则重启后又撞同一条坏入口
#   * 成功切根前也要删标记（删标记 = 本次试跑已被消耗）⇒ 三条路径都不会形成重启循环
#   * 删标记不依赖路径推断：主路径没删到就按 p1 的 boot/ 与根兜底（残窗见下）
#   * F-1：p1 根下有自己的 boot/ 目录（live 的 /boot = p1:/boot）⇒ 标记/日志必须在
#     <p1>/<phase1_bootsub>/ 里，不能拿 p1 根冒充 /boot（否则 GRUB 看到的标记永远删不掉）
#   * 绝不落交互 shell（读 tty1 会永久挂死）
#   * 总超时看门狗存在，且 switch_root 之前必须撤掉（否则切根后把新系统重启掉）
#   * overlay 参数串逐字为 lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work
#   * /lower 以 ro 挂载，且有"实际写不进去"的断言
#   * 写入探针：合成根上 touch 必须出现在 /overlay/upper
#   * /lower、/overlay 搬进新根（mount -o move，失败退化二次挂载），两条都有断言
#   * 模块只用 /sbin/modprobe；CONFIG_DEVTMPFS=n 下自己 mount tmpfs /dev + mknod
#
# 只读文件、只 grep/sed，不执行 /init（它在真机上才由内核执行）。
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"
SRC=$REPO/phase1/initramfs/init
MK=$REPO/phase1/make-initramfs.sh
NAME='phase1-init-semantics'
SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sb-init-sem.XXXXXX" 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 2
}

if [ ! -f "$SRC" ]; then
	echo "  FAIL 缺少 $SRC"
	finish "$NAME"
fi
TEXT=$(cat "$SRC")

# 取某段函数体（从 "<fn>() {" 到第一个行首 "}"）
fn_body() { sed -n "/^$1() {/,/^}/p" "$SRC"; }
ln_of() { grep -n -- "$1" "$SRC" | head -n1 | cut -d: -f1; }
lines_of() { grep -c -- "$1" "$SRC" 2>/dev/null || true; }

echo "== 基本形态 =="
eq "第一行 shebang 是 busybox" '#!/bin/busybox sh' "$(head -n1 "$SRC")"
if sh -n "$SRC" 2>/dev/null; then ok "sh -n 通过（POSIX/busybox ash 子集）"; else bad "sh -n 报语法错误"; fi
eq "单文件（不含 source/. 其它脚本）" '0' "$(lines_of '^[[:space:]]*\. .*\.sh')"
contains "PATH 只含 /bin:/sbin" 'PATH=/bin:/sbin' "$TEXT"
_bare=$(printf '%s\n' "$TEXT" | sed -e 's/^[[:space:]]*//' \
	| grep -E '^(mount|mkdir|touch|rm|ln|cat|grep|cut|echo|sleep|sync|reboot|switch_root|umount|mknod|readlink|printf|kill|sed|awk|find|xargs) ' \
	| grep -v '^#' | tr '\n' ';')
eq "没有裸 applet 调用（必须 /bin/busybox 前缀）" '' "$_bare"

echo "== F-1：p1 根下有 boot/ 子目录时，标记必须命中 p1:/boot/try-phase1 =="
# 真机几何：p1 根下有 boot/ 与 efi/；live 的 /boot 是 p1:/boot（79_move_config 的 --bind）。
# 所以 /init 必须挂 p1 **根**到 ${P1_PART_DIR}，标记/日志放进 <bootsub>/ 子目录。
contains "p1 挂载点是独立目录 /p1（不是 /boot）" "P1_PART_DIR='/p1'" "$TEXT"
contains "挂 p1 根到 \$P1_PART_DIR" 'mount -t vfat -o rw,noatime "$PHASE1_BOOT" "$P1_PART_DIR"' "$TEXT"
not_contains "不再把 p1 根直接挂成 /boot" 'mount -t vfat -o rw,noatime "$PHASE1_BOOT" "$P1_BOOT_DIR"' "$TEXT"
contains "挂上后确认 boot 子目录存在（不存在即 die bootlog）" '[ -d "$P1_BOOT_DIR" ]' "$TEXT"
contains "die bootlog 的报错提到 phase1_bootsub" 'phase1_bootsub=${P1_BOOTSUB:-<空=p1 根>}' "$TEXT"
# 几何不一致时的兜底：正常路径删不掉标记 ⇒ 按 p1 上两个已知位置再试一次（否则无键盘 = 重启循环）
RESCUE=$(fn_body rescue_drop_marker)
if [ -n "$RESCUE" ]; then ok "定义了 rescue_drop_marker()（只给几何不一致兜底）"; else bad "没有 rescue_drop_marker()"; fi
contains "兜底会试 p1 根下的 boot/try-phase1" '"$P1_PART_DIR/boot/try-phase1"' "$RESCUE"
contains "兜底也会试 p1 根直放" '"$P1_PART_DIR/try-phase1"' "$RESCUE"
contains "兜底删成功记 rescued: removed（判读串）" 'rescued: removed' "$RESCUE"
DROP_FN=$(fn_body drop_trial_marker)
contains "drop_trial_marker 在主路径没删到后走兜底" 'rescue_drop_marker' "$DROP_FN"
contains "主路径删不掉的中间态有独立判读串（不与终态 REMOVE-FAILED 混淆）" 'main-remove-failed' "$DROP_FN"
contains "兜底状态区分「本来就没有」与「删不掉」" '[ "$_stuck" = 1 ] && return 2' "$RESCUE"
contains "注释里写明 F-1 这个坑" 'F-1' "$TEXT"
if grep -q 'cmdline_get phase1_bootsub' "$SRC"; then ok "支持 cmdline 键 phase1_bootsub（--boot-subdir 可为空）"; else bad "缺少 cmdline 键 phase1_bootsub"; fi
eq "默认 phase1_bootsub 来自占位符 @BOOTSUB@" "DEF_BOOTSUB='@BOOTSUB@'" \
	"$(grep -E '^DEF_BOOTSUB=' "$SRC" | head -n1)"
# 把 set_boot_paths 从被测文件里取出来真跑一遍（不是抄一份期望值）
PATHS_FN=$(sed -n '/^set_boot_paths() {/,/^}/p' "$SRC")
if [ -n "$PATHS_FN" ]; then
	P1_PART_DIR=/p1
	eval "$PATHS_FN"
	set_boot_paths boot
	eq "几何「p1 根下有 boot/」：标记 = /p1/boot/try-phase1（= GRUB 查的那个文件）" \
		'/p1/boot/try-phase1' "$P1_MARKER"
	eq "几何「p1 根下有 boot/」：日志 = /p1/boot/phase1-boot.log" '/p1/boot/phase1-boot.log' "$P1_LOG"
	not_contains "标记不是 p1 根下的 /p1/try-phase1（F-1 的错法）" '/p1/try-phase1' "$P1_MARKER"
	set_boot_paths ''
	eq "几何「引导文件直放 p1 根」：标记 = /p1/try-phase1" '/p1/try-phase1' "$P1_MARKER"
	set_boot_paths '.'
	eq "写 '.' 等价于 p1 根" '/p1/try-phase1' "$P1_MARKER"
	set_boot_paths '/'
	eq "写 '/' 等价于 p1 根" '/p1/try-phase1' "$P1_MARKER"
	set_boot_paths boot
else
	bad "没有 set_boot_paths()（路径模型被写散了，F-1 这类错抓不到）"
fi

echo "== F-1 残窗：phase1_bootsub 指向「存在但非引导」的子目录时仍必须删到 boot/try-phase1 =="
# 真机残留窗口（tm-03 提出）：bootsub=efi 时 $P1_BOOT_DIR 存在 ⇒ 旧的"目录不存在才兜底"抓不到，
# 标记（在 boot/ 里）删不掉 ⇒ 重启循环。这里把三个被测函数原样取出来在沙盒里**真跑**：
# 只把 `/bin/busybox ` 前缀去掉（宿主没有 busybox），路径与判定逻辑一字未改。
GEOM=$SB_ROOT/marker-geom
mkdir -p "$GEOM/p1/boot" "$GEOM/p1/efi"
GLOG=$SB_ROOT/drop-marker.log
: >"$GLOG"
logline() { printf '%s\n' "$*" >> "$GLOG"; }        # 桩：收集日志行
P1_PART_DIR=$GEOM/p1
eval "$(fn_body set_boot_paths     | sed 's|/bin/busybox ||g')"
eval "$(fn_body rescue_drop_marker | sed 's|/bin/busybox ||g')"
eval "$(fn_body drop_trial_marker  | sed 's|/bin/busybox ||g')"
if command -v set_boot_paths >/dev/null 2>&1 && command -v drop_trial_marker >/dev/null 2>&1; then
	ok "三个函数都能从被测文件里取出并定义（可行为测试）"
else
	bad "取不出 set_boot_paths/rescue_drop_marker/drop_trial_marker（无法行为测试）"
fi

# ① 错位但目录存在：bootsub=efi
: >"$GEOM/p1/boot/try-phase1"; : >"$GLOG"
set_boot_paths efi
eq "错位(bootsub=efi)：主路径指向存在的非引导目录" "$GEOM/p1/efi/try-phase1" "$P1_MARKER"
drop_trial_marker 2>/dev/null; _dm_rc=$?   # 2>/dev/null：只收集日志行，console 回声由静态断言覆盖
eq "错位(bootsub=efi)：drop_trial_marker 仍返回 0" '0' "$_dm_rc"
eq "错位(bootsub=efi)：p1/boot/try-phase1 真的被删掉" 'gone' \
	"$( [ -e "$GEOM/p1/boot/try-phase1" ] && echo present || echo gone )"
contains "错位(bootsub=efi)：日志记 rescued: removed" 'recovery: rescued: removed' "$(cat "$GLOG")"
contains "错位(bootsub=efi)：日志点名兜底删掉的路径" "$GEOM/p1/boot/try-phase1" "$(cat "$GLOG")"

# ② 正常几何：走主路径
: >"$GEOM/p1/boot/try-phase1"; : >"$GLOG"
set_boot_paths boot
drop_trial_marker 2>/dev/null; _dm_rc=$?   # 2>/dev/null：只收集日志行，console 回声由静态断言覆盖
eq "正常几何：返回 0" '0' "$_dm_rc"
contains "正常几何：日志记 removed <主路径>" "recovery: removed $GEOM/p1/boot/try-phase1" "$(cat "$GLOG")"
not_contains "正常几何：不出现 rescued" 'rescued:' "$(cat "$GLOG")"

# ③ 根本没有标记（live 默认项）
: >"$GLOG"
drop_trial_marker 2>/dev/null; _dm_rc=$?   # 2>/dev/null：只收集日志行，console 回声由静态断言覆盖
eq "没有标记：返回 0（本来就是 live 默认项）" '0' "$_dm_rc"
contains "没有标记：记 no marker（不误报 REMOVE-FAILED）" 'recovery: no marker at' "$(cat "$GLOG")"
not_contains "没有标记：不出现 REMOVE-FAILED" 'REMOVE-FAILED' "$(cat "$GLOG")"

# ④ 标记存在但删不掉（用目录模拟 rm 失败）：必须终态失败，不许静默放过
mkdir -p "$GEOM/p1/boot/try-phase1"; : >"$GLOG"
set_boot_paths efi
drop_trial_marker 2>/dev/null; _dm_rc=$?   # 2>/dev/null：只收集日志行，console 回声由静态断言覆盖
eq "两处都删不掉：返回 1（终态）" '1' "$_dm_rc"
contains "两处都删不掉：记 REMOVE-FAILED" 'recovery: REMOVE-FAILED' "$(cat "$GLOG")"
rmdir "$GEOM/p1/boot/try-phase1" 2>/dev/null || true
set_boot_paths boot

echo "== 失败语义：die() 是唯一出口 =="
DIE=$(fn_body die)
if [ -n "$DIE" ]; then ok "定义了 die()"; else bad "没有 die() 函数"; fi
contains "die 写持久日志" 'logline "$_m"' "$DIE"
contains "die 的日志行带稳定阶段名（FAIL stage=）" 'phase1-init: FAIL stage=' "$DIE"
# 删标记抽成单一实现，die / 看门狗 / 成功切根三处共用（语义漂移 = 重启循环）
DROP=$(fn_body drop_trial_marker)
if [ -n "$DROP" ]; then ok "定义了 drop_trial_marker()（唯一实现）"; else bad "没有 drop_trial_marker()"; fi
contains "标记由 P1_BOOT_DIR 推出（只有一个真实位置）" 'P1_MARKER="$P1_BOOT_DIR/try-phase1"' "$TEXT"
contains "日志同样由 P1_BOOT_DIR 推出" 'P1_LOG="$P1_BOOT_DIR/phase1-boot.log"' "$TEXT"
not_contains "没有第二个标记视角（F-1 之后不该再有 P1_MARKER_NEW）" 'P1_MARKER_NEW' "$TEXT"
not_contains "没有第二个日志视角（不该再有 P1_LOG_NEW）" 'P1_LOG_NEW' "$TEXT"
contains "drop_trial_marker 真的 rm" 'rm -f "$P1_MARKER"' "$DROP"
contains "drop_trial_marker 记 REMOVE-FAILED 判读串" 'REMOVE-FAILED' "$DROP"
contains "drop_trial_marker 记 removed 判读串" 'recovery: removed' "$DROP"
contains "drop_trial_marker 处理「本来没有标记」的情况" 'no marker at' "$DROP"
contains "drop_trial_marker 日志里点明删的路径" 'removed ${P1_MARKER}' "$DROP"
contains "die 调 drop_trial_marker" 'drop_trial_marker' "$DIE"
contains "die 有 sync" 'busybox sync' "$DIE"
contains "die 有 sleep 5" 'sleep 5' "$DIE"
contains "die 走 reboot -f" 'reboot -f' "$DIE"
contains "die 在 reboot -f 也失败时把 FAIL 行也写进持久日志（无屏幕时 console 等于丢了）" \
	'logline "phase1-init: FAIL stage=${_stage}: reboot -f 也失败' "$DIE"
contains "die 先撤看门狗（避免自己触发两次重启）" 'stop_watchdog' "$DIE"
contains "die 会补挂 p1 自救（模块阶段失败也能删标记）" 'ensure_bootlog' "$DIE"
# H1（审计）：删标记必须**无条件**。判据：剔除注释与空行后，drop_trial_marker 的前一条语句
# 就是 stop_watchdog（说明它没被包在 `if [ -n "$LOG_READY" ]` 里；LOG_READY 只决定 logline）。
DIE_CODE=$(printf '%s\n' "$DIE" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
_dm_prev=$(printf '%s\n' "$DIE_CODE" | awk '/drop_trial_marker/{print prev; exit} {prev=$0}' | tr -d '[:space:]')
eq "die 里 drop_trial_marker 前一条语句是 stop_watchdog（= 未被 LOG_READY 门控）" 'stop_watchdog' "$_dm_prev"
contains "die 用 return 值区分 removed / REMOVE-FAILED" '_mk_rc=$?' "$DIE"
contains "日志不可用时把删标记结果写 stderr（无屏幕时唯一留痕）" '日志不可用；删标记结果 rc=' "$DIE"
contains "drop_trial_marker 自己上 console 记 removed（不依赖日志可写）" 'recovery: removed ${P1_MARKER}" >&2' "$TEXT"

# die 内部顺序：日志 -> 删标记（drop_trial_marker）-> sync -> reboot
_d_log=$(printf '%s\n' "$DIE" | grep -n 'logline "\$_m"' | head -n1 | cut -d: -f1)
_d_rm=$(printf '%s\n' "$DIE" | grep -n 'drop_trial_marker' | head -n1 | cut -d: -f1)
_d_sync=$(printf '%s\n' "$DIE" | grep -n 'busybox sync' | head -n1 | cut -d: -f1)
_d_reb=$(printf '%s\n' "$DIE" | grep -n 'busybox reboot -f' | head -n1 | cut -d: -f1)
if [ -n "$_d_log" ] && [ -n "$_d_rm" ] && [ -n "$_d_sync" ] && [ -n "$_d_reb" ] \
   && [ "$_d_log" -lt "$_d_rm" ] && [ "$_d_rm" -lt "$_d_sync" ] && [ "$_d_sync" -lt "$_d_reb" ]; then
	ok "die 内部顺序 日志($_d_log) < 删标记($_d_rm) < sync($_d_sync) < reboot($_d_reb)"
else
	bad "die 内部顺序不对（log=$_d_log rm=$_d_rm sync=$_d_sync reboot=${_d_reb}）"
fi

# 路径不许写死成 /boot/...（F-1 就是这么错的）：只允许从 P1_BOOT_DIR 推出
eq "标记不是写死的 /boot/try-phase1（必须由 P1_BOOT_DIR 推出）" 'P1_MARKER="$P1_BOOT_DIR/try-phase1"' \
	"$(grep -E '^[[:space:]]+P1_MARKER=' "$SRC" | tr -d '\t' | head -n1)"
eq "日志不是写死的 /boot/phase1-boot.log（必须由 P1_BOOT_DIR 推出）" 'P1_LOG="$P1_BOOT_DIR/phase1-boot.log"' \
	"$(grep -E '^[[:space:]]+P1_LOG=' "$SRC" | tr -d '\t' | head -n1)"

echo "== 绝不落交互 shell =="
not_contains "没有 exec /bin/busybox sh（交互 shell）" 'exec /bin/busybox sh' "$TEXT"
not_contains "没有裸 sh 兜底" 'exec sh' "$TEXT"
eq "没有调用 shell 子进程（除了 shebang 里的 /bin/busybox sh）" '1' "$(grep -c 'busybox sh' "$SRC")"
eq "read 只用于读管道（while read -r），不是读键盘" \
	"$(grep -c 'while read -r' "$SRC")" "$(grep -cE '(^|[[:space:]|])read ' "$SRC")"
not_contains "没有 sh -i / ash -i" ' -i ' "$TEXT"
not_contains "没有 /bin/sh" '/bin/sh' "$TEXT"
eq "没有 exit（流程只有 exec switch_root 与 die）" '0' "$(lines_of '^[[:space:]]*exit ')"
contains "die 的最后一行是死等（reboot 也失败时交给 panic=10），不是 shell" \
	'while :; do /bin/busybox sleep 3600; done' "$DIE"

echo "== 看门狗：存在、够早、switch_root 前必须撤 =="
eq "看门狗时长 150s（给补挂 p1 留时间）" "P1_WDT_SECS='150'" "$(grep -E '^P1_WDT_SECS=' "$SRC" | head -n1)"
_wdt=$(printf '%s\n' "$TEXT" | sed -n '/^start_watchdog() {/,/^}/p')
contains "看门狗在后台子 shell 里跑（WDT_PID=\$!）" 'WDT_PID=$!' "$_wdt"
contains "看门狗到点 reboot -f" 'reboot -f' "$_wdt"
contains "看门狗 sleep 用 P1_WDT_SECS" 'sleep "$P1_WDT_SECS"' "$_wdt"
contains "看门狗记录 fired 判读串" 'watchdog: fired' "$TEXT"
contains "看门狗触发时也删试跑标记（否则重启又撞同一条坏入口 = 重启循环）" 'drop_trial_marker' "$_wdt"
# H2 根因之二：不要靠"日志文件已存在"来判断 p1 挂没挂（首次试跑时文件还不存在）
_ens_body=$(fn_body ensure_bootlog)
contains "ensure_bootlog 先看 /proc/mounts 里 \$P1_PART_DIR 是否已挂" 'grep -q " ${P1_PART_DIR} " /proc/mounts' "$_ens_body"
not_contains "ensure_bootlog 不再要求日志文件已存在" 'if [ -f "$P1_LOG" ]; then
		LOG_READY=1' "$_ens_body"
contains "看门狗先自救补挂 p1（与 die 同第一步；卡死常发生在 p1 挂载之前）" 'ensure_bootlog' "$_wdt"
_wd_ens=$(printf '%s\n' "$_wdt" | grep -n 'ensure_bootlog' | head -n1 | cut -d: -f1)
_wd_drop=$(printf '%s\n' "$_wdt" | grep -n 'drop_trial_marker' | head -n1 | cut -d: -f1)
if [ -n "$_wd_ens" ] && [ -n "$_wd_drop" ] && [ "$_wd_ens" -lt "$_wd_drop" ]; then
	ok "看门狗里 补挂(${_wd_ens}) 早于 删标记(${_wd_drop})"
else
	bad "看门狗没有先补挂再删标记（ensure=${_wd_ens} drop=${_wd_drop}）"
fi
_wd_mk=$(printf '%s\n' "$_wdt" | grep -n 'drop_trial_marker' | head -n1 | cut -d: -f1)
_wd_rb=$(printf '%s\n' "$_wdt" | grep -n 'busybox reboot -f' | grep -v 'busybox echo' | head -n1 | cut -d: -f1)
if [ -n "$_wd_mk" ] && [ -n "$_wd_rb" ] && [ "$_wd_mk" -lt "$_wd_rb" ]; then
	ok "看门狗里 删标记($_wd_mk) 早于 reboot($_wd_rb)"
else
	bad "看门狗里没有先删标记（drop=$_wd_mk reboot=${_wd_rb}）"
fi
contains "stop_watchdog 用 kill \$WDT_PID" 'kill "$WDT_PID"' "$TEXT"
_w_arm=$(ln_of 'start_watchdog$')
_w_kill=$(ln_of 'stop_watchdog$')
_w_sw=$(ln_of 'exec /bin/busybox switch_root')
_modp=$(ln_of '/sbin/modprobe btrfs')
if [ -n "$_w_arm" ] && [ -n "$_modp" ] && [ "$_w_arm" -lt "$_modp" ]; then
	ok "看门狗在模块加载之前就上（$_w_arm < modprobe ${_modp}），覆盖 modprobe 卡死"
else
	bad "看门狗没有早于 modprobe（arm=$_w_arm modprobe=${_modp}）"
fi
if [ -n "$_w_kill" ] && [ -n "$_w_sw" ] && [ "$_w_kill" -lt "$_w_sw" ]; then
	ok "switch_root($_w_sw) 之前撤看门狗($_w_kill)"
else
	bad "看门狗没有在 switch_root 前撤（kill=$_w_kill switch_root=${_w_sw}）"
fi

echo "== cmdline 参数（键名与 grub 模板一致）=="
for _k in phase1_dev phase1_boot phase1_lower phase1_overlay; do
	if grep -q -- "cmdline_get $_k" "$SRC"; then ok "支持 cmdline 键 $_k"; else bad "缺少 cmdline 键 $_k"; fi
done
contains "默认值 phase1_dev 来自占位符 @ROOTDEV@" "DEF_DEV='@ROOTDEV@'" "$TEXT"
contains "默认值 phase1_boot 来自占位符 @BOOTDEV@" "DEF_BOOT='@BOOTDEV@'" "$TEXT"
contains "默认值 phase1_lower 来自占位符 @LOWER@" "DEF_LOWER='@LOWER@'" "$TEXT"
contains "默认值 phase1_overlay 来自占位符 @OVL@" "DEF_OVL='@OVL@'" "$TEXT"
eq "rootwait 不作为 mount 选项/参数出现（禁入 cmdline）" '0' \
	"$(grep -v '^[[:space:]]*#' "$SRC" | grep -cE 'mount.*rootwait|rootwait,' | tr -d ' ')"
contains "rootwait 命中时直接 die（不带着它继续启动）" 'die cmdline "cmdline 出现 rootwait' "$TEXT"
contains "rootwait 检查是 cmdline 的 case 分支" '*" rootwait "*)' "$TEXT"
not_contains "没有任何 mount 带 rootwait" 'rootwait,' "$TEXT"

echo "== 模块加载：只用 /sbin/modprobe =="
contains "加载 btrfs 用 /sbin/modprobe" '/sbin/modprobe btrfs' "$TEXT"
not_contains "不调 kmodloader（rc=0 的静默假成功）" '/sbin/kmodloader' "$TEXT"
not_contains "不自己 insmod 单个 ko" '/sbin/insmod' "$TEXT"
contains "加载后用 /proc/modules 硬断言" "grep -q '^btrfs ' /proc/modules" "$TEXT"
contains "带 vfat（写 p1 日志必需）" '/sbin/modprobe vfat' "$TEXT"
for _n in nls_cp437 nls_iso8859-1 nls_utf8; do
	contains "带 $_n" "/sbin/modprobe $_n" "$TEXT"
done

echo "== CONFIG_DEVTMPFS=n：tmpfs /dev + mknod =="
contains "mount -t tmpfs /dev" 'mount -t tmpfs tmpfs /dev' "$TEXT"
contains "mknod /dev/console 5 1" 'mknode 600 /dev/console 5 1' "$TEXT"
contains "块设备号优先读 /sys/class/block" '/sys/class/block/' "$TEXT"
contains "归档外造 ROOTDEV 节点" 'mkblkdev 600 "$PHASE1_DEV"' "$TEXT"
contains "归档外造 BOOTDEV 节点" 'mkblkdev 600 "$PHASE1_BOOT"' "$TEXT"

echo "== overlay 参数串（逐字，运行期判读的唯一依据）=="
eq "P1_OVL_OPTS 逐字" "P1_OVL_OPTS='lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work'" \
	"$(grep -E '^P1_OVL_OPTS=' "$SRC" | head -n1)"
contains "用该串挂 overlay" 'mount -t overlay -o "$P1_OVL_OPTS" overlay "$P1_NEWROOT"' "$TEXT"
eq "代码里只有一处 lowerdir=（单一真相，注释不计）" '1' \
	"$(grep -v '^[[:space:]]*#' "$SRC" | grep -c 'lowerdir=' | tr -d ' ')"

echo "== M6：判据串与 files/lib/preinit/80_mount_root 必须一致（改一处忘另一处 = fail-open）=="
# 判据两边各存一份：/init 挂 overlay 时用的串 vs 80_mount_root 认的串。任一侧改了另一侧没跟上，
# 80_mount_root 就会认不出我们的根 ⇒ 回到 ramoverlay() 的静默假阳性。这里交叉断言。
PREINIT=$REPO/files/lib/preinit/80_mount_root
if [ -f "$PREINIT" ]; then
	PTEXT=$(cat "$PREINIT")
	# 从 /init 的 P1_OVL_OPTS 里解析出三个路径（不抄字面量：改了 /init 这边会跟着变）
	_ovl_raw=$(grep -E '^P1_OVL_OPTS=' "$SRC" | head -n1 | sed -e "s/^P1_OVL_OPTS=//" -e "s/^'//" -e "s/'$//")
	_lower=$(printf '%s' "$_ovl_raw" | tr ',' '\n' | sed -n 's/^lowerdir=//p')
	_upper=$(printf '%s' "$_ovl_raw" | tr ',' '\n' | sed -n 's/^upperdir=//p')
	_work=$(printf '%s' "$_ovl_raw" | tr ',' '\n' | sed -n 's/^workdir=//p')
	eq "从 /init 解析出 lowerdir" '/lower' "$_lower"
	eq "从 /init 解析出 upperdir" '/overlay/upper' "$_upper"
	eq "从 /init 解析出 workdir" '/overlay/work' "$_work"
	contains "80_mount_root 认的 lowerdir 与 /init 用的是同一个（${_lower}）" "lowerdir=$_lower" "$PTEXT"
	contains "80_mount_root 认的 upperdir 与 /init 用的是同一个（${_upper}）" "upperdir=$_upper" "$PTEXT"
	# 反过来也断言：80_mount_root 代码里出现的取值集合只许是 /init 用的那一个
	# （注释不算；`lowerdir=/lower:` 是"允许多 lower 列表首项"的变体，属设计内）。
	_p_code=$(printf '%s\n' "$PTEXT" | grep -v '^[[:space:]]*#')
	_pre_lower=$(printf '%s\n' "$_p_code" | grep -oE 'lowerdir=[^,*[:space:]]+' | LC_ALL=C sort -u | tr '\n' ' ')
	_pre_upper=$(printf '%s\n' "$_p_code" | grep -oE 'upperdir=[^,*[:space:]]+' | LC_ALL=C sort -u | tr '\n' ' ')
	eq "80_mount_root 代码里的 lowerdir 取值集合 = {/lower, /lower:}（多 lower 首项变体）" \
		'lowerdir=/lower lowerdir=/lower: ' "$_pre_lower"
	eq "80_mount_root 代码里的 upperdir 取值集合 = {${_upper}}（与 /init 同一个）" \
		"upperdir=$_upper " "$_pre_upper"
else
	bad "缺少 ${PREINIT}（判据交叉断言无从比较）"
fi

echo "== /lower：ro 挂载 + 实际不可写断言 =="
contains "lower 以 ro 挂载" 'subvol=$PHASE1_LOWER_SUBVOL,ro,noatime' "$TEXT"
contains "ro 的 /lower 不加 compress（只读，没意义）" 'subvol=$PHASE1_LOWER_SUBVOL,ro,noatime' "$TEXT"
eq "ro 的 /lower 挂载串里没有 compress" '0' \
	"$(printf '%s\n' "$TEXT" | grep -v '^[[:space:]]*#' | grep -c 'LOWER_SUBVOL,ro,noatime,compress' | tr -d ' ')"

echo "== M4：rw 子卷必须带 compress=zstd:1（跳过 mount_root 后 fstab 不再生效）=="
contains "@overlay(rw) 挂载串带 compress=zstd:1" \
	'mount -t btrfs -o "subvol=$PHASE1_OVL_SUBVOL,noatime,compress=zstd:1"' "$TEXT"
contains "搬运用二次挂载（rw 分支）也带 compress=zstd:1" '_opts="subvol=$_sv,noatime,compress=zstd:1"' "$TEXT"
contains "@docker/@swap（mount_optional）也带 compress=zstd:1" \
	'mount -t btrfs -o "subvol=$1,noatime,compress=zstd:1"' "$TEXT"
contains "注释写明 move/bind 会保留挂载选项（新系统继承压缩）" '新系统里的 /overlay 直接继承' "$TEXT"

echo "== M4'：btrfs 参数是 sb 级 —— 顺序必须 @overlay 先于 @root，且必须读回断言 =="
# 真机复验发现：代码里有 compress=zstd:1 但实际没生效 —— 因为首次挂载的是 /lower（无 compress），
# sb 级参数就定死了，之后带 compress 的挂载被静默忽略。所以这里断言两件事：
#   ① 结构性：@overlay 的 mount 行号必须小于 @root(/lower) 的 mount 行号
#   ② 运行时：/init 必须从 /proc/mounts 读回 compress=zstd:1，失败即 die stage=compress
contains "注释把 sb 级写成坑（顺序不能反）" 'superblock 级' "$TEXT"
contains "注释点名「顺序不能反」" '**顺序不能反**' "$TEXT"
_ovl_m=$(grep -n 'subvol=\$PHASE1_OVL_SUBVOL,noatime,compress=zstd:1" "\$PHASE1_DEV" "\$P1_OVL_DIR"' "$SRC" | head -n1 | cut -d: -f1)
_low_m=$(grep -n 'subvol=\$PHASE1_LOWER_SUBVOL,ro,noatime" "\$PHASE1_DEV" "\$P1_LOWER_DIR"' "$SRC" | head -n1 | cut -d: -f1)
if [ -n "$_ovl_m" ] && [ -n "$_low_m" ] && [ "$_ovl_m" -lt "$_low_m" ]; then
	ok "@overlay 的挂载($_ovl_m) 早于 @root($_low_m)：sb 级参数由首次挂载决定"
else
	bad "挂载顺序反了（overlay=${_ovl_m} lower=${_low_m}）—— btrfs 参数是 sb 级，compress 会被静默忽略"
fi
contains "挂完 @overlay 后从 /proc/mounts 读回挂载选项" 'done < /proc/mounts' "$TEXT"
contains "读回断言要求 compress=zstd:1" '*compress=zstd:1*)' "$TEXT"
contains "读不到即 die stage=compress" 'die compress' "$TEXT"
eq "读回断言是硬失败（不是告警）" '1' \
	"$(grep -c 'die compress' "$SRC" | tr -d ' ')"
contains "断言 openwrt_release 存在（子卷选对）" 'etc/openwrt_release" ]' "$TEXT"
contains "ro 断言：touch 必须失败" 'touch "$P1_LOWER_DIR/.p1-ro-probe"' "$TEXT"
contains "可写即 die（ro 没生效）" 'die lower-readonly' "$TEXT"

echo "== 写入探针：必须落进 upper =="
contains "探针 touch 合成根" 'touch "$P1_NEWROOT/.p1-probe"' "$TEXT"
contains "断言落到 /overlay/upper/.p1-probe" '[ -f "$P1_OVL_DIR/upper/.p1-probe" ]' "$TEXT"
contains "没落到 upper 即 die" 'die probe-upper' "$TEXT"
contains "探针用完删掉" 'rm -f "$P1_NEWROOT/.p1-probe"' "$TEXT"

echo "== 搬运挂载：/lower -> /newroot/rom、/overlay -> /newroot/overlay =="
contains "先试 mount -o move" 'mount -o move "$_src" "$_dst"' "$TEXT"
contains "失败退化同子卷二次挂载" '二次挂载' "$TEXT"
contains "两次挂载都断言 rom/etc" '[ -d "$P1_NEWROOT/rom/etc" ]' "$TEXT"
contains "两次挂载都断言 overlay/upper" '[ -d "$P1_NEWROOT/overlay/upper" ]' "$TEXT"
contains "搬运后仍可写（N.9 未确认项）+ 断言" 'die post-move-probe' "$TEXT"
contains "@docker -> /opt/docker（存在才挂）" 'mount_optional "$PHASE1_DOCKER_SUBVOL" "$P1_NEWROOT/opt/docker" docker' "$TEXT"
contains "@swap -> /swap（存在才挂）" 'mount_optional "$PHASE1_SWAP_SUBVOL"   "$P1_NEWROOT/swap"       swap' "$TEXT"
contains "切根前断言 /sbin/init 可执行" '[ -x "$P1_NEWROOT/sbin/init" ]' "$TEXT"

echo "== 每个失败点都走 die()，阶段名稳定可 grep =="
# 阶段名是 tm-03 判读用的契约：改实现必须同步改这里（和 handoff.md 的表）
STAGES='mkdir proc sys dev console devnode cmdline modprobe bootlog compress lower-mount lower-release
	lower-readonly overlay-mount overlay-dirs overlay-root probe probe-upper
	rom-relocate overlay-relocate boot-relocate post-move-probe newroot-init switch-root'
_n_stage=0
for _s in $STAGES; do
	_n_stage=$((_n_stage + 1))
	if grep -qE "(die|relocate) $_s( |$)" "$SRC"; then
		ok "失败点 stage=$_s 走 die"
	else
		bad "缺少失败点 stage=$_s"
	fi
done
_n_die=$(grep -cE '(^|[[:space:];|&])die ' "$SRC")
if [ "$_n_die" -ge "$_n_stage" ]; then
	ok "die 调用 $_n_die 处 ≥ 阶段名 $_n_stage 个（每个失败点都有出口）"
else
	bad "die 调用只有 $_n_die 处，少于阶段名 $_n_stage 个"
fi
eq "阶段名不重复定义（日志可唯一判读）" "$_n_stage" \
	"$(printf '%s\n' $STAGES | sort -u | wc -l | tr -d ' ')"

echo "== 成功路径留痕 =="
contains "成功行逐字（tm-03 按它判成功）" 'initramfs: switching root upperdir=/overlay/upper' "$TEXT"
contains "成功前 sync" 'busybox sync' "$TEXT"
not_contains "不再在切根前 umount /boot（umount 后失败就没地方写日志/删标记）" \
	'umount "$P1_BOOT_DIR"' "$TEXT"
contains "切根前把 p1 的引导目录 bind 进新根（live 的 /boot = p1:/boot）" \
	'mount -o bind "$P1_BOOT_DIR" "$P1_NEWROOT/boot"' "$TEXT"
contains "bind 之后断言新根里能看到日志" '[ -f "$P1_NEWROOT/boot/phase1-boot.log" ]' "$TEXT"
contains "bind 失败退化为再挂一次 p1" 'mount -t vfat -o rw,noatime "$PHASE1_BOOT" "$P1_NEWROOT/boot"' "$TEXT"
not_contains "子目录搬挂载不再硬用 mount -o move（move 只能搬挂载点）" \
	'relocate boot-relocate' "$TEXT"
contains "切根前摘掉 p1 根那次挂载（避免删旧根撞 EBUSY）" 'umount "$P1_PART_DIR"' "$TEXT"
_mk_line=$(ln_of '^drop_trial_marker$')
_boot_line=$(ln_of '^relocate_boot$')
if [ -n "$_mk_line" ] && [ -n "$_boot_line" ] && [ "$_mk_line" -lt "$_boot_line" ]; then
	ok "删标记($_mk_line) 早于搬 p1($_boot_line)：搬之前路径唯一、不会被搬走后找不到"
else
	bad "删标记没有早于搬 p1（marker=${_mk_line} boot=${_boot_line}）"
fi
contains "成功切根前有「删标记」的 info 行" 'info 切根前删除试跑标记（成功即一次性）' "$TEXT"
_succ_mk=$(ln_of '^drop_trial_marker$')
_succ_sw=$(ln_of 'exec /bin/busybox switch_root')
if [ -n "$_succ_mk" ] && [ -n "$_succ_sw" ] && [ "$_succ_mk" -lt "$_succ_sw" ]; then
	ok "成功路径 drop_trial_marker($_succ_mk) 早于 exec switch_root($_succ_sw)"
else
	bad "成功路径没有在 switch_root 前删标记（drop=$_succ_mk switch_root=${_succ_sw}）"
fi
if [ -f "$MK" ]; then
	_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sb-semantics.XXXXXX") || { bad "mktemp 失败"; _TMP=''; }
	if [ -n "$_TMP" ]; then
		if sh "$MK" --render-init-only "$_TMP/init" >"$_TMP/render.log" 2>&1; then
			ok "make-initramfs.sh --render-init-only 渲染成功"
		else
			bad "--render-init-only 失败：$(tail -2 "$_TMP/render.log" | tr '\n' ' ')"
		fi
		if sh -n "$_TMP/init" 2>/dev/null; then ok "渲染后 sh -n 通过"; else bad "渲染后语法错误"; fi
		eq "渲染后无 @大写@ 占位符" '' "$(grep -Eo '@[A-Z][A-Z0-9_]*@' "$_TMP/init" 2>/dev/null | sort -u | tr '\n' ' ')"
		contains "渲染后仍保留 overlay 参数串" 'lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work' "$(cat "$_TMP/init")"
		not_contains "渲染后仍不落交互 shell" 'exec /bin/busybox sh' "$(cat "$_TMP/init")"
		rm -rf "$_TMP"
	fi
fi

finish PHASE1-INIT-SEMANTICS
