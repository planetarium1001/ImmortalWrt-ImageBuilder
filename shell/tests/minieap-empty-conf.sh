#!/bin/sh
# ac-1：conf 出厂零有效参数，由首次 -w 生成
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
C="$ROOT/files/etc/minieap.conf"
FAIL=0

[ -f "$C" ] && echo "ok: 文件存在" || { echo "FAIL: 缺 conf"; FAIL=1; }

# 不得有任何未注释的 key=value
EFF=$(grep -vE '^[[:space:]]*#' "$C" | grep -E '^[[:space:]]*[a-z-]+[[:space:]]*=' || true)
[ -z "$EFF" ] && echo "ok: 无有效键" || { echo "FAIL: 存在预设键:"; echo "$EFF"; FAIL=1; }

grep -q -- "-w" "$C" && echo "ok: 说明 -w 生成" || { echo "FAIL: 未说明 -w"; FAIL=1; }
grep -q "init.d/minieap" "$C" && echo "ok: 说明开自启" || { echo "FAIL: 缺自启说明"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "MINIEAP-EMPTY OK" || echo "MINIEAP-EMPTY FAILED"
exit $FAIL
