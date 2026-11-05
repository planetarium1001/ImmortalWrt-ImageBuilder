#!/bin/sh
# 全量套件状态判定：`fail=` 必须为 0。
#
# 为什么单独做一个：`all.sh` 在有 PEND（需要真机）时退出码是 2，直接拿它当门禁会把
# "缺少真机"误判成"回归失败"。真正要守住的是 `fail=0` 这个计数。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
out=$("$ROOT/shell/tests/all.sh" 2>&1) || true
tail=$(printf '%s\n' "$out" | tail -1)
printf '%s\n' "$out" | grep -E '^(FAIL|PEND) ' | tail -8
printf 'summary: %s\n' "$tail"
case "$tail" in
*fail=0*) echo "SUITE-STATUS OK"; exit 0 ;;
*) echo "SUITE-STATUS FAILED"; exit 1 ;;
esac
