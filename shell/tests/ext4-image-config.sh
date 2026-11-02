#!/bin/sh
# ac-1 的本地部分：确认构建配置会产出 ext4 镜像，并确认 workflow 上传该产物。
# 注意：真实产物需要 CI 跑一次构建，本脚本只校验配置链路。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0
cfg="$ROOT/x86-64/imm25.config"
wf="$ROOT/.github/workflows/Build-N5105-x86_64-25.12.x.yml"
build="$ROOT/x86-64/build25.sh"

grep -q '^CONFIG_TARGET_ROOTFS_EXT4FS=y' "$cfg" && echo "ok: 目标配置启用 ext4" || { echo "FAIL: ext4 未启用"; FAIL=1; }
grep -q '^CONFIG_USES_EXT4=y' "$cfg" && echo "ok: USES_EXT4=y" || { echo "FAIL: USES_EXT4 未置位"; FAIL=1; }
grep -q 'EXTRA_IMAGE_NAME="n5105"' "$build" && echo "ok: 产物名带 n5105" || { echo "FAIL: 产物名未设置"; FAIL=1; }
grep -q 'ext4-combined-efi.img.gz' "$wf" && echo "ok: workflow 上传 ext4 产物" || { echo "FAIL: workflow 未上传 ext4"; FAIL=1; }
grep -q "ROOTFS_PARTSIZE=\$PROFILE" "$build" && echo "ok: 根分区大小可配" || { echo "FAIL: 根分区大小不可配"; FAIL=1; }

# 产物名拼装：n5105 在 IMG_PREFIX（文件名前缀），ext4-combined-efi 在尾部；
# workflow 的 glob 必须能匹配这种形状，README 也按这个形状写。
prefix=$(grep -o 'EXTRA_IMAGE_NAME="[^"]*"' "$build" | head -1 | sed 's/.*="//;s/"//')
expected="immortalwrt-25.12.2-${prefix}-x86-64-generic-ext4-combined-efi.img.gz"
case "$expected" in
	*ext4-combined-efi.img.gz) echo "ok: 产物名形状 $expected" ;;
	*) echo "FAIL: 产物名形状异常 $expected"; FAIL=1 ;;
esac
grep -qF "immortalwrt-25.12.2-n5105-x86-64-generic-ext4-combined-efi.img.gz" "$ROOT/README.md" \
	&& echo "ok: README 产物名与实际一致" || { echo "FAIL: README 产物名与实际不一致"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "EXT4-CONFIG OK（真实产物需 CI 构建验证）" || echo "EXT4-CONFIG FAILED"
exit $FAIL
