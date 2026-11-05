#!/bin/sh
# ac-7：swapfile 落在 @swap 子卷（/swap/swapfile），apply 的步骤顺序必须是
#   读配置 → 目标目录存在（= @swap 已挂）→ 空间够（size+64MiB）→ 建空文件并置 NOCOW
#   → 写入/mkswap → swapon **成功之后**才写 /etc/fstab；
# 任何一步失败都不留半成品、不写 fstab（backlog C6：半成品 swapfile 会让下次 apply 卡死）。
#
# 沙盒做法：
#   * uci 桩里的 `option file` 指向 $SB_ROOT 下（真机路径 /swap/swapfile 由静态断言守）；
#   * df/chattr/lsattr/swapon/swapoff/fallocate/mkswap/sysctl 全部用假件，可注入退出码；
#   * /proc/mounts 与 /proc/swaps 用 PROC_MOUNTS / PROC_SWAPS 指向 fixture（25.12 没有 findmnt）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

SWCTL="$REPO/files/usr/sbin/swapctl"
SWCONF="$REPO/files/etc/config/swap"

echo "== 静态：默认路径与配置都指向 @swap 内的 /swap/swapfile =="
if grep -qF "option file '/swap/swapfile'" "$SWCONF"; then
	ok "files/etc/config/swap 的 file 是 /swap/swapfile"
else
	bad "files/etc/config/swap 的 file 不是 /swap/swapfile"
fi
if grep -qF '/swap/swapfile' "$SWCTL"; then
	ok "swapctl 的缺省 file 也是 /swap/swapfile"
else
	bad "swapctl 的缺省 file 不是 /swap/swapfile"
fi
if grep -qE 'mkswap[[:space:]]+/dev/' "$SWCTL"; then
	bad "swapctl 对块设备 mkswap（只用 swapfile）"
else
	ok "swapctl 不对块设备 mkswap"
fi

# 假外部命令：只实现被测脚本用到的契约，副作用都落进 $SB_CMDS
mkfake() { # <名字>；stdin 是脚本体
	{ printf '#!/bin/sh\n'; cat; } >"$SB_ROOT/bin/$1"
	chmod +x "$SB_ROOT/bin/$1"
}

install_fakes() { # 每个用例都装一遍（sb_new 会换 SB_ROOT）
mkfake df <<'EOS'
printf '%s\n' 'Filesystem 1M-blocks Used Available Capacity Mounted on'
printf '/dev/fake 102400 1000 %s 1%% %s\n' "${SB_DF_AVAIL:-102400}" "${SB_SWAP_DIR:-/swap}"
EOS
mkfake swapon <<'EOS'
printf 'swapon %s\n' "$*" >>"$SB_CMDS"
exit "${SB_SWAPON_RC:-0}"
EOS
mkfake swapoff <<'EOS'
printf 'swapoff %s\n' "$*" >>"$SB_CMDS"
exit 0
EOS
mkfake chattr <<'EOS'
printf 'chattr %s\n' "$*" >>"$SB_CMDS"
exit "${SB_CHATTR_RC:-0}"
EOS
mkfake lsattr <<'EOS'
printf 'lsattr %s\n' "$*" >>"$SB_CMDS"
printf '%s %s\n' "${SB_LSATTR_FLAGS:--C--------------}" "${2:-}"
exit 0
EOS
mkfake fallocate <<'EOS'
printf 'fallocate %s\n' "$*" >>"$SB_CMDS"
[ "${SB_FALLOCATE_RC:-0}" = 0 ] || exit "${SB_FALLOCATE_RC}"
p=
for a in "$@"; do case "$a" in -*) ;; *) p=$a ;; esac; done
[ -n "$p" ] && : >"$p"
exit 0
EOS
mkfake dd <<'EOS'
printf 'dd %s\n' "$*" >>"$SB_CMDS"
[ "${SB_DD_RC:-0}" = 0 ] || exit "${SB_DD_RC}"
of=
for a in "$@"; do case "$a" in of=*) of=${a#of=} ;; esac; done
[ -n "$of" ] && : >"$of"
exit 0
EOS
mkfake mkswap <<'EOS'
printf 'mkswap %s\n' "$*" >>"$SB_CMDS"
exit "${SB_MKSWAP_RC:-0}"
EOS
mkfake sysctl <<'EOS'
exit 0
EOS
}

fstab_count() { # 目标路径在 fstab 里出现几次
	_c=$(grep -cF "$SW" "$FSTAB" 2>/dev/null || true)
	printf '%s' "${_c:-0}"
}
exists() { [ -e "$1" ] && echo yes || echo no; }

setup() { # <用例名> <size_mb>
	sb_new "$1"
	SWDIR=$SB_ROOT/swap
	SW=$SWDIR/swapfile
	FSTAB=$SB_ROOT/etc/fstab
	CMDS=$SB_ROOT/cmds.log
	OUT=$SB_ROOT/out.log
	MOUNTS=$SB_ROOT/proc.mounts
	SWAPS=$SB_ROOT/proc.swaps
	mkdir -p "$SB_ROOT/etc/sysctl.d"
	: >"$FSTAB"; : >"$CMDS"; : >"$SWAPS"; : >"$MOUNTS"
	export SB_CMDS=$CMDS SB_SWAP_DIR=$SWDIR PROC_MOUNTS=$MOUNTS PROC_SWAPS=$SWAPS
	printf '%s\n' '/dev/root / squashfs ro,relatime 0 0' >"$MOUNTS"
	# uci 桩：swap 配置（file 指向沙盒，等价于真机 /swap/swapfile）
	printf "config swap 'globals'\n\toption enabled '1'\n\toption file '%s'\n\toption size_mb '%s'\n\toption swappiness '20'\n\toption zram '0'\n" \
		"$SW" "${2:-4096}" >"$UCI_STUB_DIR/swap"
	install_fakes
	S=$(sb_script "$SWCTL" usr/sbin/swapctl)
}

run_apply() { # 运行被测脚本，返回退出码（stdout+stderr 收进 ）
	rc=0
	sh "$S" apply >"$OUT" 2>&1 || rc=$?
	printf '%s' "$rc"
}

echo "== @swap 未挂（目标目录不存在）→ 明确报错、不建文件、不写 fstab =="
setup notmounted 4096
rc=$(run_apply)
ne "apply 退出非 0" 0 "$rc"
contains "报错点名 @swap 未挂" '@swap' "$(cat "$OUT")"
eq "没有创建 swapfile" no "$(exists "$SW")"
eq "没有写 fstab" 0 "$(fstab_count)"
not_contains "未调用 swapon" 'swapon ' "$(cat "$CMDS")"

echo "== 空间不足（可用 < size+64MiB）→ 退出非 0、不建文件、不写 fstab =="
setup nospace 4096
mkdir -p "$SWDIR"
rc=$(SB_DF_AVAIL=3000 run_apply)
ne "空间不足时退出非 0" 0 "$rc"
contains "提示需要 size+64MiB" '64' "$(cat "$OUT")"
eq "空间不足时没有创建 swapfile" no "$(exists "$SW")"
eq "空间不足时没有写 fstab" 0 "$(fstab_count)"
not_contains "空间不足时未调用 swapon" 'swapon ' "$(cat "$CMDS")"

echo "== fallocate 不可用时回退 dd（原行为保留）=="
setup fallocate-fallback 4096
mkdir -p "$SWDIR"
rc=$(SB_FALLOCATE_RC=1 run_apply)
eq "回退 dd 后仍退出 0" 0 "$rc"
contains "确实走了 dd 回退" 'dd if=/dev/zero' "$(cat "$CMDS")"
eq "回退路径也写了 fstab" 1 "$(fstab_count)"

echo "== 分配彻底失败（fallocate 与 dd 都失败）→ 退出非 0、清掉半成品、不写 fstab =="
setup allocfail 4096
mkdir -p "$SWDIR"
rc=$(SB_FALLOCATE_RC=1 SB_DD_RC=1 run_apply)
ne "分配失败时退出非 0" 0 "$rc"
eq "分配失败后不留半成品" no "$(exists "$SW")"
eq "分配失败时不写 fstab" 0 "$(fstab_count)"

echo "== mkswap 失败 → 退出非 0、清掉半成品、不写 fstab =="
setup mkswapfail 4096
mkdir -p "$SWDIR"
rc=$(SB_MKSWAP_RC=1 run_apply)
ne "mkswap 失败时退出非 0" 0 "$rc"
eq "mkswap 失败后不留半成品" no "$(exists "$SW")"
eq "mkswap 失败时不写 fstab" 0 "$(fstab_count)"

echo "== swapon 失败 → 退出非 0、清掉半成品、不写 fstab =="
setup swaponfail 4096
mkdir -p "$SWDIR"
rc=$(SB_SWAPON_RC=1 run_apply)
ne "swapon 失败时退出非 0" 0 "$rc"
eq "swapon 失败后不留半成品" no "$(exists "$SW")"
eq "swapon 失败时不写 fstab" 0 "$(fstab_count)"

echo "== 成功 → fstab 恰好写一次；再 apply 不重复追加 =="
setup ok 4096
mkdir -p "$SWDIR"
rc=$(run_apply)
eq "apply 退出 0" 0 "$rc"
eq "swapfile 已创建" yes "$(exists "$SW")"
eq "fstab 有 1 行" 1 "$(fstab_count)"
contains "fstab 行内容正确" "$SW none swap sw 0 0" "$(cat "$FSTAB")"
rc=$(run_apply)
eq "重复 apply 仍退出 0" 0 "$rc"
eq "重复 apply 后 fstab 仍是 1 行" 1 "$(fstab_count)"

echo "== btrfs：已带 C（继承 @swap 根目录）则不重复 chattr =="
setup btrfs-nocow 4096
mkdir -p "$SWDIR"
printf '/dev/sda3 %s btrfs rw,noatime 0 0\n' "$SWDIR" >>"$MOUNTS"
rc=$(SB_LSATTR_FLAGS='-------C--------------' run_apply)
eq "apply 退出 0" 0 "$rc"
not_contains "已有 C 时不再 chattr" 'chattr ' "$(cat "$CMDS")"

echo "== btrfs：缺 C 时补 chattr +C，并在置标志后才写入数据 =="
setup btrfs-nocow-missing 4096
mkdir -p "$SWDIR"
printf '/dev/sda3 %s btrfs rw,noatime 0 0\n' "$SWDIR" >>"$MOUNTS"
rc=$(SB_LSATTR_FLAGS='----------------------' run_apply)
eq "apply 退出 0" 0 "$rc"
contains "补设了 chattr +C" "chattr +C" "$(cat "$CMDS")"
# 顺序：chattr 必须在 fallocate/mkswap 之前（NOCOW 只对新分配的 extent 生效）
first_data=$(grep -nE '^(fallocate|mkswap) ' "$CMDS" | head -1 | cut -d: -f1)
nocow=$(grep -n '^chattr +C' "$CMDS" | head -1 | cut -d: -f1)
if [ -n "$nocow" ] && [ -n "$first_data" ] && [ "$nocow" -lt "$first_data" ]; then
	ok "chattr +C 早于 fallocate/mkswap"
else
	bad "chattr +C 必须在写入数据前执行（nocow=${nocow} first_data=${first_data}）"
fi

echo "== 非 btrfs（没有 btrfs 挂载）→ 不碰 chattr =="
setup non-btrfs 4096
mkdir -p "$SWDIR"
rc=$(run_apply)
eq "apply 退出 0" 0 "$rc"
not_contains "非 btrfs 不调用 chattr" 'chattr ' "$(cat "$CMDS")"

echo "== @swap 未挂时 resize → 失败但不先毁掉现有 swapfile =="
# 模拟"@swap 未挂"：目录不可见（数据还在盘上），旧 swapfile 是当前正在用的那个。
# 反例（修复前的行为）：先 swapoff + rm -f 再 apply，等于把还能用的 swap 弄丢。
setup resize-guard 4096
mkdir -p "$SWDIR"
: >"$SW"                                         # 现有 swapfile（4096M）
mv "$SWDIR" "$SB_ROOT/swap-unmounted"            # @swap 未挂：/swap 不可见
size_before=$(uci -q get swap.globals.size_mb)
rc=0
sh "$S" resize 2048 >"$OUT" 2>&1 || rc=$?
ne "resize 退出非 0" 0 "$rc"
contains "resize 报错点名 @swap 未挂" '@swap' "$(cat "$OUT")"
eq "旧 swapfile 仍在（没被 rm 掉）" yes "$(exists "$SB_ROOT/swap-unmounted/swapfile")"
eq "size_mb 未被改动" "$size_before" "$(uci -q get swap.globals.size_mb)"
not_contains "resize 未调用 swapoff" 'swapoff ' "$(cat "$CMDS")"
not_contains "resize 未分配新 swapfile" 'fallocate ' "$(cat "$CMDS")"

echo "== @swap 已挂时 resize 正常工作（回归）=="
setup resize-ok 4096
mkdir -p "$SWDIR"
: >"$SW"
rc=0
sh "$S" resize 2048 >"$OUT" 2>&1 || rc=$?
eq "resize 退出 0" 0 "$rc"
eq "size_mb 已写入 2048" 2048 "$(uci -q get swap.globals.size_mb)"
contains "resize 先 swapoff 旧 swapfile" 'swapoff ' "$(cat "$CMDS")"

echo "== size_mb 非数字（4g）→ 拒绝，不进算术、不建文件、不写 fstab =="
setup badsize 4g
mkdir -p "$SWDIR"
rc=$(run_apply)
ne "退出非 0" 0 "$rc"
contains "报错点名 size_mb" 'size_mb' "$(cat "$OUT")"
not_contains "不是 ash 的算术语法错误（必须先校验再进算术）" 'arithmetic' "$(cat "$OUT")"
eq "没有创建 swapfile" no "$(exists "$SW")"
eq "没有写 fstab" 0 "$(fstab_count)"
not_contains "没有开始分配" 'fallocate ' "$(cat "$CMDS")"

echo "== size_mb = 0 → 拒绝 =="
setup zerosize 0
mkdir -p "$SWDIR"
rc=$(run_apply)
ne "size_mb=0 退出非 0" 0 "$rc"
eq "size_mb=0 不建文件" no "$(exists "$SW")"

echo "== resize 给非数字 → 拒绝且不改配置、不动现有 swapfile =="
setup badresize 4096
mkdir -p "$SWDIR"
: >"$SW"
size_before=$(uci -q get swap.globals.size_mb)
rc=0
sh "$S" resize 4g >"$OUT" 2>&1 || rc=$?
ne "resize 非数字退出非 0" 0 "$rc"
eq "size_mb 未被改动" "$size_before" "$(uci -q get swap.globals.size_mb)"
not_contains "resize 未 swapoff" 'swapoff ' "$(cat "$CMDS")"
eq "现有 swapfile 仍在" yes "$(exists "$SW")"

echo "== fstab 幂等必须整行匹配（前缀相同的另一个 swapfile 不能顶掉我们这条）=="
setup fstabprefix 4096
mkdir -p "$SWDIR"
printf '%s2 none swap sw 0 0\n' "$SW" >"$FSTAB"
rc=$(run_apply)
eq "apply 退出 0" 0 "$rc"
contains "写入了我们这条 swap 行" "$SW none swap sw 0 0" "$(cat "$FSTAB")"
eq "fstab 现在两行" 2 "$(wc -l <"$FSTAB" | tr -d ' ')"

finish SWAPCTL-SPACE
