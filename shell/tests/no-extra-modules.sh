#!/bin/sh
# ac-1：探针与自动扩容已删除，无残留
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0
for f in files/etc/config/wandetect files/usr/sbin/wandetect files/etc/init.d/wandetect \
         files/usr/sbin/rootfs-expand shell/tests/wandetect-vote.sh shell/tests/rootfs-grow.sh; do
	[ -e "$ROOT/$f" ] && { echo "FAIL: 仍存在 $f"; FAIL=1; }
done
[ "$FAIL" = "0" ] && echo "ok: 文件已删除"

H=$(grep -rn "wandetect\|rootfs-expand" "$ROOT/files" "$ROOT/shell" "$ROOT/docs" "$ROOT/README.md" 2>/dev/null | grep -v no-extra-modules.sh | grep -v no-auto-disk.sh | grep -v lib-uci-stub.sh | grep -v docs-native.sh)
[ -z "$H" ] && echo "ok: 无引用残留" || { echo "FAIL: 仍有引用:"; echo "$H" | head -5; FAIL=1; }

[ "$FAIL" = "0" ] && echo "NO-EXTRA OK" || echo "NO-EXTRA FAILED"
exit $FAIL
