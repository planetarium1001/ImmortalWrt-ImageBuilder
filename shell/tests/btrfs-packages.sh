#!/bin/sh
# ac-2：btrfs 写层必需的包必须进**权威清单**（x86-64/build25.sh 的 PACKAGES），并被
# shell/tests/allowed-packages.txt 收录。
#   kmod-fs-btrfs / btrfs-progs  模块与子卷命令（mkfs.btrfs / btrfs）
#   gdisk / sgdisk               gptfdisk 拆成 4 个独立包！overlay-setup 真正调用的是
#                                **sgdisk**（-e 挪 GPT 备份头、-n 建 p3），只装 gdisk 会
#                                在首启报 "sgdisk: not found"（2026-11-05 真机实证）
#   chattr / lsattr              25.12 里是独立 apk 包（不在 e2fsprogs），用于给
#                                @docker/@swap 置 NOCOW 并复核；缺了 swapfile 会 swapon 失败
#
# 为什么不能写在 imm25.config：那里的 CONFIG_PACKAGE_* 对被 `make image PACKAGES=...`
# 选中的包完全不生效（已核实），写进去只会制造"看起来已经选上"的假象。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

BUILD="$REPO/x86-64/build25.sh"
ALLOW="$REPO/shell/tests/allowed-packages.txt"
CFG="$REPO/x86-64/imm25.config"

# ac-2 要求的包（两处清单都必须有）
NEEDED="kmod-fs-btrfs btrfs-progs gdisk sgdisk chattr lsattr"

# 与 check-packages.sh 同口径抽取 PACKAGES（唯一权威清单）
pkgs=$(sed -n 's/^PACKAGES="\$PACKAGES \(.*\)"$/\1/p' "$BUILD" | tr ' ' '\n' | grep -v '^\$' | grep -v '^$')

echo "== PACKAGES 里有 btrfs 写层全部包 =="
for p in $NEEDED; do
	if printf '%s\n' "$pkgs" | grep -qx "$p"; then
		ok "PACKAGES 含 $p"
	else
		bad "PACKAGES 缺 $p"
	fi
done

echo "== 每个包各只声明一次（无重复行）=="
for p in $NEEDED; do
	n=$(printf '%s\n' "$pkgs" | grep -cx "$p")
	eq "$p 在 PACKAGES 中出现次数" 1 "$n"
done

echo "== 二进制 → 包 的映射必须成立（防止"包名写对、二进制没有"）=="
# 2026-11-05 真机事故：PACKAGES 里写的是 gdisk，而 overlay-setup 调用的是 sgdisk，
# gptfdisk 把它们拆成了两个包 ⇒ 断言"字符串 gdisk 存在"完全没能拦住。
# 这里按**脚本实际调用的二进制**反推它要求哪个包。
mapping='sgdisk:sgdisk
mkfs.btrfs:btrfs-progs
btrfs:btrfs-progs
chattr:chattr
lsattr:lsattr'
printf '%s\n' "$mapping" | while IFS=: read -r bin pkg; do
	# 脚本里有调用该二进制（含默认值赋值 SGDISK=${SGDISK:-sgdisk} 这种）
	if grep -qE "(^|[^a-zA-Z0-9_.-])$bin([^a-zA-Z0-9_.-]|$)" "$REPO/files/usr/sbin/overlay-setup" \
		|| grep -qE "(^|[^a-zA-Z0-9_.-])$bin([^a-zA-Z0-9_.-]|$)" "$REPO/files/etc/init.d/btrfs-subvols" \
		|| grep -qE "(^|[^a-zA-Z0-9_.-])$bin([^a-zA-Z0-9_.-]|$)" "$REPO/files/usr/sbin/swapctl"; then
		if printf '%s\n' "$pkgs" | grep -qx "$pkg"; then
			echo "  ok   脚本调用 $bin → PACKAGES 含 $pkg"
		else
			echo "  FAIL 脚本调用 ${bin}，但 PACKAGES 缺 $pkg"
			FAIL=1
		fi
	fi
done

echo "== allowed-packages.txt 收录 =="
if [ -f "$ALLOW" ]; then
	for p in $NEEDED; do
		if grep -qx "$p" "$ALLOW"; then
			ok "allowlist 收录 $p"
		else
			bad "allowlist 缺 ${p}（check-packages.sh 会红）"
		fi
	done
	dups=$(LC_ALL=C sort "$ALLOW" | uniq -d)
	eq "allowlist 无重复行" '' "$dups"
	if LC_ALL=C sort -c "$ALLOW" 2>/dev/null; then
		ok "allowlist 保持 C 序"
	else
		bad "allowlist 未按 C 序排列"
	fi
else
	bad "缺少 $ALLOW"
fi

echo "== imm25.config 里的 btrfs 开关都标注了「对 ImageBuilder 无效」 =="
# 只查"看起来像选包/选内核"的行：# CONFIG_KERNEL_BTRFS_FS*、CONFIG_PACKAGE_<包名>=...
# 不标注就会被后人当成有效开关（实测无效：内核预编译、CONFIG_PACKAGE_* 对 make image 无效）。
unmarked=$(awk '
	{ buf[NR % 6] = $0 }
	/CONFIG_(KERNEL_BTRFS_FS|PACKAGE_(kmod-fs-btrfs|btrfs-progs|gdisk|chattr|lsattr)=)/ {
		found = 0
		for (i = 1; i <= 5; i++) if (buf[(NR - i) % 6] ~ /ImageBuilder/) found = 1
		if (!found) print NR ": " $0
	}
' "$CFG")
eq "btrfs 开关附近有「ImageBuilder」说明" '' "$unmarked"

finish BTRFS-PACKAGES
