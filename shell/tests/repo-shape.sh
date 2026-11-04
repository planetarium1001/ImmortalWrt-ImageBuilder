#!/bin/sh
# ac-1：仓库只保留 N5105 相关资产
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

for d in arch armsr-armv8 glinet mediatek-filogic model n1 raspberrypi rockchip sunxi-cortexa53; do
	if [ -e "$ROOT/$d" ]; then echo "FAIL: 仍存在无关平台目录 $d"; FAIL=1; fi
done
[ "$FAIL" = "0" ] && echo "ok: 无无关平台目录"

for f in x86-64/build24.sh x86-64/imm.config shell/custom-packages.sh \
         shell/prepare-packages.sh shell/switch_repository.sh SUPPORT.md info.md; do
	if [ -e "$ROOT/$f" ]; then echo "FAIL: 仍存在遗留文件 $f"; FAIL=1; fi
done
[ "$FAIL" = "0" ] && echo "ok: 无遗留脚本与文档"

for f in x86-64/build25.sh x86-64/imm25.config README.md README.upstream.md \
         PACKAGES.upstream.md LICENSE files/etc/uci-defaults/99-custom.sh \
         files/usr/sbin/ipv6mode shell/nikki-repo.sh; do
	if [ -e "$ROOT/$f" ]; then :; else echo "FAIL: 缺少必需文件 $f"; FAIL=1; fi
done
[ "$FAIL" = "0" ] && echo "ok: 必需文件齐全"

[ "$FAIL" = "0" ] && echo "REPO-SHAPE OK" || echo "REPO-SHAPE FAILED"
exit $FAIL
