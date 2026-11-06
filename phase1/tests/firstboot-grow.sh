#!/bin/sh
# ac-5：首启 p2 扩容脚本的行为用例 —— 真跑脚本 + 桩命令（离线，macOS 可跑）。
#
# 为什么不是"grep 源码"：扩容脚本的价值全在"什么时候**不**动盘"和"失败会不会阻断启动"。
# 所以这里把 sgdisk / partx / btrfs / findmnt 换成"记录 argv 并按规定退出"的桩，
# 真跑 10-grow-p2.sh，然后断言 ①调了哪些命令 ②顺序对不对 ③该拒的时候一条破坏性命令都没发。
#
# 场景：
#   1 需要扩   ：p2 end < 盘尾 ⇒ 必须 sgdisk -e → sgdisk -d 2 -n 2:<原start>:0 → partx -u → btrfs resize max
#   2 已满     ：p2 end = 盘尾 ⇒ 打印 already-full，一条 sgdisk -d 都不发（幂等）
#   3 命令失败 ：桩 sgdisk 返回 1 ⇒ 瞬时失败 **exit 1**（uci-defaults 保留脚本、下次开机重试；
#                启动本身不受影响：boot 只是跳过删文件），日志里有失败记录
#   4 几何异常 ：p128 start >= p2 start ⇒ 拒绝改分区表（不动盘），**exit 0**（不该重试）
#   5 无 /proc/mounts：退化用 findmnt 认盘，仍然走完扩容
#   6 缺工具   ：PATH 里没有 sgdisk/partx/btrfs ⇒ 只记日志、exit 0（重试也不会自己长出来）
#   7 resize 失败：btrfs 返回 1 ⇒ exit 1（瞬时失败，重启重试）
#   8 partx 全失败：两种用法都失败 ⇒ exit 1（内核没重读表，resize 必失败）
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

GROW=$REPO/phase1/firstboot/rootfs/etc/uci-defaults/10-grow-p2.sh
NAME='phase1-firstboot-grow'
DISK=/dev/sda
P2_START=534528
P2_END_GROW=16000000
LAST=16777182

[ -f "$GROW" ] || {
	printf '  FAIL 缺少 %s\n' "$GROW"
	finish "$NAME"
}

SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sb-grow.XXXXXX" 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# 静态前提：这是首启脚本，必须 POSIX sh、可执行、且永远以 exit 0 收尾
# ---------------------------------------------------------------------------
echo "== 0. 静态前提 =="
eq "10-grow-p2.sh 可执行" '-rwxr-xr-x' "$(ls -l "$GROW" | cut -c1-10)"
if sh -n "$GROW" 2>/dev/null; then ok "sh -n 通过"; else bad "sh -n 失败"; fi
GR=$(cat "$GROW")
not_contains "没有 set -e（失败不能中断启动）" 'set -eu' "$GR"
contains "用 sgdisk -e 先把备份 GPT 挪到盘尾" 'sgdisk -e' "$GR"
contains "重建 p2 到盘尾（end=0）" ':0" -t 2:8300 -c 2:phase1-root' "$GR"
contains "partx -u 让内核重读分区表" 'partx -u' "$GR"
contains "partx -u 不可用时退化 partx -a -n 2:2" 'partx -a -n 2:2' "$GR"
contains "btrfs filesystem resize max" 'btrfs filesystem resize max' "$GR"
contains "已满幂等分支（already-full）" 'already-full' "$GR"
contains "瞬时失败路径用 exit 1（uci-defaults 才会保留脚本）" 'exit 1' "$GR"
eq "文件里确实有 exit 1 分支" 'yes' "$(grep -qE '^[[:space:]]*exit 1$' "$GROW" && echo yes || echo no)"
eq "最后一条是 exit 0（成功路径）" 'exit 0' "$(grep -E '^exit ' "$GROW" | tail -1)"
not_contains "文件头不再声称\"永远 exit 0\"" '永远 exit 0' "$GR"
contains "文件头写清了 uci-defaults 的退出语义" 'exit 0 ⇒' "$GR"

# ---------------------------------------------------------------------------
# 桩与夹具
# ---------------------------------------------------------------------------
write_stubs() { # <桩目录>
	_s=$1
	mkdir -p "$_s"

	cat >"$_s/sgdisk" <<'EOF'
#!/bin/sh
printf 'sgdisk %s\n' "$*" >>"${STUB_LOG:?}"
case $1 in
-p)
	[ -n "${STUB_TABLE:-}" ] || exit 1
	cat "$STUB_TABLE"
	exit 0
	;;
esac
exit "${STUB_SGDISK_RC:-0}"
EOF

	cat >"$_s/partx" <<'EOF'
#!/bin/sh
printf 'partx %s\n' "$*" >>"${STUB_LOG:?}"
exit "${STUB_PARTX_RC:-0}"
EOF

	cat >"$_s/btrfs" <<'EOF'
#!/bin/sh
printf 'btrfs %s\n' "$*" >>"${STUB_LOG:?}"
printf 'Resize device id 1 (stub) from 7.80GiB to 8.00GiB\n'
exit "${STUB_BTRFS_RC:-0}"
EOF

	# findmnt 桩：只实现 `-n -o SOURCE,TARGET,OPTIONS -t btrfs`（脚本的唯一调用形态）
	cat >"$_s/findmnt" <<'EOF'
#!/bin/sh
printf 'findmnt %s\n' "$*" >>"${STUB_LOG:?}"
[ -n "${STUB_FINDMNT:-}" ] || exit 1
cat "$STUB_FINDMNT"
exit 0
EOF
	chmod 755 "$_s/sgdisk" "$_s/partx" "$_s/btrfs" "$_s/findmnt"
}

table() { # <文件> <p2end> <p128start>
	cat >"$1" <<EOF
Disk ${DISK}: 16777216 sectors, 8.0 GiB
Model: STUB-DISK
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 00000000-0000-0000-0000-000000000000
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 2048, last usable sector is ${LAST}
Partitions will be aligned on 2048-sector boundaries
Total free space is 0 sectors (0 bytes)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048          526335   256.0 MiB   EF00  phase1-boot
 128        $3          534527   4.0 MiB     EF02  phase1-core
   2       ${P2_START}        $2   7.8 GiB     8300  phase1-root
EOF
}

mounts() { # <文件>：伪造 /proc/mounts（/rom 挂 @root 是 ro，/overlay 挂 @overlay 是 rw）
	cat >"$1" <<EOF
${DISK}1 ${BOOT_MNT} vfat rw,relatime 0 0
${DISK}2 ${MNT_ROM} btrfs ro,relatime,subvol=/@root 0 0
${DISK}2 ${MNT_OVL} btrfs rw,noatime,compress=zstd:1,subvol=/@overlay 0 0
overlay / overlay rw,relatime,lowerdir=/lower,upperdir=${MNT_OVL}/upper,workdir=${MNT_OVL}/work 0 0
EOF
}

new_case() { # <名字>
	CASE=$SB_ROOT/$1
	STUB=$CASE/stub
	mkdir -p "$STUB" "$CASE/mnt/boot" "$CASE/mnt/rom" "$CASE/mnt/overlay" "$CASE/proc"
	: >"$CASE/calls.log"
	: >"$CASE/grow.log"
	: >"$CASE/kmsg"
	ARGS=$CASE/calls.log
	GLOG=$CASE/grow.log
	KMSG=$CASE/kmsg
	BOOT_MNT=$CASE/mnt/boot
	MNT_ROM=$CASE/mnt/rom
	MNT_OVL=$CASE/mnt/overlay
	TABLE=$CASE/table.txt
	MOUNTS_SRC=$CASE/proc/mounts
	# 桩旋钮每个用例复位（这些是普通 shell 变量，上一条用例设过的会留下来）
	STUB_SGDISK_RC=0
	STUB_PARTX_RC=0
	STUB_BTRFS_RC=0
	STUB_FINDMNT=''
	write_stubs "$STUB"
	mounts "$CASE/proc/mounts"
}

run_grow() { # 真跑扩容脚本（PATH 前置桩目录）；返回码放 RC，输出进 $CASE/grow.out
	# 桩的旋钮全部显式进环境：非 export 的 shell 变量子进程看不到（踩过）
	if PATH="$STUB:$PATH" \
		PROC_MOUNTS="$MOUNTS_SRC" \
		PHASE1_GROW_LOG="$GLOG" \
		PHASE1_GROW_KMSG="$KMSG" \
		STUB_LOG="$ARGS" \
		STUB_TABLE="$TABLE" \
		STUB_SGDISK_RC="${STUB_SGDISK_RC:-0}" \
		STUB_PARTX_RC="${STUB_PARTX_RC:-0}" \
		STUB_BTRFS_RC="${STUB_BTRFS_RC:-0}" \
		STUB_FINDMNT="${STUB_FINDMNT:-}" \
		sh "$GROW" >"$CASE/grow.out" 2>&1; then
		RC=0
	else
		RC=$?
	fi
}

line_of() { # <模式> → 在调用日志里第一个匹配的行号（没有给 0）
	_n=$(grep -n -- "$1" "$ARGS" 2>/dev/null | head -1 | cut -d: -f1)
	[ -n "$_n" ] || _n=0
	printf '%s\n' "$_n"
}

# ---------------------------------------------------------------------------
# 1. 需要扩容：命令 + 顺序
# ---------------------------------------------------------------------------
echo "== 1. 未满：必须扩到盘尾，且顺序是先 -e 再 -d/-n 再 partx 再 resize =="
new_case need-grow
table "$TABLE" "$P2_END_GROW" 526336
run_grow
eq "退出 0" '0' "$RC"
contains "调了 sgdisk -e" "sgdisk -e ${DISK}" "$(cat "$ARGS")"
contains "重建 p2：同 start、end=0" "sgdisk -d 2 -n 2:${P2_START}:0 -t 2:8300 -c 2:phase1-root ${DISK}" "$(cat "$ARGS")"
contains "调了 partx -u" "partx -u ${DISK}" "$(cat "$ARGS")"
contains "resize 对着**可写**的 /overlay 挂载点（不是 /rom，也不是 /）" \
	"btrfs filesystem resize max ${MNT_OVL}" "$(cat "$ARGS")"
_e=$(line_of "sgdisk -e")
_d=$(line_of "sgdisk -d 2")
_p=$(line_of "partx -u")
_r=$(line_of "btrfs filesystem resize")
if [ "$_e" -gt 0 ] && [ "$_e" -lt "$_d" ] && [ "$_d" -lt "$_p" ] && [ "$_p" -lt "$_r" ]; then
	ok "顺序正确：sgdisk -e(${_e}) < sgdisk -d 2(${_d}) < partx -u(${_p}) < btrfs resize(${_r})"
else
	bad "顺序不对：-e=${_e} -d=${_d} partx=${_p} resize=${_r}"
fi
contains "日志记了 ok/done" 'done：p2 已扩到盘尾' "$(cat "$GLOG")"
contains "kmsg 也写了（两个日志口都通）" '10-grow-p2:' "$(cat "$KMSG")"
contains "resize 的输出进了日志" 'Resize device id 1' "$(cat "$GLOG")"
eq "日志里没有 already-full（确实走了扩容分支）" '0' "$(grep -c 'already-full' "$GLOG")"

# ---------------------------------------------------------------------------
# 2. 已满：幂等，一条破坏性命令都不发
# ---------------------------------------------------------------------------
echo "== 2. 已满（p2 end = 盘尾）：幂等，不发 sgdisk -d =="
new_case already-full
table "$TABLE" "$LAST" 526336
run_grow
eq "退出 0" '0' "$RC"
contains "日志说 already-full" 'already-full' "$(cat "$GLOG")"
eq "没有 sgdisk -d" '0' "$(grep -c 'sgdisk -d' "$ARGS")"
eq "没有 btrfs resize" '0' "$(grep -c 'btrfs filesystem resize' "$ARGS")"
run_grow
eq "再跑一次仍退出 0" '0' "$RC"
eq "再跑一次没有新增 sgdisk -d" '0' "$(grep -c 'sgdisk -d' "$ARGS")"

# ---------------------------------------------------------------------------
# 3. 命令失败：不阻断启动
# ---------------------------------------------------------------------------
echo "== 3. sgdisk 返回 1：瞬时失败 ⇒ exit 1（重试），启动不受影响 =="
new_case sgdisk-fail
table "$TABLE" "$P2_END_GROW" 526336
# 桩 sgdisk 一律返回 1（模拟"分区表写不进去"）
STUB_SGDISK_RC=1
run_grow
eq "退出 1（瞬时失败：脚本保留，下次开机重试；启动不阻断）" '1' "$RC"
contains "日志里有失败记录" 'FAIL' "$(cat "$GLOG")"
contains "kmsg 里也有失败记录" 'FAIL' "$(cat "$KMSG")"
eq "失败后没有继续发 sgdisk -d" '0' "$(grep -c 'sgdisk -d' "$ARGS")"
eq "失败后没有 btrfs resize" '0' "$(grep -c 'btrfs filesystem resize' "$ARGS")"

# ---------------------------------------------------------------------------
# 4. 几何异常：p128 在 p2 之后 ⇒ 拒绝改分区表
# ---------------------------------------------------------------------------
echo "== 4. 几何异常（p128 start >= p2 start）：拒绝改分区表 =="
new_case bad-geometry
table "$TABLE" "$P2_END_GROW" 600000
run_grow
eq "退出 0" '0' "$RC"
contains "日志点出几何异常" '几何异常' "$(cat "$GLOG")"
eq "没有 sgdisk -d（一个字节都不动）" '0' "$(grep -c 'sgdisk -d' "$ARGS")"
eq "没有 partx -u" '0' "$(grep -c 'partx -u' "$ARGS")"
eq "没有 btrfs resize" '0' "$(grep -c 'btrfs filesystem resize' "$ARGS")"

# ---------------------------------------------------------------------------
# 5. 没有 /proc/mounts：退化用 findmnt 认盘
# ---------------------------------------------------------------------------
echo "== 5. 读不到 /proc/mounts：用 findmnt 认盘，仍然走完扩容 =="
new_case via-findmnt
table "$TABLE" "$P2_END_GROW" 526336
cat >"$CASE/findmnt.list" <<EOF
${DISK}2 ${MNT_OVL} rw,noatime,subvol=/@overlay
${DISK}2 ${MNT_ROM} ro,relatime,subvol=/@root
EOF
STUB_FINDMNT=$CASE/findmnt.list
MOUNTS_SRC=$CASE/proc/nonexistent
run_grow
eq "退出 0" '0' "$RC"
contains "调了 findmnt 兜底" 'findmnt -n -o SOURCE,TARGET,OPTIONS -t btrfs' "$(cat "$ARGS")"
contains "仍然重建了 p2" "sgdisk -d 2 -n 2:${P2_START}:0" "$(cat "$ARGS")"
contains "仍然 resize 到可写挂载点" "btrfs filesystem resize max ${MNT_OVL}" "$(cat "$ARGS")"

# ---------------------------------------------------------------------------
# 6. resize 失败：瞬时失败 ⇒ exit 1
# ---------------------------------------------------------------------------
echo "== 6. btrfs filesystem resize 失败：瞬时失败 ⇒ exit 1 =="
new_case resize-fail
table "$TABLE" "$P2_END_GROW" 526336
STUB_BTRFS_RC=1
run_grow
eq "退出 1（瞬时失败，下次开机重试）" '1' "$RC"
contains "日志里有 resize 失败记录" 'FAIL: btrfs filesystem resize' "$(cat "$GLOG")"
contains "日志说明下次开机会重试" '下次开机会重试' "$(cat "$GLOG")"
contains "分区表已经改过（-d 2 发过了）" "sgdisk -d 2" "$(cat "$ARGS")"

# ---------------------------------------------------------------------------
# 7. partx 两种用法都失败：瞬时失败 ⇒ exit 1
# ---------------------------------------------------------------------------
echo "== 7. partx -u 与 partx -a 都失败：瞬时失败 ⇒ exit 1 =="
new_case partx-fail
table "$TABLE" "$P2_END_GROW" 526336
STUB_PARTX_RC=1
run_grow
eq "退出 1（瞬时失败，下次开机重试）" '1' "$RC"
contains "日志点名 partx 两条路都失败" 'partx 两种用法都失败' "$(cat "$GLOG")"
eq "partx 两种用法都试过了" '2' "$(grep -c '^partx ' "$ARGS")"
eq "partition 表改完但没做 resize（内核没重读就不 resize）" '0' "$(grep -c 'btrfs filesystem resize' "$ARGS")"

# ---------------------------------------------------------------------------
# 8. 缺工具：只记日志，exit 0
# ---------------------------------------------------------------------------
echo "== 8. 缺 sgdisk/partx/btrfs：只记日志、exit 0（不该重试）=="
new_case no-tools
table "$TABLE" "$P2_END_GROW" 526336
rm -f "$STUB/sgdisk" "$STUB/partx" "$STUB/btrfs"
run_grow
eq "退出 0" '0' "$RC"
contains "日志点名缺哪个工具" '缺少 sgdisk' "$(cat "$GLOG")"
contains "给出补包提示" 'btrfs-progs' "$(cat "$GLOG")"

finish "$NAME"
