#!/bin/sh
# ac-1：仓库内不再存在任何端口重命名逻辑
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

[ -e "$ROOT/files/etc/init.d/portmap" ] && { echo "FAIL: 重命名脚本仍存在"; FAIL=1; } || echo "ok: 已删除 portmap init"

HITS=$(grep -rn "ip link set .* name \|ip link set .*name eth" "$ROOT/files" "$ROOT/shell" 2>/dev/null | grep -v "no-rename.sh" | grep -v "tmp\$i")
if [ -n "$HITS" ]; then echo "FAIL: 仍有改名调用:"; echo "$HITS" | head -5; FAIL=1; else echo "ok: 无改名调用"; fi

[ -x "$ROOT/files/usr/sbin/nicsync" ] && echo "ok: nicsync 存在" || { echo "FAIL: 缺 nicsync"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "NO-RENAME OK" || echo "NO-RENAME FAILED"
exit $FAIL
