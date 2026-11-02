#!/bin/sh
# ac-8：README 必须写清写入后的流程与注意事项
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
R="$ROOT/README.md"
FAIL=0

need() { grep -q "$1" "$R" && echo "ok: $2" || { echo "FAIL: 缺少 $2"; FAIL=1; }; }
# 章节标题以文档为准（用户已定稿为「写入后开机」），同时兼容旧标题
need "## 写入后开机\|## 写入后会发生什么" "写入后流程章节"
need "## 注意事项" "注意事项章节"
need "根分区扩满系统盘" "扩容步骤"
need "nvme0n1p2\|sda1" "设备名兼容说明"
need "resize2fs" "扩容命令"
need "uci-defaults-log.txt" "首启日志位置"
need "先接 LAN、后接 WAN" "接线顺序注意事项"
need "passwd" "首次改密码提示"
need "关闭 DHCP" "AP 模式注意事项"
need "192.168.100.1" "管理地址"

[ "$FAIL" = "0" ] && echo "README-FLOW OK" || echo "README-FLOW FAILED"
exit $FAIL
