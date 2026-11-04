#!/bin/sh
# ac-9：离线校验构建脚本语法、包名、关键包与 owut 关闭状态。
#
# 口径（Lead 裁决）：`x86-64/build25.sh` 的 PACKAGES 是**唯一权威**软件清单
# （构建时 `make image PACKAGES=...`）；`x86-64/imm25.config` 只是 ImageBuilder 的
# defconfig 底稿（内核/构建选项）。因此**不做**"build25.sh ⊆ imm25.config"这类断言
# ——audit B1 的"44 个包未在 config 里选中"是两套清单的分工，不是缺陷。
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0
BUILD="$ROOT/x86-64/build25.sh"
CFG="$ROOT/x86-64/imm25.config"

ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; FAIL=1; }

# ---- 1. 语法 ----
for f in "$BUILD" "$ROOT/files/usr/sbin/swapctl" \
	"$ROOT/files/usr/sbin/ipv6mode" "$ROOT/files/usr/sbin/netprofile" \
	"$ROOT/files/lib/functions/netports.sh" \
	"$ROOT/files/etc/uci-defaults/99-custom.sh" \
	"$ROOT/files/etc/uci-defaults/98-campus-nft.sh" \
	"$ROOT/files/etc/campus/nft/render.sh" \
	"$ROOT/files/etc/init.d/minieap" "$ROOT/files/usr/sbin/nicsync"; do
	if sh -n "$f" 2>/dev/null; then ok "syntax ${f#"$ROOT"/}"; else bad "syntax ${f#"$ROOT"/}"; fi
done

# ---- 2. 权威清单：抽出 build25.sh 的 PACKAGES ----
pkgs=$(sed -n 's/^PACKAGES="\$PACKAGES \(.*\)"$/\1/p' "$BUILD" | tr ' ' '\n' | grep -v '^\$' | sort -u)
[ -n "$pkgs" ] || bad "build25.sh 里抽不到 PACKAGES"
echo "包数量: $(echo "$pkgs" | wc -l | tr -d ' ')"

# 2a. 包名必须在允许清单内（防止拼写错误的包名进镜像）
ALLOW="$ROOT/shell/tests/allowed-packages.txt"
[ -f "$ALLOW" ] || { echo "FAIL: 缺少 $ALLOW"; exit 1; }
for p in $pkgs; do
	if ! grep -qx "$p" "$ALLOW"; then bad "未在允许清单中的包: $p"; fi
done
[ "$FAIL" = "0" ] && ok "所有包名都在允许清单内"

# 2b. 关键包必须在权威清单里（缺一个就等于功能缺失）
for p in minieap parted sfdisk zram-swap kmod-nft-tproxy nikki; do
	if printf '%s\n' "$pkgs" | grep -qx "$p"; then
		ok "关键包在权威清单: $p"
	else
		bad "关键包缺失: $p（build25.sh 的 PACKAGES 里必须有）"
	fi
done

# ---- 3. imm25.config：owut 必须未选（25.12 + apk 的 ImageBuilder 下不可用）----
if grep -qx '# CONFIG_PACKAGE_owut is not set' "$CFG"; then
	ok "owut 未选（# CONFIG_PACKAGE_owut is not set）"
else
	bad "$CFG 里 owut 未被显式关掉"
fi
if grep -q '^CONFIG_PACKAGE_owut=' "$CFG"; then
	bad "$CFG 里 owut 被选中"
else
	ok "owut 未出现在已选包中"
fi

# ---- 4. imm25.config 头部必须声明"非权威包清单"并指向 build25.sh ----
if head -5 "$CFG" | grep -q '本文件非权威包清单' && head -5 "$CFG" | grep -q 'build25\.sh'; then
	ok "imm25.config 头部声明了权威清单在 x86-64/build25.sh"
else
	bad "imm25.config 头部缺少「本文件非权威包清单，权威清单在 x86-64/build25.sh」说明"
fi

[ "$FAIL" = "0" ] && echo "PACKAGES OK" || echo "PACKAGES FAILED"
exit $FAIL
