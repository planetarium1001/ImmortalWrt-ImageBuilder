#!/bin/sh
# 一次跑完所有可离线验证的验收测试。
# 退出码：0 全通过；1 有失败；2 有未完成（PENDING，例如依赖实机或未产出）。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail=0; pending=0
for t in repo-shape workflows-shape readme-shape readme-flow upstream-readme squashfs-image-config btrfs-packages btrfs-preinit-order btrfs-fstab-config overlay-setup overlay-subvols overlay-reset sysupgrade-layout swapctl-space check-packages uci-fake uci-defaults-idempotent uci-defaults-nic minieap-native nikki-feed check-static no-site-words no-legacy-config no-extra-modules no-override-config no-rename no-iptables netports-truth netports-fail-closed nicsync nicsync-idempotent nicsync-warn ipv6mode ipv6mode-memory netprofile-switch netprofile-memory netprofile-templates netprofile-render netprofile-rollback minieap-empty-conf minieap-skip wan-auto hostname docs-native docs-nic docs-auth docs-profile nat66-native no-auto-disk docs-complete docs-overlay campus-include-values campus-rules-scope device-verify device-upgrade-check; do
	sh "$ROOT/shell/tests/$t.sh" >/tmp/t.out 2>&1
	rc=$?
	case $rc in
		0) echo "PASS  $t" ;;
		2) echo "PEND  $t"; sed 's/^/      /' /tmp/t.out | tail -3; pending=$((pending+1)) ;;
		*) echo "FAIL  $t"; sed 's/^/      /' /tmp/t.out | tail -12; fail=$((fail+1)) ;;
	esac
done
echo "---"
echo "fail=$fail pending=$pending"
[ $fail -gt 0 ] && exit 1
[ $pending -gt 0 ] && exit 2
exit 0
