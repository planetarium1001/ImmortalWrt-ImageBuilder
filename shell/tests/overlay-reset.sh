#!/bin/sh
# ac-8：overlay-reset（恢复出厂替代品）。
#
# firstboot / jffs2reset 在 extroot 下**无效**（fstools 的 factoryreset 只重置 rootfs_data，
# 而 extroot 生效时 rootfs_data 根本没被挂载）——它们会"报成功但什么都没删"。
# 所以恢复出厂必须清 /overlay/upper（系统层的可写差异）再重启。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

setup() { # <tag>
	sb_new "reset-$1"
	SB=$SB_ROOT
	mkdir -p "$SB/state" "$SB/overlay/upper"
	FAKE_LOG=$SB/calls.log
	: >"$FAKE_LOG"
	export FAKE_LOG
	UPPER=$SB/overlay/upper
	# 假 /proc/mounts：25.12.2 源里没有 findmnt，写层类型只能从这里读
	MP=$SB/state/mounts
	mkdir -p "$SB/state"
	printf '/dev/sda3 %s btrfs rw,noatime 0 0\n' "$SB/overlay" >"$MP"
	# 典型 overlay 上层：配置 + 已装的包文件 + 一个隐藏文件 + 嵌套目录
	mkdir -p "$UPPER/etc/config" "$UPPER/usr/lib/opkg/info" "$UPPER/dir/sub"
	printf 'x\n' >"$UPPER/etc/config/network"
	printf 'y\n' >"$UPPER/usr/lib/opkg/info/foo.list"
	printf 'z\n' >"$UPPER/.hidden"
	printf 'w\n' >"$UPPER/dir/sub/f"
	WORK=$SB/overlay/work
	mkdir -p "$WORK/work/incompat"
	printf 'junk\n' >"$WORK/work/incompat/data"
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
	SB_RESET=$(sb_script "$REPO/files/usr/sbin/overlay-reset" usr/sbin/overlay-reset)
}

fake() { cat >"$SB/bin/$1"; chmod +x "$SB/bin/$1"; }

setup base

run_reset() { # [参数...]
	OVERLAY_UPPER=$UPPER OVERLAY_WORK=$WORK OVERLAY_DIR=$SB/overlay PROC_MOUNTS=$MP \
		SYNC=$SB/bin/sync REBOOT=$SB/bin/reboot sh "$SB_RESET" "$@"
}

count() { if [ -f "$2" ]; then grep -c "$1" "$2" 2>/dev/null || true; else echo 0; fi; }

echo "== ① 不带 --yes：只打印计划，不动数据 =="
before=$(ls -A "$UPPER" | wc -l | tr -d ' ')
rc=0
out=$(run_reset) || rc=$?
eq "退出 0" '0' "$rc"
eq "数据一个都没删" "$before" "$(ls -A "$UPPER" | wc -l | tr -d ' ')"
eq "不重启" '0' "$(count '^reboot' "$FAKE_LOG")"
contains "打印了将要做什么" '--yes' "$out"
contains "写层类型来自 /proc/mounts（不依赖 findmnt）" 'btrfs' "$out"
not_contains "不再有 FINDMNT 覆盖点（25.12.2 源里没有 findmnt）" 'FINDMNT' "$(cat "$SB_RESET")"
contains "说明 firstboot 在本固件无效" 'firstboot' "$out"
contains "说明 jffs2reset 无效" 'jffs2reset' "$out"

echo "== ② --yes：清空上层（含隐藏文件）后重启 =="
rc=0
out=$(run_reset --yes) || rc=$?
eq "退出 0" '0' "$rc"
eq "上层已清空（含隐藏文件）" '0' "$(ls -A "$UPPER" | wc -l | tr -d ' ')"
eq "上层目录本身保留" 'yes' "$([ -d "$UPPER" ] && echo yes)"
eq "overlayfs 的 work 目录也清空（残留会影响下次挂载）" '0' "$(ls -A "$WORK" 2>/dev/null | wc -l | tr -d ' ')"
eq "清完先 sync 再次重启" 'sync
reboot' "$(sed 's/[[:space:]]*$//' "$FAKE_LOG" | grep -E '^(sync|reboot)')"
contains "提示恢复出厂语义" 'firstboot' "$out"

echo "== ③ 安全阀：上层不存在 → 非 0（不能在 extroot 没生效时瞎清）=="
UPPER=$SB/overlay/nope
rc=0
out=$(run_reset --yes 2>&1) || rc=$?
ne "退出非 0" '0' "$rc"
eq "仍然不重启" '1' "$(count '^reboot' "$FAKE_LOG")"

echo "== ④ 安全阀：/overlay 不是 btrfs（extroot 没生效）→ 拒绝，不删不重启 =="
setup nonextroot
before=$(ls -A "$UPPER" | wc -l | tr -d ' ')
printf '/dev/loop0 %s ext4 rw,noatime 0 0\n' "$SB/overlay" >"$MP"
rc=0
out=$(run_reset --yes 2>&1) || rc=$?
ne "退出非 0" '0' "$rc"
eq "一个字节都没删" "$before" "$(ls -A "$UPPER" | wc -l | tr -d ' ')"
eq "不重启" '0' "$(count '^reboot' "$FAKE_LOG")"
contains "提示需要显式放行开关" '--force-non-extroot' "$out"

echo "== ⑤ 显式 --force-non-extroot 才允许清非 extroot 的写层 =="
rc=0
out=$(run_reset --yes --force-non-extroot) || rc=$?
eq "退出 0" '0' "$rc"
eq "清空了" '0' "$(ls -A "$UPPER" | wc -l | tr -d ' ')"
eq "重启了一次" '1' "$(count '^reboot' "$FAKE_LOG")"

finish OVERLAY-RESET
