#!/bin/sh
# ac-5：文档不含容量绑定与场景绑定描述
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D="$ROOT/x86-64/docs/n5105"
FAIL=0

for kw in "16G" "傲腾" "Optane" "500G"; do
	HITS=$(grep -rn "${kw}" "$D" "$ROOT/README.md" 2>/dev/null | grep -v upstream)
	if [ -n "$HITS" ]; then
		echo "FAIL: 仍有容量绑定描述${kw}:"; echo "$HITS" | head -3; FAIL=1
	fi
done
[ "$FAIL" = "0" ] && echo "ok: 无容量绑定描述"

# 场景字样（学校/高校/宿舍/校园）在文档中不得出现
HITS2=$(grep -rn "校园\|学校\|高校\|宿舍" "$D" "$ROOT/README.md" 2>/dev/null | grep -v upstream)
[ -z "$HITS2" ] && echo "ok: 无场景字样" || { echo "FAIL: 文档仍有场景字样"; echo "$HITS2" | head -3; FAIL=1; }

# 泛化说法必须存在
grep -q "容量任意" "$ROOT/README.md" && echo "ok: README 声明容量任意" || { echo "FAIL: README 未声明容量任意"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "DOCS-GENERIC OK" || echo "DOCS-GENERIC FAILED"
exit $FAIL
