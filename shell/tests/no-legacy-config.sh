#!/bin/sh
# ac-1：私有配置层已彻底删除
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

for f in files/usr/sbin/wanmode files/etc/config/wanprofile \
         files/usr/sbin/ruijie-guard files/etc/config/ruijie-guard; do
	[ -e "$ROOT/$f" ] && { echo "FAIL: 仍存在 $f"; FAIL=1; }
done
[ "$FAIL" = "0" ] && echo "ok: 旧文件已删除"

for kw in wanmode wanprofile ruijie-guard; do
	if grep -rn "$kw" --include="*.sh" --include="*.yml" --include="*.md" "$ROOT/files" "$ROOT/shell" "$ROOT/x86-64" "$ROOT/.github" "$ROOT/docs" "$ROOT/README.md" 2>/dev/null \
		| grep -v "no-legacy-config.sh" | grep -v "docs-native.sh" | grep -v "no-legacy-config.sh" | grep -q .; then
		echo "FAIL: 仍有引用 $kw"; FAIL=1
	fi
done
[ "$FAIL" = "0" ] && echo "ok: 无引用残留"

[ "$FAIL" = "0" ] && echo "NO-LEGACY OK" || echo "NO-LEGACY FAILED"
exit $FAIL
