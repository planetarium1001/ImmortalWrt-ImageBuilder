#!/bin/sh
# 认证 init：只传 --conf-file、前台运行、不放弃重试
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
I="$ROOT/files/etc/init.d/minieap"
FAIL=0

[ -f "$I" ] && echo "ok: init 存在" || { echo "FAIL: 缺 init"; FAIL=1; }
grep -q -- "--conf-file /etc/minieap.conf" "$I" && echo "ok: 传 --conf-file" || { echo "FAIL: 未传 conf"; FAIL=1; }
grep -v "^[[:space:]]*#" "$I" | grep -q -- "--daemonize" && { echo "FAIL: 不应使用 --daemonize"; FAIL=1; } || echo "ok: 无 --daemonize"
grep -q "respawn 3600 5 0" "$I" && echo "ok: respawn 不放弃" || { echo "FAIL: respawn 会放弃"; FAIL=1; }
grep -v "^[[:space:]]*#" "$I" | grep -qE "\-\-module|\-u |\-p |udhcpc" && { echo "FAIL: 注入了额外参数"; FAIL=1; } || echo "ok: 未注入额外参数"
grep -q '|example)' "$I" && echo "ok: 跳过示例账号" || { echo "FAIL: 未跳过 example"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "MINIEAP-NATIVE OK" || echo "MINIEAP-NATIVE FAILED"
exit $FAIL
