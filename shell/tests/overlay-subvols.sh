#!/bin/sh
# ac-6：/etc/init.d/btrfs-subvols（START=12）挂 @docker/@swap/@data 的行为用例。
#
# 被测对象是 **/etc/rc.common 驱动的 init 脚本**，所以沙盒里放一个最小 rc.common 桩，
# 直接执行 $SB_ROOT/etc/init.d/btrfs-subvols start（与真机 rcS 的调用形态一致：
# shebang 是 `#!/bin/sh /etc/rc.common`，内核把脚本路径当 $1 传进去）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

setup() { # <tag>
	sb_new "subvols-$1"
	SB=$SB_ROOT
	mkdir -p "$SB/state" "$SB/opt" "$SB/etc/config"
	FAKE_LOG=$SB/calls.log
	: >"$FAKE_LOG"
	STATE=$SB/state
	export FAKE_LOG STATE
	printf '%s\n' /dev/sda3 >"$STATE/p3dev"
	MP=$STATE/mounts
	: >"$MP"

	# /etc/rc.common 桩：只做 initscript=$1; . "$initscript"; "$action"
	cat >"$SB/etc/rc.common" <<'EOS'
#!/bin/sh
_initscript=${1:-}
[ -n "$_initscript" ] || exit 1
shift
. "$_initscript"
[ -n "${1:-}" ] || set -- start
"$1"
EOS
	chmod +x "$SB/etc/rc.common"

	fake btrfs <<'EOS'
#!/bin/sh
echo "btrfs $*" >>"$FAKE_LOG"
case "$1 $2" in
'filesystem show')
	[ -f "$STATE/no_fs" ] && exit 1
	printf "Label: 'wrt-overlay'  uuid: 11111111-1111-1111-1111-111111111111\n"
	printf '\tTotal devices 1 FS bytes used 4.00MiB\n'
	printf '\tdevid    1 size 126.00GiB used 4.00GiB path %s\n' "$(cat "$STATE/p3dev")"
	exit 0
	;;
esac
exit 0
EOS
	# 挂的是假 /proc/mounts（真机就是它；25.12 源里没有 findmnt，不能用它判断"已挂载"）
	fake mount <<'EOS'
#!/bin/sh
echo "mount $*" >>"$FAKE_LOG"
last=''
for a in "$@"; do last=$a; done
printf '/dev/sda3 %s btrfs rw,noatime 0 0\n' "$last" >>"$PROC_MOUNTS"
exit 0
EOS
	fake lsattr <<'EOS'
#!/bin/sh
echo "lsattr $*" >>"$FAKE_LOG"
p=''
for a in "$@"; do p=$a; done
flags='----------------------'
if [ -f "$STATE/nocow" ] && grep -qx "$p" "$STATE/nocow"; then
	flags='---------------C------'
fi
printf '%s %s\n' "$flags" "$p"
exit 0
EOS
	fake chattr <<'EOS'
#!/bin/sh
echo "chattr $*" >>"$FAKE_LOG"
case "$1" in
+C|-C) shift ;;
esac
for p in "$@"; do printf '%s\n' "$p" >>"$STATE/nocow"; done
exit 0
EOS

	# /usr/sbin/swapctl 桩：swap 的自启现在由 btrfs-subvols 在 @swap 挂好之后接管
	cat >"$SB/usr/sbin/swapctl" <<'EOS'
#!/bin/sh
echo "swapctl $*" >>"$FAKE_LOG"
exit "${SB_SWAPCTL_RC:-0}"
EOS
	chmod +x "$SB/usr/sbin/swapctl"

	SB_INIT=$(sb_script "$REPO/files/etc/init.d/btrfs-subvols" etc/init.d/btrfs-subvols)
	SB_LOG=$SB/etc/config/btrfs-subvols.log
	DOCKER_DIR=$SB/opt/docker
	SWAP_DIR=$SB/swap
	DATA_DIR=$SB/data
	export DOCKER_DIR SWAP_DIR DATA_DIR
}

fake() { cat >"$SB/bin/$1"; chmod +x "$SB/bin/$1"; }

run_init() { # [动作]
	# 直接执行（不能 `sh 脚本`：那样 shebang 里的 /etc/rc.common 不会被 source，
	# 函数定义了却没人调用，等于什么都没测）
	DOCKER_DIR=$DOCKER_DIR SWAP_DIR=$SWAP_DIR DATA_DIR=$DATA_DIR \
		BTRFS_SUBVOLS_LOG=$SB_LOG PROC_MOUNTS=$MP "$SB_INIT" "${1:-start}"
}

mounts() { sed 's/[[:space:]]*$//' "$FAKE_LOG" | grep -E '^mount ' ; }
count() { if [ -f "$2" ]; then grep -c "$1" "$2" 2>/dev/null || true; else echo 0; fi; }

echo "== ① 正常：三个子卷各挂一次 =="
setup ok
rc=0
out=$(run_init) || rc=$?
eq "退出 0" '0' "$rc"
eq "挂载顺序与参数" "mount -t btrfs -o noatime,subvol=@docker /dev/sda3 $DOCKER_DIR
mount -t btrfs -o noatime,subvol=@swap /dev/sda3 $SWAP_DIR
mount -t btrfs -o noatime,subvol=@data /dev/sda3 $DATA_DIR" "$(mounts)"
not_contains "不带 nodatacow（fs 级参数只能由首次挂载决定）" 'nodatacow' "$(cat "$FAKE_LOG")"
eq "缺 C 时给 @docker 补设" '1' "$(count "chattr +C $DOCKER_DIR" "$FAKE_LOG")"
eq "缺 C 时给 @swap 补设" '1' "$(count "chattr +C $SWAP_DIR" "$FAKE_LOG")"
eq "@data 不设 NOCOW" '0' "$(count "chattr +C $DATA_DIR" "$FAKE_LOG")"
[ -d "$DOCKER_DIR" ] && ok "挂载点已创建" || bad "挂载点未创建"
contains "日志记下挂载结果" '@docker' "$(cat "$SB_LOG" 2>/dev/null)"
eq "挂完 @swap 调用了 swapctl apply" '1' "$(count '^swapctl apply' "$FAKE_LOG")"
mnt_swap=$(grep -nE "^mount .* ${SWAP_DIR}\$" "$FAKE_LOG" | head -1 | cut -d: -f1)
sw_line=$(grep -n '^swapctl apply' "$FAKE_LOG" | head -1 | cut -d: -f1)
if [ -n "$mnt_swap" ] && [ -n "$sw_line" ] && [ "$mnt_swap" -lt "$sw_line" ]; then
	ok "swapctl apply 在 @swap 挂载之后（顺序正确）"
else
	bad "swapctl apply 必须在 @swap 挂载之后（mount=${mnt_swap} swapctl=${sw_line}）"
fi

echo "== ② 幂等：已挂载（/proc/mounts 里有三条）则不再 mount =="
printf '/dev/sda3 %s btrfs rw,noatime 0 0\n' "$DOCKER_DIR" "$SWAP_DIR" "$DATA_DIR" >>"$MP"
before=$(count '^mount ' "$FAKE_LOG")
rc=0
out=$(run_init) || rc=$?
eq "重复执行退出 0" '0' "$rc"
eq "不重复挂载" "$before" "$(count '^mount ' "$FAKE_LOG")"

echo "== ③ C 标志已在：不再 chattr =="
setup nocow
printf '%s\n%s\n' "$DOCKER_DIR" "$SWAP_DIR" >"$STATE/nocow"
rc=0
out=$(run_init) || rc=$?
eq "退出 0" '0' "$rc"
eq "不重复 chattr" '0' "$(count '^chattr ' "$FAKE_LOG")"
eq "仍复核了两处（lsattr -d 各一次）" '2' "$(count '^lsattr -d ' "$FAKE_LOG")"

echo "== ④ p3 缺失：fail-closed（不挂空目录、exit 非 0）=="
setup nodev
: >"$STATE/no_fs"
rc=0
out=$(run_init) || rc=$?
ne "退出非 0" '0' "$rc"
eq "一个挂载都不做" '' "$(mounts)"
[ -d "$DOCKER_DIR" ] && bad "不应创建空挂载点 $DOCKER_DIR" || ok "没有留下空挂载点"
contains "日志记 ERROR" 'ERROR' "$(cat "$SB_LOG" 2>/dev/null)"

echo "== ⑤ 运行期不写 /etc/config/fstab =="
setup fstab
printf "config mount 'overlay'\n\toption target '/overlay'\n" >"$SB/etc/config/fstab"
sum=$(cksum "$SB/etc/config/fstab")
rc=0
out=$(run_init) || rc=$?
eq "退出 0" '0' "$rc"
eq "fstab 逐字节未变" "$sum" "$(cksum "$SB/etc/config/fstab")"
not_contains "脚本不调用 uci（fstab 只在 squashfs 里改）" 'uci ' "$(cat "$SB_INIT")"

echo "== ⑥ chattr 缺失（25.12 里 chattr 是独立 apk 包）：只记日志、exit 0 =="
setup nochattr
rm -f "$SB/bin/chattr"
rc=0
out=$(run_init) || rc=$?
eq "仍然 exit 0（不阻断 boot）" '0' "$rc"
contains "日志说明 chattr 缺失" 'chattr 包缺失' "$(cat "$SB_LOG" 2>/dev/null)"
eq "三个子卷照常挂载" '3' "$(count '^mount ' "$FAKE_LOG")"

echo "== ⑦ lsattr 缺失：无法复核，仍尝试 chattr +C 并继续 =="
setup nolsattr
rm -f "$SB/bin/lsattr"
rc=0
out=$(run_init) || rc=$?
eq "exit 0" '0' "$rc"
contains "日志记下无法复核" 'lsattr 包缺失' "$(cat "$SB_LOG" 2>/dev/null)"
eq "仍尝试给 @docker/@swap 设 C" '2' "$(count '^chattr ' "$FAKE_LOG")"

echo "== ⑧ 不依赖 findmnt（25.12.2 源里没有该包）=="
setup nofindmnt
rc=0
out=$(run_init) || rc=$?
eq "退出 0" '0' "$rc"
not_contains "不再有 FINDMNT 覆盖点" 'FINDMNT' "$(cat "$SB_INIT")"
eq "运行期一次都没调用 findmnt" '0' "$(count '^findmnt' "$FAKE_LOG")"

echo "== ⑨ swapctl 失败：只记 WARN，不改变 btrfs-subvols 的退出码 =="
setup swapctl-fail
rc=0
out=$(SB_SWAPCTL_RC=1 run_init) || rc=$?
eq "仍然 exit 0（子卷挂好了就算成功）" '0' "$rc"
contains "日志记下 swapctl 失败" 'swapctl' "$(cat "$SB_LOG" 2>/dev/null)"
eq "确实尝试过 swapctl" '1' "$(count '^swapctl apply' "$FAKE_LOG")"

echo "== ⑩ 顺序：99-custom（START=10）在 /swap 未挂时不硬失败、不调 swapctl =="
ud_setup() { # <tag> [是否已挂 /swap]
	sb_new "ud-$1"
	SB=$SB_ROOT
	sb_fixture net-anon
	sb_netports
	sb_initd
	SB_SYS=$(sb_sysfs eth0:0000:01:00.0 eth1:0000:02:00.0)
	NETPORTS_SYSFS=$SB_SYS
	export NETPORTS_SYSFS
	FAKE_LOG=$SB/calls.log
	: >"$FAKE_LOG"
	export FAKE_LOG
	UDMOUNTS=$SB/proc.mounts
	printf '/dev/root /rom squashfs ro,relatime 0 0\n' >"$UDMOUNTS"
	printf 'overlayfs:/overlay / overlay rw,noatime 0 0\n' >>"$UDMOUNTS"
	if [ "${2:-no}" = yes ]; then
		printf '/dev/sda3 /swap btrfs rw,noatime 0 0\n' >>"$UDMOUNTS"
		printf '/dev/sda3 /opt/docker btrfs rw,noatime 0 0\n' >>"$UDMOUNTS"
	fi
	cat >"$SB/usr/sbin/swapctl" <<'EOS'
#!/bin/sh
echo "swapctl $*" >>"$FAKE_LOG"
exit 0
EOS
	chmod +x "$SB/usr/sbin/swapctl"
	SB_UD=$(sb_script "$REPO/files/etc/uci-defaults/99-custom.sh" etc/uci-defaults/99-custom.sh)
	SB_UDLOG=$SB/etc/config/uci-defaults-log.txt
}

ud_setup noswap no
rc=0
PROC_MOUNTS=$UDMOUNTS NETPORTS_LOG=$SB/netports.log sh "$SB_UD" >/dev/null 2>&1 || rc=$?
eq "99-custom 退出 0（不因 @swap 未挂而硬失败）" '0' "$rc"
eq "没有调用 swapctl" '0' "$(count '^swapctl ' "$FAKE_LOG")"
contains "日志说明 swap 延后到 btrfs-subvols" 'deferred' "$(cat "$SB_UDLOG" 2>/dev/null)"

ud_setup hasswap yes
rc=0
PROC_MOUNTS=$UDMOUNTS NETPORTS_LOG=$SB/netports.log sh "$SB_UD" >/dev/null 2>&1 || rc=$?
eq "99-custom 退出 0" '0' "$rc"
eq "@swap 已挂时才调用 swapctl apply" '1' "$(count '^swapctl apply' "$FAKE_LOG")"

echo "== ⑪ 静态：99-custom 里不再有无条件的 swapctl apply =="
not_contains "已改成条件式（不再 && 硬跑）" '[ -x /usr/sbin/swapctl ] && /usr/sbin/swapctl apply' "$(cat "$REPO/files/etc/uci-defaults/99-custom.sh")"

finish OVERLAY-SUBVOLS
