#!/bin/sh
# ac-7：文档给出原生命令与"认证≠取地址"的说明
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D="$ROOT/docs"
FAIL=0
need() { grep -rq "$1" "$D" 2>/dev/null && echo "ok: $2" || { echo "FAIL: 缺 $2"; FAIL=1; }; }
need "minieap.conf" "conf 配置说明"
need "init.d/minieap" "init 自启说明"
need "只做 802.1X 认证\|只做认证" "认证与地址分工"
need "proto dhcp" "地址由 dhcp 获取"
need "PCI" "端口顺序说明"
grep -rq "wanmode" "$D" && { echo "FAIL: 文档仍提 wanmode"; FAIL=1; } || echo "ok: 无 wanmode 残留"
[ "$FAIL" = "0" ] && echo "DOCS-NATIVE OK" || echo "DOCS-NATIVE FAILED"
exit $FAIL
