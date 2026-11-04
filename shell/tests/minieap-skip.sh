#!/bin/sh
# ac-2：init 在 username 空或 example 时跳过
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
I="$ROOT/files/etc/init.d/minieap"
FAIL=0

grep -q '"")' <<EOF2
$(grep -n '|example)' "$I")
EOF2
grep -q '|example)' "$I" && echo "ok: 覆盖 example 示例账号" || { echo "FAIL: 未处理 example"; FAIL=1; }
grep -q 'username 未配置' "$I" && echo "ok: 有跳过日志" || { echo "FAIL: 缺日志"; FAIL=1; }
grep -v "^[[:space:]]*#" "$I" | grep -q -- "--conf-file /etc/minieap.conf" && echo "ok: 仍读 conf" || { echo "FAIL: 未读 conf"; FAIL=1; }
grep -v "^[[:space:]]*#" "$I" | grep -q -- "--daemonize" && { echo "FAIL: 又加了 daemonize"; FAIL=1; } || echo "ok: 无 daemonize"

[ "$FAIL" = "0" ] && echo "MINIEAP-SKIP OK" || echo "MINIEAP-SKIP FAILED"
exit $FAIL
