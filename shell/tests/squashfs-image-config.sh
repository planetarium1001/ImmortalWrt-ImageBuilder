#!/bin/sh
# ac-1 的本地部分：交付根是 squashfs 只读根（不再是 ext4 单分区），根分区固定 512 MiB，
# CI 不再让人选 profile、只发布 squashfs 产物。真实产物仍需 CI 跑一次构建，
# 本脚本只把"配置链路"钉死；README 里的产物名由 docs-overlay.sh（另一个单元）断言。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

CFG="$REPO/x86-64/imm25.config"
BUILD="$REPO/x86-64/build25.sh"
WF="$REPO/.github/workflows/Build-N5105-x86_64-25.12.x.yml"

# 权威包清单：与 check-packages.sh 同口径（build25.sh 的 PACKAGES 才是 make image 的输入）
pkgs=$(sed -n 's/^PACKAGES="\$PACKAGES \(.*\)"$/\1/p' "$BUILD" | tr ' ' '\n' | grep -v '^\$' | grep -v '^$')

echo "== imm25.config：squashfs 根开、ext4 根关 =="
if grep -qx 'CONFIG_TARGET_ROOTFS_SQUASHFS=y' "$CFG"; then
	ok "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
else
	bad "imm25.config 未启用 squashfs 根（CONFIG_TARGET_ROOTFS_SQUASHFS=y）"
fi
if grep -qx 'CONFIG_USES_SQUASHFS=y' "$CFG"; then
	ok "CONFIG_USES_SQUASHFS=y"
else
	bad "imm25.config 缺 CONFIG_USES_SQUASHFS=y"
fi
live=$(grep -E '^CONFIG_(TARGET_ROOTFS_EXT4FS|USES_EXT4)=' "$CFG")
eq "ext4 根没有生效的 =y 行" '' "$live"
for k in CONFIG_TARGET_ROOTFS_EXT4FS CONFIG_USES_EXT4; do
	if grep -qx "# $k is not set" "$CFG"; then
		ok "显式关闭 $k"
	else
		bad "imm25.config 未显式关闭 ${k}（应为「# ${k} is not set」）"
	fi
done

echo "== build25.sh：根分区固定 512 MiB、产物名与 profile 固定 =="
if grep -qE 'ROOTFS_PARTSIZE=512([^0-9]|$)' "$BUILD"; then
	ok "make image 固定 ROOTFS_PARTSIZE=512"
else
	bad "build25.sh 的 make image 未固定 ROOTFS_PARTSIZE=512"
fi
if grep -q 'ROOTFS_PARTSIZE=\$PROFILE' "$BUILD"; then
	bad "build25.sh 仍从 \$PROFILE 取根分区大小（改尺寸会让升级整盘覆写）"
else
	ok "根分区大小不再是外部可变的 \$PROFILE"
fi
if grep -qE 'ROOTFS_PARTSIZE=\$\{?[A-Za-z_]' "$BUILD"; then
	bad "ROOTFS_PARTSIZE 仍是变量（必须固定为 512）"
else
	ok "ROOTFS_PARTSIZE 不是变量"
fi
# .config 里的同名默认值也要一致：本地 `make image` 不带 ROOTFS_PARTSIZE 时不能漂回 300 MiB
if grep -qx 'CONFIG_TARGET_ROOTFS_PARTSIZE=512' "$CFG"; then
	ok "imm25.config 的 TARGET_ROOTFS_PARTSIZE 也是 512"
else
	bad "imm25.config 的 CONFIG_TARGET_ROOTFS_PARTSIZE 不是 512（本地构建会与 CI 分叉）"
fi
for pair in 'PROFILE="generic"' 'EXTRA_IMAGE_NAME="n5105"' 'FILES="/home/build/immortalwrt/files"'; do
	if grep -qF "$pair" "$BUILD"; then
		ok "make image 仍带 $pair"
	else
		bad "make image 丢了 $pair"
	fi
done

echo "== build25.sh：PACKAGES 含 btrfs 三包 =="
for p in kmod-fs-btrfs btrfs-progs gdisk; do
	if printf '%s\n' "$pkgs" | grep -qx "$p"; then
		ok "PACKAGES 含 $p"
	else
		bad "PACKAGES 缺 ${p}（ImageBuilder 下 .config 的 CONFIG_PACKAGE_* 无效，必须写在这里）"
	fi
done

echo "== workflow：去掉 profile 选择，只发布 squashfs 产物 =="
if grep -qE '^[[:space:]]+profile:' "$WF"; then
	bad "workflow 仍有 profile 输入"
else
	ok "workflow 已去掉 profile 输入"
fi
for pat in 'inputs\.profile' 'ROOTFS_SIZE'; do
	if grep -qE "$pat" "$WF"; then
		bad "workflow 仍残留 profile 相关写法（${pat}）"
	else
		ok "workflow 无 $pat"
	fi
done
if grep -qE "'(1G|2G|3G|4G)'" "$WF"; then
	bad "workflow 仍有 1G/2G/3G/4G 尺寸映射"
else
	ok "workflow 无 1G/2G/3G/4G 尺寸映射"
fi
if grep -qF 'squashfs-combined-efi.img.gz' "$WF"; then
	ok "workflow 上传 squashfs 产物"
else
	bad "workflow 未上传 squashfs 产物"
fi
if grep -qF 'ext4-combined-efi' "$WF"; then
	bad "workflow 仍上传/or 提及 ext4 产物（本期只交付 squashfs）"
else
	ok "workflow 不再涉及 ext4 产物"
fi

# 产物名形状：n5105 在 IMG_PREFIX（文件名前缀），squashfs-combined-efi 在尾部；
# workflow 的 glob 必须能匹配这种形状。
prefix=$(grep -o 'EXTRA_IMAGE_NAME="[^"]*"' "$BUILD" | head -1 | sed 's/.*="//;s/"//')
expected="immortalwrt-25.12.2-${prefix}-x86-64-generic-squashfs-combined-efi.img.gz"
case "$expected" in
*squashfs-combined-efi.img.gz) ok "产物名形状 $expected" ;;
*) bad "产物名形状异常 $expected" ;;
esac

finish SQUASHFS-IMAGE-CONFIG
