#!/bin/sh
# ac-9：README 必须写清写入后的流程与注意事项（squashfs 只读根 + btrfs 子卷写层版）。
#
# 旧版本这里要求 README 教「手工扩根分区 + parted/resizepart/resize2fs」——
# 那时根分区是 ext4 且只有 2G。现在 p2 固定 512 MiB 只读、写层在 p3 的 btrfs 子卷上，
# 手工扩 p2 不仅没必要，还会让升级走整盘覆写（丢 p3）。所以断言整体反过来：
# 必须写清"不用扩、写层在哪、首启会重启一次、怎么恢复出厂"，且**不得**再教手工动分区表。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
R="$ROOT/README.md"
FAIL=0

need() {
	if grep -q -- "$1" "$R"; then echo "ok: $2"; else echo "FAIL: 缺少 $2"; FAIL=1; fi
}
nope() {
	if grep -q -- "$1" "$R"; then echo "FAIL: 不应再出现 $2"; FAIL=1; else echo "ok: 无 $2"; fi
}

# 章节标题以文档为准（用户已定稿为「写入后开机」），同时兼容旧标题
need "## 写入后开机\|## 写入后会发生什么" "写入后流程章节"
need "## 注意事项" "注意事项章节"

# 写入后会发生什么（与固件真实行为对齐）
need "枚举物理网口" "端口枚举步骤"
need "重启一次" "首启会重启一次（写层迁到 p3）"
need "uci-defaults-log.txt" "首启日志位置"
need "overlay-setup.log" "建 p3 日志位置"

# 产物与写层
need "squashfs-combined-efi" "产物名（squashfs 单一产物）"
need "btrfs" "写层文件系统"
need "@overlay" "写层子卷"
need "/data" "个人数据子卷"

# 恢复出厂 / 升级
need "overlay-reset" "恢复出厂手段"
need "firstboot" "说明 firstboot 无效"
need "sysupgrade -T" "升级预演"

# 注意事项
need "先接 LAN、后接 WAN" "接线顺序注意事项"
need "passwd" "首次改密码提示"
need "关闭 DHCP" "AP 模式注意事项"
need "192.168.100.1" "管理地址"

# 不再教人手工动分区表（扩 p2 既无意义又会让升级整盘覆写）
nope "手工扩" "手工扩容说明"
nope "resizepart" "resizepart 命令"
nope "resize2fs" "resize2fs 命令"
nope "ext4-combined-efi" "ext4 产物名"
nope "根分区只有 2G" "「根分区只有 2G」的旧说法"

[ "$FAIL" = "0" ] && echo "README-FLOW OK" || echo "README-FLOW FAILED"
exit $FAIL
