#!/bin/sh
# ac-4：不吻合时写日志告警且不阻断
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/usr/sbin/nicsync"
FAIL=0

grep -q "br-lan 实际成员" "$S" && echo "ok: 有成员数告警" || { echo "FAIL: 缺告警"; FAIL=1; }
grep -q "exit 0" "$S" && echo "ok: 正常路径不阻断" || { echo "FAIL: 可能阻断"; FAIL=1; }
# 无物理口时也必须安全退出
mkdir -p /tmp/ns-empty/class/net
out=$(sh "$S" --sysfs /tmp/ns-empty 2>&1); rc=$?
[ "$rc" = "0" ] && echo "ok: 无物理口时退出码 0" || { echo "FAIL: 无物理口时退出码 $rc"; FAIL=1; }
case "$out" in *"no physical port"*) echo "ok: 明确提示无物理口" ;; *) echo "FAIL: 无提示"; FAIL=1 ;; esac

[ "$FAIL" = "0" ] && echo "NICSYNC-WARN OK" || echo "NICSYNC-WARN FAILED"
exit $FAIL
