#!/bin/sh
# 首启一次：把系统盘剩余空间做成 btrfs 分区 p3 并建好子卷（调用 /usr/sbin/overlay-setup）。
#
# uci-defaults 语义：返回 0 才被删除（不再重试）；返回非 0 会在下次开机重试。
# 所以这里必须把 overlay-setup 的退出码原样传出去——"还没真正切到 @overlay 子卷"时
# overlay-setup 会非 0 退出，正是靠这个语义保留重试（否则脚本被自删，
# 系统会静默留在 p2 的内部 overlay 上）。
#
# 本脚本不写任何 UCI 配置，因此不做 uci commit：/etc/config/fstab 是 squashfs 里的
# 只读副本（preinit 的 block extroot 读的就是它），运行期改不会影响下次开机。
# 成功路径由 overlay-setup 自己 reboot，所以同一次开机里排在后面的 98/99 不会执行
# （配网、管理地址、swap 在首启重启后那次才生效）。
#
# OVERLAY_SETUP 仅供测试覆盖脚本路径。

SETUP=${OVERLAY_SETUP:-/usr/sbin/overlay-setup}

if [ ! -x "$SETUP" ]; then
	echo "95-overlay-setup: 找不到可执行的 ${SETUP}，跳过（下次开机重试）" >&2
	exit 1
fi

"$SETUP" "$@" || exit $?
exit 0
