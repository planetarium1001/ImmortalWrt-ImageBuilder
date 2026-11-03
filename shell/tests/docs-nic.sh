#!/bin/sh
# ac-5：文档给出顺序确认与改口步骤，且不再宣传重命名
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D="$ROOT/docs"
FAIL=0

grep -q "不重命名网卡" "$D/network.md" && echo "ok: 说明不重命名" || { echo "FAIL: 缺设计说明"; FAIL=1; }
grep -q "eth0.*WAN\|WAN.*eth0" "$D/network.md" && echo "ok: 默认约定" || { echo "FAIL: 缺默认约定"; FAIL=1; }
grep -q "nicsync" "$D/network.md" && echo "ok: 提到自检脚本" || { echo "FAIL: 缺自检说明"; FAIL=1; }
grep -q "uci set network.wan.device" "$D/network.md" && echo "ok: 给改口命令" || { echo "FAIL: 缺改口命令"; FAIL=1; }

if grep -rq "init.d/portmap" "$D" 2>/dev/null; then
	echo "FAIL: 文档仍提 portmap init"; FAIL=1
else
	echo "ok: 无过时引用"
fi

[ "$FAIL" = "0" ] && echo "DOCS-NIC OK" || echo "DOCS-NIC FAILED"
exit $FAIL
