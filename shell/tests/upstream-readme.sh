#!/bin/sh
# ac-6：上游 README 原样留存，未被改写
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
U="$ROOT/README.upstream.md"
P="$ROOT/PACKAGES.upstream.md"
FAIL=0

[ -s "$U" ] && echo "ok: README.upstream.md 存在" || { echo "FAIL: README.upstream.md 缺失"; FAIL=1; }
[ -s "$P" ] && echo "ok: PACKAGES.upstream.md 存在" || { echo "FAIL: PACKAGES.upstream.md 缺失"; FAIL=1; }

# 上游特征的句子必须在，且不该被我们的定制内容替换
grep -q "AutoBuildImmortalWrt" "$U" && echo "ok: 含上游项目名" || { echo "FAIL: 上游项目名丢失"; FAIL=1; }
grep -q "与 ImmortalWrt 官方没有关联" "$U" && echo "ok: 上游免责原句保留" || { echo "FAIL: 上游免责原句丢失"; FAIL=1; }
grep -q "wukongdaily" "$U" && echo "ok: 含上游作者署名" || { echo "FAIL: 上游署名丢失"; FAIL=1; }

# 上游文件不应出现本项目专有内容，否则说明被误改
if grep -q "minieap.conf\|N5105 v5 四网口" "$U"; then
	echo "FAIL: README.upstream.md 被写入了本项目的定制内容"; FAIL=1
else
	echo "ok: 上游 README 未被混入定制内容"
fi

[ "$FAIL" = "0" ] && echo "UPSTREAM-README OK" || echo "UPSTREAM-README FAILED"
exit $FAIL
