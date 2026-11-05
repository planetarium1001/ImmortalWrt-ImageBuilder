#!/bin/sh
# ac-5：首启初始化 overlay-setup 的状态机（全离线：所有外部命令都被 fake 替换）。
#
# 覆盖 design §5 的 S0–S5，重点是三件真机不敢试的事：
#   1) 三步各自幂等——重复执行不重复 `sgdisk -n`、不重复 mkfs、不重复建子卷；
#   2) 就绪判据是"当前 /overlay 真的是 btrfs 且含 @overlay"，否则必须非 0 退出
#      以便 uci-defaults 下次开机重试（否则脚本被自删、从此静默跑在 p2 内部 overlay 上）；
#   3) 失败时不动 p2 的 overlay，只写日志。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

# ---------- 沙盒 + fake 工具 ----------
setup() { # <tag>
	sb_new "ovs-$1"
	SB=$SB_ROOT
	mkdir -p "$SB/proc" "$SB/sys/block/sda" "$SB/sys/dev/block/8:2" \
		"$SB/dev" "$SB/state" "$SB/rom" "$SB/overlay" "$SB/tmp"
	FAKE_LOG=$SB/calls.log
	: >"$FAKE_LOG"
	STATE=$SB/state
	export FAKE_LOG STATE
	printf '%s\n' "$SB/dev/sda3" >"$STATE/p3dev"

	# 真机 /proc/mounts 里 /rom 的设备是 bdev 别名 /dev/root（不含分区号），
	# 所以真实分区名只能从 mountinfo 的 maj:min → /sys/dev/block/<maj:min>/uevent 取。
	printf '/dev/root %s squashfs ro,relatime 0 0\n' "$SB/rom" >"$SB/proc/mounts"
	printf '36 1 8:2 / %s ro,relatime - squashfs /dev/root ro\n' "$SB/rom" >"$SB/proc/mountinfo"
	printf 'MAJOR=8\nMINOR=2\nDEVNAME=sda2\n' >"$SB/sys/dev/block/8:2/uevent"

	fake sgdisk <<'EOS'
#!/bin/sh
echo "sgdisk $*" >>"$FAKE_LOG"
[ -f "$STATE/sgdisk.fail" ] && exit 1
exit 0
EOS
	fake mkfs.btrfs <<'EOS'
#!/bin/sh
echo "mkfs.btrfs $*" >>"$FAKE_LOG"
lab=''
while [ $# -gt 0 ]; do
	case "$1" in
	-L) shift; lab=$1 ;;
	esac
	shift
done
printf '%s\n' "$lab" >"$STATE/label"
exit 0
EOS
	fake btrfs <<'EOS'
#!/bin/sh
echo "btrfs $*" >>"$FAKE_LOG"
case "$1 $2" in
'filesystem show')
	d=$3
	case "$d" in
	/*) : ;;
	*) d=$(cat "$STATE/p3dev" 2>/dev/null) ;;
	esac
	if [ -f "$STATE/label" ]; then
		printf "Label: '%s'  uuid: 11111111-1111-1111-1111-111111111111\n" "$(cat "$STATE/label")"
		printf '\tTotal devices 1 FS bytes used 4.00MiB\n'
		printf '\tdevid    1 size 126.00GiB used 4.00GiB path %s\n' "$d"
		exit 0
	fi
	echo 'No btrfs filesystem found' >&2
	exit 1
	;;
'subvolume list')
	[ -f "$STATE/subvols" ] || exit 0
	awk '{ printf "ID %d gen 10 top level 5 path %s\n", 255 + NR, $0 }' "$STATE/subvols"
	exit 0
	;;
'subvolume create')
	mkdir -p "$3" || exit 1
	printf '%s\n' "${3##*/}" >>"$STATE/subvols"
	exit 0
	;;
'filesystem label')
	printf '%s\n' "$4" >"$STATE/label"
	exit 0
	;;
esac
exit 1
EOS
	fake partx <<'EOS'
#!/bin/sh
echo "partx $*" >>"$FAKE_LOG"
# 模拟"内核通知 udev/devtmpfs 之后分区节点出现"
: >"$SYS_BLOCK/sda/sda3"
exit 0
EOS
	# 挂的是假 /proc/mounts（真机上就是它），不再有 findmnt 桩：25.12 源里没有 findmnt
	fake mount <<'EOS'
#!/bin/sh
echo "mount $*" >>"$FAKE_LOG"
last=''
for a in "$@"; do last=$a; done
printf '/dev/root %s btrfs rw,noatime 0 0\n' "$last" >>"$PROC_MOUNTS"
exit 0
EOS
	fake umount <<'EOS'
#!/bin/sh
echo "umount $*" >>"$FAKE_LOG"
last=''
for a in "$@"; do last=$a; done
awk -v t="$last" '$2 != t' "$PROC_MOUNTS" >"$PROC_MOUNTS.new" 2>/dev/null
mv "$PROC_MOUNTS.new" "$PROC_MOUNTS" 2>/dev/null
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
	fake reboot <<'EOS'
#!/bin/sh
echo "reboot $*" >>"$FAKE_LOG"
exit 0
EOS
	fake sync <<'EOS'
#!/bin/sh
echo "sync $*" >>"$FAKE_LOG"
exit 0
EOS
	fake logger <<'EOS'
#!/bin/sh
echo "logger $*" >>"$FAKE_LOG"
echo "$*" >>"$STATE/logread"
exit 0
EOS
	: >"$SB/kmsg"

	SB_SETUP=$(sb_script "$REPO/files/usr/sbin/overlay-setup" usr/sbin/overlay-setup)
	SB_LOG=$SB/etc/config/overlay-setup.log
}

fake() { # <名字>：stdin 写成 $SB/bin/<名字>
	cat >"$SB/bin/$1"
	chmod +x "$SB/bin/$1"
}

run_setup() {
	PROC_MOUNTS=$SB/proc/mounts \
		PROC_MOUNTINFO=$SB/proc/mountinfo \
		SYS_BLOCK=$SB/sys/block \
		SYS_DEV_BLOCK=$SB/sys/dev/block \
		DEV_DIR=$SB/dev \
		ROM_DIR=$SB/rom \
		OVERLAY_DIR=$SB/overlay \
		TOPLEVEL_MNT=$SB/tmp/top \
		KMSG=$SB/kmsg \
		SLEEP=true \
		sh "$SB_SETUP" "$@"
}

# 只留"会改盘/改配置"的外部调用（读探测被排除，否则断言绑死在实现细节上）
mutating() {
	sed 's/[[:space:]]*$//' "$FAKE_LOG" |
		grep -E '^(sgdisk|partx|mkfs\.btrfs|mount|umount|chattr|sync|reboot)( |$)|^btrfs subvolume create '
}

mnt_add() { # <挂载点> <fstype>：往假 /proc/mounts 里加一条（模拟"已经挂好"）
	printf '/dev/sda3 %s %s rw,noatime 0 0\n' "$1" "$2" >>"$SB/proc/mounts"
}

count() { # <模式> <文件>：匹配条数（文件不存在算 0）
	if [ -f "$2" ]; then
		grep -c "$1" "$2" 2>/dev/null || true
	else
		echo 0
	fi
}

same_list() { # <描述> <期望> <实际>
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		bad "$1"
		printf '       期望:\n%s\n' "$2"
		printf '       实际:\n%s\n' "$3"
	fi
}

echo "== ① 全新建盘：p3 不存在 / 非 btrfs / 无子卷 =="
setup new
rc=0
out=$(run_setup) || rc=$?
eq "退出 2（已下发重启；只有真正切到 @overlay 才允许 exit 0）" '2' "$rc"
contains "说明保留重试语义" '下次开机重试' "$(cat "$SB_LOG" 2>/dev/null)"
same_list "写操作序列" "$(cat <<EOS
sgdisk -e $SB/dev/sda
sgdisk -n 3:0:0 -t 3:8300 -c 3:wrt-overlay $SB/dev/sda
partx -a $SB/dev/sda
mkfs.btrfs -L wrt-overlay -f $SB/dev/sda3
mount -t btrfs -o subvolid=5,noatime $SB/dev/sda3 $SB/tmp/top
btrfs subvolume create $SB/tmp/top/@overlay
btrfs subvolume create $SB/tmp/top/@docker
btrfs subvolume create $SB/tmp/top/@swap
btrfs subvolume create $SB/tmp/top/@data
chattr +C $SB/tmp/top/@docker
chattr +C $SB/tmp/top/@swap
umount $SB/tmp/top
sync
reboot
EOS
)" "$(mutating)"
not_contains "partx 不带 -u（-a -u 互斥）" 'partx -a -u' "$(cat "$FAKE_LOG")"
contains "日志记下 p3 建好" 'wrt-overlay' "$(cat "$SB_LOG" 2>/dev/null)"
eq "@data 不做 chattr +C" '0' "$(count '@data' "$STATE/nocow")"
contains "关键事件进 logread（logger -t overlay-setup）" 'logger -t overlay-setup' "$(cat "$FAKE_LOG")"
[ -s "$SB/kmsg" ] && ok "本次日志也 dump 进了 kmsg" || bad "kmsg 里没有日志副本（p2 内部 overlay 的日志会丢）"
not_contains "不再有 FINDMNT 覆盖点（25.12.2 源里没有 findmnt）" 'FINDMNT' "$(cat "$SB_SETUP")"
eq "运行期一次都没调用 findmnt" '0' "$(count '^findmnt' "$FAKE_LOG")"

echo "== ② 已就绪：/overlay 已是 btrfs 且含 @overlay =="
setup ready
printf '@overlay\n@docker\n@swap\n@data\n' >"$STATE/subvols"
printf 'wrt-overlay\n' >"$STATE/label"
mnt_add "$SB/overlay" btrfs
rc=0
out=$(run_setup) || rc=$?
eq "退出 0" '0' "$rc"
eq "不做任何写操作" '' "$(mutating)"
contains "报告 up-to-date" 'up-to-date' "$out"
eq "就绪路径不写 ERROR" '0' "$(count 'ERROR' "$SB_LOG")"

echo "== ③ 中间态：p3 已存在但非 btrfs =="
setup half
: >"$SB/sys/block/sda/sda3"
rc=0
out=$(run_setup) || rc=$?
eq "退出 2（已下发重启）" '2' "$rc"
not_contains "不重复建分区" 'sgdisk' "$(mutating)"
not_contains "不重复 partx" 'partx' "$(mutating)"
contains "只做 mkfs" "mkfs.btrfs -L wrt-overlay -f $SB/dev/sda3" "$(mutating)"

echo "== ④ 缺子卷：fs 已就绪但只有 @overlay =="
setup subvols
: >"$SB/sys/block/sda/sda3"
printf 'wrt-overlay\n' >"$STATE/label"
printf '@overlay\n' >"$STATE/subvols"
rc=0
out=$(run_setup) || rc=$?
eq "退出 2（已下发重启）" '2' "$rc"
same_list "只补建缺失的三个子卷" "$(cat <<EOS
mount -t btrfs -o subvolid=5,noatime $SB/dev/sda3 $SB/tmp/top
btrfs subvolume create $SB/tmp/top/@docker
btrfs subvolume create $SB/tmp/top/@swap
btrfs subvolume create $SB/tmp/top/@data
chattr +C $SB/tmp/top/@docker
chattr +C $SB/tmp/top/@swap
umount $SB/tmp/top
sync
reboot
EOS
)" "$(mutating)"

echo "== ⑤ /rom 是整盘 root（无分区）：拒绝执行 =="
setup whole
: >"$SB/proc/mountinfo"
printf '/dev/sda %s squashfs ro,relatime 0 0\n' "$SB/rom" >"$SB/proc/mounts"
rc=0
out=$(run_setup) || rc=$?
eq "退出 3" '3' "$rc"
eq "不做任何写操作" '' "$(mutating)"

echo "== ⑥ --dry-run 不执行写命令 =="
setup dry
rc=0
out=$(run_setup --dry-run) || rc=$?
eq "退出 0" '0' "$rc"
eq "不执行任何写命令" '' "$(mutating)"
contains "打印将要执行的分区操作" 'DRY' "$out"
contains "计划里看得到 mkfs" 'mkfs.btrfs' "$out"

echo "== ⑦ 失败路径：sgdisk 失败 → 非 0 + 写日志 + 不动 p2 overlay =="
setup fail
: >"$STATE/sgdisk.fail"
rc=0
out=$(run_setup) || rc=$?
ne "退出非 0（uci-defaults 下次开机会重试）" '0' "$rc"
not_contains "失败后不 mkfs" 'mkfs.btrfs' "$(mutating)"
not_contains "失败后不 mount" 'mount ' "$(mutating)"
contains "日志有 ERROR" 'ERROR' "$(cat "$SB_LOG" 2>/dev/null)"
[ -d "$SB/overlay" ] && eq "p2 内部 overlay 未被改动" '' "$(ls -A "$SB/overlay")" || bad "overlay 目录丢了吗"

echo "== ⑧ S0 回退：/proc/mounts 直接给分区名 =="
setup fallback
: >"$SB/proc/mountinfo"
printf '/dev/sda2 %s squashfs ro,relatime 0 0\n' "$SB/rom" >"$SB/proc/mounts"
printf '@overlay\n' >"$STATE/subvols"
printf 'wrt-overlay\n' >"$STATE/label"
mnt_add "$SB/overlay" btrfs
rc=0
out=$(run_setup) || rc=$?
eq "退出 0（认出 /dev/sda2 → sda + 3）" '0' "$rc"
eq "不做任何写操作" '' "$(mutating)"

echo "== ⑨ uci-defaults 包装：退出码原样透传（0 才被自动删除）=="
setup wrapper
SB_WRAP=$(sb_script "$REPO/files/etc/uci-defaults/95-overlay-setup.sh" etc/uci-defaults/95-overlay-setup.sh)
cat >"$STATE/fake-setup" <<'EOS'
#!/bin/sh
printf '%s' "$*" >"$STATE/args"
exit "${FAKE_RC:-0}"
EOS
chmod +x "$STATE/fake-setup"
rc=0
OVERLAY_SETUP=$STATE/fake-setup FAKE_RC=2 sh "$SB_WRAP" >/dev/null 2>&1 || rc=$?
eq "子脚本 2 → 包装也 2（保留重试）" '2' "$rc"
rc=0
OVERLAY_SETUP=$STATE/fake-setup FAKE_RC=0 sh "$SB_WRAP" >/dev/null 2>&1 || rc=$?
eq "子脚本 0 → 包装 0（下次开机不再跑）" '0' "$rc"
rc=0
OVERLAY_SETUP=$STATE/nope sh "$SB_WRAP" >/dev/null 2>&1 || rc=$?
ne "子脚本缺失 → 非 0" '0' "$rc"
rc=0
OVERLAY_SETUP=$STATE/fake-setup FAKE_RC=0 sh "$SB_WRAP" --dry-run >/dev/null 2>&1 || rc=$?
eq "参数原样透传" '--dry-run' "$(cat "$STATE/args" 2>/dev/null)"

echo "== ⑩ chattr 缺失（25.12 里 chattr 是独立 apk 包）：降级不阻断 =="
setup nochattr
rm -f "$SB/bin/chattr"
rc=0
out=$(run_setup) || rc=$?
eq "仍然走完流程并下发重启（exit 2）" '2' "$rc"
contains "日志说明 chattr 缺失并声明降级" 'chattr 包缺失' "$(cat "$SB_LOG" 2>/dev/null)"
eq "不尝试 chattr +C" '0' "$(count '^chattr ' "$FAKE_LOG")"
contains "子卷照建（@data 在序列里）" '@data' "$(mutating)"

echo "== ⑪ p3/子卷都在但 /overlay 仍非 btrfs：不重启、exit 3（防无限重启砖）=="
setup loopguard
: >"$SB/sys/block/sda/sda3"
printf 'wrt-overlay\n' >"$STATE/label"
printf '@overlay\n@docker\n@swap\n@data\n' >"$STATE/subvols"
rc=0
out=$(run_setup) || rc=$?
eq "退出 3（不支持/无法自愈）" '3' "$rc"
not_contains "不调用 reboot（否则每次开机都重启、网络又没起）" 'reboot' "$(mutating)"
contains "日志说明为什么不动" '避免无限重启' "$(cat "$SB_LOG" 2>/dev/null)"
contains "同一事件进了 logread" '避免无限重启' "$(cat "$STATE/logread" 2>/dev/null)"

echo "== ⑫ btrfs 命令缺失：立即 exit 3，不重启、不碰盘 =="
setup nobtrfs
rm -f "$SB/bin/btrfs"
rc=0
out=$(run_setup) || rc=$?
eq "退出 3" '3' "$rc"
eq "不做任何写操作" '' "$(mutating)"
contains "明确报出缺 btrfs（不是静默判未就绪）" 'btrfs' "$out"
contains "缺 btrfs 时也进 logread" 'btrfs' "$(cat "$STATE/logread" 2>/dev/null)"

finish OVERLAY-SETUP
