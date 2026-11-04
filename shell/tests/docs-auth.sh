#!/bin/sh
# ac-6：文档写明首次认证三步与 IPv6 记忆行为
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D="$ROOT/docs"
FAIL=0
need() { grep -rq -- "$1" "$D" 2>/dev/null && echo "ok: $2" || { echo "FAIL: 缺 $2"; FAIL=1; }; }

need "-w" "首次 -w 生成配置"
need "minieap -u" "手动运行命令"
need "ipv6mode native" "IPv6 native 用法"
need "ipv6mode nat66" "IPv6 nat66 用法"
need "记住\|记忆\|存档" "IPv6 记忆说明"

[ "$FAIL" = "0" ] && echo "DOCS-AUTH OK" || echo "DOCS-AUTH FAILED"
exit $FAIL
