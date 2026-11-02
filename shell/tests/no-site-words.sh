#!/bin/sh
# ac-1：仓库内不出现指向具体使用场景的字样
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0
HITS=$(grep -rn "校园\|学校\|高校\|宿舍" \
	--include="*.md" --include="*.sh" --include="*.yml" --include="*.yaml" \
	"$ROOT/files" "$ROOT/shell" "$ROOT/x86-64" "$ROOT/.github" "$ROOT/README.md" 2>/dev/null \
	| grep -v "upstream" | grep -v "no-site-words.sh" | grep -v "docs-generic.sh")

if [ -n "$HITS" ]; then
	echo "FAIL: 仍存在场景字样:"; echo "$HITS" | head -10; FAIL=1
else
	echo "ok: 无场景字样"
fi

# 旧标识符不得残留
# 注意排除本测试自身（它必须写出旧名才能断言）
for old in campus-guard wanprofile.campus "apply campus" campus.md; do
	if grep -rn "$old" --include="*.sh" --include="*.md" "$ROOT/files" "$ROOT/shell" "$ROOT/x86-64" 2>/dev/null \
		| grep -qv "no-site-words.sh"; then
		echo "FAIL: 残留旧标识 $old"; FAIL=1
	fi
done
[ "$FAIL" = "0" ] && echo "ok: 无 campus 残留"

[ "$FAIL" = "0" ] && echo "NO-SITE-WORDS OK" || echo "NO-SITE-WORDS FAILED"
exit $FAIL
