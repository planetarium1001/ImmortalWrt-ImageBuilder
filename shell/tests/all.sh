#!/bin/sh
# 一次跑完所有可离线验证的验收测试。
# 退出码：0 全通过；1 有失败；2 有未完成（PENDING，例如依赖实机或未产出）。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail=0; pending=0
for t in ext4-image-config check-packages portmap uci-defaults-idempotent \
         minieap-config wandetect-vote campus-guard-toggle nikki-feed check-static \
         nat66-native no-auto-disk docs-complete; do
	sh "$ROOT/shell/tests/$t.sh" >/tmp/t.out 2>&1
	rc=$?
	case $rc in
		0) echo "PASS  $t" ;;
		2) echo "PEND  $t"; pending=$((pending+1)) ;;
		*) echo "FAIL  $t"; sed 's/^/      /' /tmp/t.out | tail -12; fail=$((fail+1)) ;;
	esac
done
echo "---"
echo "fail=$fail pending=$pending"
[ $fail -gt 0 ] && exit 1
[ $pending -gt 0 ] && exit 2
exit 0
