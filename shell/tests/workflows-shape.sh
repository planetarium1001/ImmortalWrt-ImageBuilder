#!/bin/sh
# ac-2：workflow 只剩构建与清理两个，命名符合约定
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W="$ROOT/.github/workflows"
FAIL=0

count=$(ls "$W" | wc -l | tr -d ' ')
[ "$count" = "2" ] && echo "ok: workflow 数量为 2" || { echo "FAIL: workflow 数量为 $count"; ls "$W"; FAIL=1; }

[ -f "$W/Build-N5105-x86_64-25.12.x.yml" ] && echo "ok: 构建 workflow 命名正确" || { echo "FAIL: 缺 Build-N5105-x86_64-25.12.x.yml"; FAIL=1; }
[ -f "$W/Cleanup-Old-Workflow-Runs.yml" ] && echo "ok: 清理 workflow 命名正确" || { echo "FAIL: 缺 Cleanup-Old-Workflow-Runs.yml"; FAIL=1; }

B="$W/Build-N5105-x86_64-25.12.x.yml"
grep -q "^name: Build N5105 x86_64 25.12.x" "$B" && echo "ok: 显示名正确" || { echo "FAIL: 显示名未更新"; FAIL=1; }
grep -q "ext4-combined-efi.img.gz" "$B" && echo "ok: 仍上传 ext4 产物" || { echo "FAIL: 未上传 ext4 产物"; FAIL=1; }
grep -q "custom/custom_router_ip.txt:/home/build/immortalwrt/files/etc/config/custom_router_ip.txt" "$B" \
	&& echo "ok: custom 单文件挂载未被改回整目录" || { echo "FAIL: custom 挂载方式回退"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "WORKFLOWS OK" || echo "WORKFLOWS FAILED"
exit $FAIL
