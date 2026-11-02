#!/bin/sh
# ac-2：构建脚本语法有效、包清单无未知包名（离线校验，不联网）
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

for f in "$ROOT/x86-64/build25.sh" "$ROOT/files/usr/sbin/portmap" "$ROOT/files/usr/sbin/wandetect" \
         "$ROOT/files/usr/sbin/swapctl" "$ROOT/files/usr/sbin/wanmode" "$ROOT/files/usr/sbin/ruijie-guard" \
         "$ROOT/files/etc/uci-defaults/99-custom.sh" "$ROOT/files/etc/init.d/wandetect"; do
	if sh -n "$f" 2>/dev/null; then echo "ok: syntax $f"; else echo "FAIL: syntax $f"; FAIL=1; fi
done

# 包清单：从 build25.sh 抽出 PACKAGES 里的包名，检查与允许清单一致
ALLOW="$ROOT/shell/tests/allowed-packages.txt"
[ -f "$ALLOW" ] || { echo "FAIL: 缺少 $ALLOW"; exit 1; }
pkgs=$(sed -n 's/^PACKAGES="\$PACKAGES \(.*\)"$/\1/p' "$ROOT/x86-64/build25.sh" | tr ' ' '\n' | grep -v '^\$' | sort -u)
for p in $pkgs; do
	if ! grep -qx "$p" "$ALLOW"; then echo "FAIL: 未在允许清单中的包: $p"; FAIL=1; fi
done
echo "包数量: $(echo "$pkgs" | wc -l | tr -d ' ')"

[ "$FAIL" = "0" ] && echo "PACKAGES OK" || echo "PACKAGES FAILED"
exit $FAIL
