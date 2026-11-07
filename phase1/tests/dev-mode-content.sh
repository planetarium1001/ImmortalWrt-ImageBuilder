#!/bin/sh
# ac-4：dev / prod 两种镜像内容的离线用例（只走 build.sh 的 --prepare-rootfs 与全桩路径）。
#
# 判据是"**镜像里**有没有"，所以这里断言的是落进 rootfs tree 的东西：
#   ① dev 的 firewall 规则必须**构建期**就写进 /etc/config/firewall（不是只在首启脚本里写）
#   ② dev/prod 的差异（DEV-IMAGE / 90-dev-image / dev-open-wan）静态可判定
#   ③ 注入不破坏原有文件、挂载点内容不进来、同一夹具跑两次结果一致
# 并真跑两侧脚本：
#   * 90-dev-image 用 shell/tests/lib-uci-stub.sh（真 UCI 语义）跑两遍，证明判重/幂等
#   * make-initramfs.sh / assemble-image.sh 换成记录型桩，让 build.sh 走完整条流水线，
#     再把真跑的 argv 与 --dry-run 打印的 argv 逐字比对（含 INIT_SHA 取证那条渲染命令）
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

BUILD=$REPO/phase1/build.sh
AS=$REPO/phase1/assemble-image.sh
UCI_STUB=$REPO/shell/tests/lib-uci-stub.sh
NAME='phase1-dev-mode-content'
KVER=6.12.103
LIBUBOX_VER=20251231

for _f in "$BUILD" "$UCI_STUB"; do
	[ -f "$_f" ] || {
		printf '  FAIL 缺少 %s\n' "$_f"
		finish "$NAME"
	}
done

SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sb-devcontent.XXXXXX" 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 2
}
FIX=$SB_ROOT/fixture
KERNEL=$SB_ROOT/vmlinuz.stub
: >"$KERNEL"
# 固定渲染输入：两次构建的 /etc/DEV-IMAGE 必须逐字节可比
BUILD_TIME=2026-11-07T00:00:00Z
GIT_SHA=tests
export BUILD_TIME GIT_SHA

MODS_BTRFS='xxhash zstd_common zstd_compress zstd_decompress raid6_pq lzo_compress lzo_decompress xor libcrc32c btrfs'
MODS_FS='vfat fat nls_cp437 nls_iso8859-1 nls_utf8'

sha_of() { # <文件>
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

# ---------------------------------------------------------------------------
# 夹具：一个"像 rootfs 的最小树"（够 build.sh 全流水线通过 STAGE 校验）
# ---------------------------------------------------------------------------
make_fixture() { # <目录> [libubox 版本]
	_d=$1
	_lu=${2:-$LIBUBOX_VER}
	mkdir -p "$_d/etc/config" "$_d/etc/uci-defaults" "$_d/bin" "$_d/sbin" "$_d/lib" \
		"$_d/usr/lib" "$_d/usr/bin" "$_d/lib/modules/$KVER" \
		"$_d/proc/self" "$_d/sys/kernel" "$_d/dev" "$_d/tmp" "$_d/boot"

	# 上游风格的 UCI 文本（lib-uci-stub.sh 直接解析这种真格式）
	{
		printf 'package system\n\n'
		printf 'config system\n'
		printf "\toption hostname 'TestRouter'\n"
		printf "\toption timezone 'UTC'\n"
	} >"$_d/etc/config/system"
	{
		printf 'package firewall\n\n'
		printf 'config defaults\n'
		printf "\toption input 'REJECT'\n\n"
		printf 'config zone\n'
		printf "\toption name 'wan'\n"
		printf "\toption input 'REJECT'\n"
		printf "\toption output 'ACCEPT'\n"
		printf "\toption forward 'REJECT'\n"
	} >"$_d/etc/config/firewall"
	printf '#!/bin/sh\n# 夹具自带的另一个首启脚本，注入后必须还在\nexit 0\n' \
		>"$_d/etc/uci-defaults/50-fixture-defaults"
	chmod 755 "$_d/etc/uci-defaults/50-fixture-defaults"

	# 挂载点里的"宿主内容"：必须被排除（与 assemble-image.sh 的 extract_rootfs 同一份清单）
	echo 'host-only 不该进镜像' >"$_d/proc/host-only"
	echo 'host-only 不该进镜像' >"$_d/sys/host-only"
	echo 'host-only 不该进镜像' >"$_d/dev/host-only"

	# STAGE 载荷（内容是假的，build.sh 只搬不解析）
	printf 'fake-busybox\n' >"$_d/bin/busybox"
	printf 'fake-ld-musl\n' >"$_d/lib/ld-musl-x86_64.so.1"
	printf 'fake-libc\n' >"$_d/lib/libc.so"
	printf 'fake-libubox\n' >"$_d/lib/libubox.so.${_lu}"
	printf 'fake-libgcc\n' >"$_d/lib/libgcc_s.so.1"
	printf 'fake-kmodloader\n' >"$_d/sbin/kmodloader"
	for _a in modprobe insmod rmmod lsmod; do
		ln -s kmodloader "$_d/sbin/$_a"
	done
	for _m in $MODS_BTRFS $MODS_FS; do
		printf 'fake-ko %s\n' "$_m" >"$_d/lib/modules/$KVER/$_m.ko"
	done
	: >"$_d/lib/modules/$KVER/modules.builtin"
	: >"$_d/lib/modules/$KVER/modules.builtin.modinfo"
	printf 'fake-getfattr\n' >"$_d/usr/bin/getfattr"
	printf 'fake-setfattr\n' >"$_d/usr/bin/setfattr"
	printf 'fake-libattr\n' >"$_d/usr/lib/libattr.so.1"
	chmod 755 "$_d/bin/busybox" "$_d/sbin/kmodloader" "$_d/usr/bin/getfattr" "$_d/usr/bin/setfattr"
}

make_fixture "$FIX"

run_build() { # <输出文件> <参数...>：跑 build.sh（合并输出），返回码放 RC
	_out=$1
	shift
	if sh "$BUILD" "$@" >"$_out" 2>&1; then
		RC=0
	else
		RC=$?
	fi
}

# ---------------------------------------------------------------------------
# 1. dev：三件套 + **构建期** firewall 规则 + firstboot；原有文件不能被破坏
# ---------------------------------------------------------------------------
echo "== 1. dev 注入内容（firewall 规则必须是构建期就写进去的）=="
run_build "$SB_ROOT/dev.log" --type dev --prepare-rootfs "$SB_ROOT/dev" \
	--rootfs "$FIX" --kernel "$KERNEL" --image-out /dev/null --size 8G
eq "dev prepare 退出 0" '0' "$RC"

DEV=$SB_ROOT/dev
DEV_FW=$DEV/etc/config/firewall
eq "etc/DEV-IMAGE 存在" 'yes' "$([ -f "$DEV/etc/DEV-IMAGE" ] && echo yes || echo no)"
contains "DEV-IMAGE 标明 type=dev" 'type=dev' "$(cat "$DEV/etc/DEV-IMAGE" 2>/dev/null)"
contains "DEV-IMAGE 带构建时间（build.sh 渲染）" 'built_at=2026-11-07T00:00:00Z' "$(cat "$DEV/etc/DEV-IMAGE" 2>/dev/null)"
contains "DEV-IMAGE 带提交号（build.sh 渲染）" 'git_sha=tests' "$(cat "$DEV/etc/DEV-IMAGE" 2>/dev/null)"
eq "DEV-IMAGE 没有残留 @占位符@" '' "$(grep -Eo '@[A-Z][A-Z0-9_]*@' "$DEV/etc/DEV-IMAGE" 2>/dev/null | sort -u | tr '\n' ' ')"
eq "DEV-IMAGE.in 模板本身不进镜像" 'no' "$([ -e "$DEV/etc/DEV-IMAGE.in" ] && echo yes || echo no)"

echo "-- dev 的 firewall：规则在镜像里（不是等首启）--"
contains "镜像 firewall 含 dev-open-wan" "option name 'dev-open-wan'" "$(cat "$DEV_FW")"
contains "镜像 firewall 规则 src=wan" "option src 'wan'" "$(cat "$DEV_FW")"
contains "镜像 firewall 规则 proto=all" "option proto 'all'" "$(cat "$DEV_FW")"
contains "镜像 firewall 规则 target=ACCEPT" "option target 'ACCEPT'" "$(cat "$DEV_FW")"
contains "原有 wan zone 没被整份替换掉" "option name 'wan'" "$(cat "$DEV_FW")"
contains "原有 defaults 段还在" "config defaults" "$(cat "$DEV_FW")"
eq "只加了一条 dev-open-wan" '1' "$(grep -c "option name 'dev-open-wan'" "$DEV_FW")"
eq "firewall 里没有新旧行粘连（每行以 config/option/空行 开头）" '' \
	"$(grep -vE '^(config |\toption |package |$)' "$DEV_FW" | tr '\n' ' ')"
eq "规则片段 firewall.dev-rule 没有被当成 uci 包拷进镜像" 'no' \
	"$([ -e "$DEV/etc/config/firewall.dev-rule" ] && echo yes || echo no)"
contains "构建日志打印了注入 firewall 规则" '注入 firewall 规则 dev-open-wan' "$(cat "$SB_ROOT/dev.log")"

echo "-- dev 的 90-dev-image / firstboot --"
DEV_UD=$DEV/etc/uci-defaults/90-dev-image
eq "90-dev-image 存在" 'yes' "$([ -f "$DEV_UD" ] && echo yes || echo no)"
eq "90-dev-image 可执行" '-rwxr-xr-x' "$(ls -l "$DEV_UD" 2>/dev/null | cut -c1-10)"
if sh -n "$DEV_UD" 2>/dev/null; then ok "90-dev-image sh -n 通过"; else bad "90-dev-image 语法错误"; fi
contains "90-dev-image 建具名规则 dev-open-wan" 'dev-open-wan' "$(cat "$DEV_UD" 2>/dev/null)"
contains "90-dev-image 规则 src=wan" 'src=wan' "$(cat "$DEV_UD" 2>/dev/null)"
contains "90-dev-image 规则 proto=all" 'proto=all' "$(cat "$DEV_UD" 2>/dev/null)"
contains "90-dev-image 规则 target=ACCEPT" 'target=ACCEPT' "$(cat "$DEV_UD" 2>/dev/null)"
contains "90-dev-image 判重后再加（幂等）" 'grep -q' "$(cat "$DEV_UD" 2>/dev/null)"

GROW=$DEV/etc/uci-defaults/10-grow-p2.sh
eq "dev 有 firstboot 的 10-grow-p2.sh" 'yes' "$([ -f "$GROW" ] && echo yes || echo no)"
eq "10-grow-p2.sh 可执行" '-rwxr-xr-x' "$(ls -l "$GROW" 2>/dev/null | cut -c1-10)"
if sh -n "$GROW" 2>/dev/null; then ok "10-grow-p2.sh sh -n 通过"; else bad "10-grow-p2.sh 语法错误"; fi

echo "-- dev 的调试公钥（无外设设备唯一的登录通道）--"
DEV_AK=$DEV/etc/dropbear/authorized_keys
REPO_AK=$REPO/phase1/dev/rootfs/etc/dropbear/authorized_keys
eq "dev 有 /etc/dropbear/authorized_keys" 'yes' "$([ -f "$DEV_AK" ] && echo yes || echo no)"
eq "/etc/dropbear 目录权限 0700" 'drwx------' "$(ls -ld "$DEV/etc/dropbear" 2>/dev/null | cut -c1-10)"
eq "authorized_keys 权限 0600（检出是 0644，构建期 chmod）" '-rw-------' \
	"$(ls -l "$DEV_AK" 2>/dev/null | cut -c1-10)"
eq "authorized_keys 与仓库公钥逐字节一致" 'same' \
	"$(cmp -s "$DEV_AK" "$REPO_AK" && echo same || echo differ)"
contains "authorized_keys 含项目专用公钥" 'n5105-dev-debug' "$(cat "$DEV_AK" 2>/dev/null)"
eq "authorized_keys 只有一行（不多塞密钥）" '1' "$(awk 'END {print NR}' "$DEV_AK" 2>/dev/null)"
contains "构建日志打印了 dev 调试公钥" 'dev 调试公钥' "$(cat "$SB_ROOT/dev.log")"

eq "原有 etc/config/system 还在" 'yes' "$([ -f "$DEV/etc/config/system" ] && echo yes || echo no)"
eq "原有 etc/config/system 内容未被改" 'same' "$(cmp -s "$FIX/etc/config/system" "$DEV/etc/config/system" && echo same || echo differ)"
eq "原有 etc/uci-defaults/50-fixture-defaults 还在" 'yes' \
	"$([ -f "$DEV/etc/uci-defaults/50-fixture-defaults" ] && echo yes || echo no)"
eq "挂载点 ./proc 里的宿主内容没被拷进镜像" 'no' "$([ -e "$DEV/proc/host-only" ] && echo yes || echo no)"
eq "挂载点 ./sys 里的宿主内容没被拷进镜像" 'no' "$([ -e "$DEV/sys/host-only" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 2. prod：三件套一件都不许有，firstboot 仍必须有，firewall 不许被碰
# ---------------------------------------------------------------------------
echo "== 2. prod 注入内容（与 dev 的差异必须静态可判定）=="
run_build "$SB_ROOT/prod.log" --type prod --prepare-rootfs "$SB_ROOT/prod" \
	--rootfs "$FIX" --kernel "$KERNEL" --image-out /dev/null --size 8G
eq "prod prepare 退出 0" '0' "$RC"
PROD=$SB_ROOT/prod
eq "prod 没有 etc/DEV-IMAGE" 'no' "$([ -e "$PROD/etc/DEV-IMAGE" ] && echo yes || echo no)"
eq "prod 没有 90-dev-image" 'no' "$([ -e "$PROD/etc/uci-defaults/90-dev-image" ] && echo yes || echo no)"
eq "prod 没有 etc/dropbear/authorized_keys（不得带认证材料）" 'no' \
	"$([ -e "$PROD/etc/dropbear/authorized_keys" ] && echo yes || echo no)"
eq "prod 全树没有项目公钥字样" '' \
	"$(grep -rl 'n5105-dev-debug' "$PROD" 2>/dev/null | sed "s#^$PROD##" | tr '\n' ' ')"

echo "-- prod 守卫：rootfs 自带公钥必须硬失败（不是静默通过）--"
FIX_AK=$SB_ROOT/fixture-with-key
mkdir -p "$FIX_AK"
cp -a "$FIX/." "$FIX_AK/"
mkdir -p "$FIX_AK/etc/dropbear"
cp "$REPO_AK" "$FIX_AK/etc/dropbear/authorized_keys"
run_build "$SB_ROOT/prod-key.log" --type prod --prepare-rootfs "$SB_ROOT/prod-key" \
	--rootfs "$FIX_AK" --kernel "$KERNEL" --image-out /dev/null --size 8G
ne "prod 守卫：rootfs 自带公钥 ⇒ 非 0" '0' "$RC"
contains "prod 守卫点名 authorized_keys" 'authorized_keys' "$(cat "$SB_ROOT/prod-key.log")"
contains "prod 守卫提示不得带认证材料" '认证材料' "$(cat "$SB_ROOT/prod-key.log")"
eq "prod 全树没有 dev-open-wan 字样" '' "$(grep -rl 'dev-open-wan' "$PROD" 2>/dev/null | sed "s#^$PROD##" | tr '\n' ' ')"
eq "prod 全树没有 dev_open_wan 字样" '' "$(grep -rl 'dev_open_wan' "$PROD" 2>/dev/null | sed "s#^$PROD##" | tr '\n' ' ')"
eq "prod 的 firewall 与出厂内容逐字节一致（没被 append）" 'same' \
	"$(cmp -s "$FIX/etc/config/firewall" "$PROD/etc/config/firewall" && echo same || echo differ)"
contains "prod 的 hostname 没有 -dev 后缀" "option hostname 'TestRouter'" "$(cat "$PROD/etc/config/system" 2>/dev/null)"
eq "prod 仍有 firstboot 的 10-grow-p2.sh" 'yes' \
	"$([ -f "$PROD/etc/uci-defaults/10-grow-p2.sh" ] && echo yes || echo no)"
eq "prod 仍有夹具原有文件" 'yes' "$([ -f "$PROD/etc/config/system" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 3. 幂等/确定性：同一夹具跑两次，文件清单与渲染结果一致
# ---------------------------------------------------------------------------
echo "== 3. 同一夹具跑两次（确定性）=="
run_build "$SB_ROOT/dev2.log" --type dev --prepare-rootfs "$SB_ROOT/dev2" \
	--rootfs "$FIX" --kernel "$KERNEL" --image-out /dev/null --size 8G
eq "第二次 dev prepare 退出 0" '0' "$RC"
eq "两次 prepare 的文件清单一致" \
	"$(cd "$DEV" && find . ! -type d | LC_ALL=C sort | tr '\n' ' ')" \
	"$(cd "$SB_ROOT/dev2" && find . ! -type d | LC_ALL=C sort | tr '\n' ' ')"
eq "两次 prepare 的 /etc/DEV-IMAGE 逐字节一致" 'same' \
	"$(cmp -s "$DEV/etc/DEV-IMAGE" "$SB_ROOT/dev2/etc/DEV-IMAGE" && echo same || echo differ)"
eq "两次 prepare 的 /etc/config/firewall 逐字节一致（规则不叠加）" 'same' \
	"$(cmp -s "$DEV_FW" "$SB_ROOT/dev2/etc/config/firewall" && echo same || echo differ)"

# ---------------------------------------------------------------------------
# 4. --type 必填/取值受限（不设默认值：避免 dev 被当正式版发出去）
# ---------------------------------------------------------------------------
echo "== 4. --type 必填且只认 dev|prod =="
run_build "$SB_ROOT/notype.log" --prepare-rootfs "$SB_ROOT/x1" --rootfs "$FIX" \
	--kernel "$KERNEL" --image-out /dev/null
ne "缺 --type ⇒ 非 0" '0' "$RC"
contains "缺 --type 的提示里有 usage" '--help' "$(cat "$SB_ROOT/notype.log")"
run_build "$SB_ROOT/badtype.log" --type devv --prepare-rootfs "$SB_ROOT/x2" --rootfs "$FIX" \
	--kernel "$KERNEL" --image-out /dev/null
ne "非法 --type ⇒ 非 0" '0' "$RC"
contains "非法 --type 的提示点出取值" 'dev|prod' "$(cat "$SB_ROOT/badtype.log")"
eq "失败的 prepare 不留下目录" 'no' "$([ -e "$SB_ROOT/x2" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 5. 真跑两侧脚本：90-dev-image（uci = 真 UCI 语义 fake）
# ---------------------------------------------------------------------------
echo "== 5. 真跑 90-dev-image =="
mkdir -p "$SB_ROOT/uci-shim"
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$UCI_STUB" >"$SB_ROOT/uci-shim/uci"
chmod 755 "$SB_ROOT/uci-shim/uci"

run_ud() { # <rootfs> <日志>：以该 rootfs 的 etc/config 为 UCI 库跑首启脚本
	( cd "$1" && PATH="$SB_ROOT/uci-shim:$PATH" UCI_STUB_DIR="$1/etc/config" \
		sh etc/uci-defaults/90-dev-image ) >"$2" 2>&1
}

echo "-- 5a. 构建期已写入规则 ⇒ 首启脚本判重跳过（不叠规则）--"
SYS=$DEV/etc/config/system
_fw_before=$(cksum <"$DEV_FW")
run_ud "$DEV" "$SB_ROOT/ud1.log"
eq "90-dev-image 退出 0" '0' "$?"
eq "firewall 逐字节未变（判重跳过）" "$_fw_before" "$(cksum <"$DEV_FW")"
contains "日志说明规则已存在" '跳过' "$(cat "$SB_ROOT/ud1.log")"
contains "hostname 追加 -dev" "option hostname 'TestRouter-dev'" "$(cat "$SYS")"
_sys_before=$(cksum <"$SYS")
run_ud "$DEV" "$SB_ROOT/ud2.log"
eq "第二次执行 system 逐字节未变（不加第二次 -dev）" "$_sys_before" "$(cksum <"$SYS")"

echo "-- 5b. 兜底路径：规则不在 firewall 里时脚本自己加，且幂等 --"
DEV_FALLBACK=$SB_ROOT/dev-fallback
cp -a "$DEV" "$DEV_FALLBACK"
# 把构建期 append 的规则段去掉（恢复成出厂 firewall）
cp "$FIX/etc/config/firewall" "$DEV_FALLBACK/etc/config/firewall"
cp "$FIX/etc/config/system" "$DEV_FALLBACK/etc/config/system"
run_ud "$DEV_FALLBACK" "$SB_ROOT/ud3.log"
eq "兜底路径退出 0" '0' "$?"
FB_FW=$DEV_FALLBACK/etc/config/firewall
contains "脚本自己补上了 dev-open-wan" "option name 'dev-open-wan'" "$(cat "$FB_FW")"
contains "补上的规则 src=wan" "option src 'wan'" "$(cat "$FB_FW")"
contains "补上的规则 proto=all" "option proto 'all'" "$(cat "$FB_FW")"
contains "补上的规则 target=ACCEPT" "option target 'ACCEPT'" "$(cat "$FB_FW")"
contains "兜底路径也改了 hostname" "option hostname 'TestRouter-dev'" \
	"$(cat "$DEV_FALLBACK/etc/config/system")"
_fb_before=$(cksum <"$FB_FW")
run_ud "$DEV_FALLBACK" "$SB_ROOT/ud4.log"
eq "兜底路径第二次执行 firewall 逐字节未变" "$_fb_before" "$(cksum <"$FB_FW")"
eq "dev-open-wan 仍然只有一条" '1' "$(grep -c "option name 'dev-open-wan'" "$FB_FW")"

# ---------------------------------------------------------------------------
# 6. --dry-run：打印完整 argv（含 STAGE 清单、默认设备名、INIT 取证命令、大小闸）
# ---------------------------------------------------------------------------
echo "== 6. --dry-run 打印完整 argv（默认 nvme0n1p2/p1）=="
DRY=$SB_ROOT/dry.log
run_build "$DRY" --type dev --rootfs "$FIX" --kernel "$KERNEL" \
	--image-out "$SB_ROOT/never.img.gz" --size 8G --dry-run
eq "--dry-run 退出 0" '0' "$RC"
eq "--dry-run 不写产物" 'no' "$([ -e "$SB_ROOT/never.img.gz" ] && echo yes || echo no)"
DRYTEXT=$(cat "$DRY")
contains "打印 STAGE 清单（busybox）" 'STAGE bin/busybox' "$DRYTEXT"
contains "打印 STAGE 清单（btrfs.ko）" "STAGE lib/modules/$KVER/btrfs.ko" "$DRYTEXT"
contains "打印 STAGE 清单（getfattr，缺了要装 attr）" 'STAGE usr/bin/getfattr' "$DRYTEXT"
contains "打印 libubox 的 STAGE 计划（原名）" 'lib/libubox.so.<版本>（原名）' "$DRYTEXT"
contains "打印 INIT 取证渲染命令" 'make-initramfs.sh --render-init-only' "$DRYTEXT"
contains "dry-run 也打印 INIT_SHA（CI 早取证）" 'INIT_SHA=' "$DRYTEXT"
contains "打印 make-initramfs argv" 'make-initramfs.sh --stage' "$DRYTEXT"
contains "initrd 默认 rootdev=nvme0n1p2" '--rootdev /dev/nvme0n1p2' "$DRYTEXT"
contains "initrd 默认 bootdev=nvme0n1p1" '--bootdev /dev/nvme0n1p1' "$DRYTEXT"
contains "initrd bootsub=boot" '--bootsub boot' "$DRYTEXT"
contains "initrd lower=@root" '--lower @root' "$DRYTEXT"
contains "initrd overlay=@overlay" '--overlay @overlay' "$DRYTEXT"
contains "打印 assemble-image argv（--image）" 'assemble-image.sh --image' "$DRYTEXT"
contains "assemble-image 收到 --size 8G" '--size 8G' "$DRYTEXT"
contains "assemble-image 收到 --rootfs" '--rootfs' "$DRYTEXT"
contains "assemble-image 收到 --initrd" '--initrd' "$DRYTEXT"
contains "打印大小闸期望字节数（8G）" '8589934592 bytes' "$DRYTEXT"
contains "打印 gzip -9 -n" 'gzip -9 -n -c' "$DRYTEXT"

echo "== 7. --size 两种写法都要能解析成同一字节数 =="
run_build "$SB_ROOT/dry-m.log" --type prod --rootfs "$FIX" --kernel "$KERNEL" \
	--image-out "$SB_ROOT/never.img.gz" --size 8192M --dry-run
eq "8192M 的 --dry-run 退出 0" '0' "$RC"
contains "8192M 解析成 8589934592 bytes" '8589934592 bytes' "$(cat "$SB_ROOT/dry-m.log")"
run_build "$SB_ROOT/dry-bad.log" --type prod --rootfs "$FIX" --kernel "$KERNEL" \
	--image-out "$SB_ROOT/never.img.gz" --size 8x --dry-run
ne "非法 --size ⇒ 非 0" '0' "$RC"
contains "非法 --size 的提示" '--size 解析不了' "$(cat "$SB_ROOT/dry-bad.log")"

echo "== 8. 设备名可覆盖（--rootdev/--bootdev 只有一处来源）=="
run_build "$SB_ROOT/dry-sda.log" --type dev --rootfs "$FIX" --kernel "$KERNEL" \
	--image-out "$SB_ROOT/never.img.gz" --size 8G --dry-run \
	--rootdev /dev/sda2 --bootdev /dev/sda1
eq "带覆盖的 --dry-run 退出 0" '0' "$RC"
contains "覆盖后的 rootdev 出现在 argv" '--rootdev /dev/sda2' "$(cat "$SB_ROOT/dry-sda.log")"
contains "覆盖后的 bootdev 出现在 argv" '--bootdev /dev/sda1' "$(cat "$SB_ROOT/dry-sda.log")"

# ---------------------------------------------------------------------------
# 9. 全桩真跑：make-initramfs.sh / assemble-image.sh 换成记录型桩
# ---------------------------------------------------------------------------
echo "== 9. 全桩真跑（桩 AS 写 4096 字节 ⇒ --size 4K 才对得上）=="
HARNESS=$SB_ROOT/harness
mkdir -p "$HARNESS/phase1" "$HARNESS/work"
cp "$BUILD" "$HARNESS/phase1/build.sh"
cp -a "$REPO/phase1/dev" "$HARNESS/phase1/dev"
cp -a "$REPO/phase1/firstboot" "$HARNESS/phase1/firstboot"
cat >"$HARNESS/phase1/make-initramfs.sh" <<'STUB'
#!/bin/sh
# 记录型桩：argv 进 $STUB_ARGV_LOG；--render-init-only 写定形 /init；--out 造假 initrd
_argv=$*
printf 'sh %s %s\n' "$0" "${_argv}" >>"${STUB_ARGV_LOG:?}"
_r=''
_out=''
_params=''
while [ "$#" -gt 0 ]; do
	case $1 in
	--render-init-only) _r=$2; shift 2 ;;
	--render-init-only=*) _r=${1#--render-init-only=}; shift ;;
	--out) _out=$2; shift 2 ;;
	--out=*) _out=${1#--out=}; shift ;;
	*) _params="${_params} $1"; shift ;;
	esac
done
if [ -n "$_r" ]; then
	mkdir -p "$(dirname "$_r")"
	# 内容只取决于**参数**（不含输出路径）⇒ dry-run 与真跑的 INIT_SHA 可以直接比
	printf '#!/bin/sh\n# stub /init params:%s\n' "${_params}" >"$_r"
	chmod 755 "$_r"
	exit 0
fi
[ -n "$_out" ] || exit 1
mkdir -p "$(dirname "$_out")"
printf 'FAKE-INITRD\n' >"$_out"
STUB
cat >"$HARNESS/phase1/assemble-image.sh" <<'STUB'
#!/bin/sh
# 记录型桩：argv 进 $STUB_ARGV_LOG；按 --image 写一个**恰好** N 字节的假镜像
_argv=$*
printf 'sh %s %s\n' "$0" "${_argv}" >>"${STUB_ARGV_LOG:?}"
_img=''
while [ "$#" -gt 0 ]; do
	case $1 in
	--image) _img=$2; shift 2 ;;
	--image=*) _img=${1#--image=}; shift ;;
	*) shift ;;
	esac
done
[ -n "$_img" ] || exit 1
_n=${STUB_AS_BYTES:-4096}
dd if=/dev/zero of="$_img" bs=1024 count=$((_n / 1024)) 2>/dev/null
STUB
chmod 755 "$HARNESS/phase1/make-initramfs.sh" "$HARNESS/phase1/assemble-image.sh"

ARGV=$SB_ROOT/argv.log
: >"$ARGV"
export STUB_ARGV_LOG=$ARGV
WORK=$HARNESS/work
OUT=$SB_ROOT/real.img.gz
COMMON="--type dev --rootfs $FIX --kernel $KERNEL --image-out $OUT --size 4K --work $WORK"

if sh "$HARNESS/phase1/build.sh" $COMMON >"$SB_ROOT/real.log" 2>&1; then RC=0; else RC=$?; fi
eq "全桩真跑退出 0" '0' "$RC"
eq "真跑产出 .img.gz" 'yes' "$([ -s "$OUT" ] && echo yes || echo no)"
eq "真跑把 dev 注入落到 work/rootfs" 'yes' "$([ -f "$WORK/rootfs/etc/DEV-IMAGE" ] && echo yes || echo no)"
eq "真跑把 dev 的 firewall 规则写进 work/rootfs" 'yes' \
	"$(grep -q "option name 'dev-open-wan'" "$WORK/rootfs/etc/config/firewall" && echo yes || echo no)"
eq "真跑把 firstboot 注入落到 work/rootfs" 'yes' \
	"$([ -f "$WORK/rootfs/etc/uci-defaults/10-grow-p2.sh" ] && echo yes || echo no)"
eq "真跑把 dev 的调试公钥落到 work/rootfs（0600）" '-rw-------' \
	"$(ls -l "$WORK/rootfs/etc/dropbear/authorized_keys" 2>/dev/null | cut -c1-10)"
eq "真跑组出 STAGE 载荷（btrfs.ko）" 'yes' \
	"$([ -f "$WORK/stage/lib/modules/$KVER/btrfs.ko" ] && echo yes || echo no)"

echo "-- libubox 必须原名进 STAGE（改名 ⇒ 动态链接器找不到 soname）--"
eq "STAGE 里 libubox 保持 rootfs 里的原名" "libubox.so.${LIBUBOX_VER}" \
	"$(cd "$WORK/stage/lib" && ls libubox.so.* 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
eq "STAGE 里没有写死旧版本名 20260213" 'no' \
	"$([ -e "$WORK/stage/lib/libubox.so.20260213" ] && echo yes || echo no)"

echo "-- INIT_SHA 取证（CI 的 ac-3 逐字比对靠它）--"
INIT_SHA_LINE=$(grep '^INIT_SHA=' "$SB_ROOT/real.log")
_isha=${INIT_SHA_LINE#INIT_SHA=}
_ilen=$(printf '%s' "$_isha" | wc -c | tr -d ' ')
eq "打印了一行 INIT_SHA=" 'yes' "$([ -n "$_isha" ] && echo yes || echo no)"
eq "INIT_SHA 是 64 位十六进制" '64' "$_ilen"
eq "INIT_SHA 等于渲染出的 /init 的 sha256" "$(sha_of "$WORK/init.rendered")" "$_isha"
eq "渲染与打包用的是同一组参数（渲染侧也有 --rootdev/--bootdev）" 'yes' \
	"$(grep 'make-initramfs.sh --render-init-only' "$ARGV" | head -1 | grep -q -- '--rootdev /dev/nvme0n1p2 --bootdev /dev/nvme0n1p1' && echo yes || echo no)"

echo "-- dry-run 与真跑的 argv 逐字一致 --"
rm -f "$OUT"
if sh "$HARNESS/phase1/build.sh" $COMMON --dry-run >"$SB_ROOT/real-dry.log" 2>&1; then RC=0; else RC=$?; fi
eq "同参数 --dry-run 退出 0" '0' "$RC"
_dry_ri=$(grep '^  \$ sh .*make-initramfs\.sh --render-init-only' "$SB_ROOT/real-dry.log" | sed 's/^  \$ //')
_dry_mk=$(grep '^  \$ sh .*make-initramfs\.sh --stage' "$SB_ROOT/real-dry.log" | sed 's/^  \$ //')
_dry_as=$(grep '^  \$ sh .*assemble-image\.sh --image' "$SB_ROOT/real-dry.log" | sed 's/^  \$ //')
_real_ri=$(grep 'make-initramfs.sh --render-init-only' "$ARGV" | head -1)
_real_mk=$(grep 'make-initramfs.sh --stage' "$ARGV" | head -1)
_real_as=$(grep 'assemble-image.sh --image' "$ARGV" | head -1)
eq "dry-run 打印的 render-init-only argv == 真跑 exec 的" "$_real_ri" "$_dry_ri"
eq "dry-run 打印的 INIT_SHA == 真跑的 INIT_SHA（参数同一份）" \
	"$(grep '^INIT_SHA=' "$SB_ROOT/real.log" | sed 's/^INIT_SHA=//')" \
	"$(grep '^INIT_SHA=' "$SB_ROOT/real-dry.log" | sed 's/^INIT_SHA=//')"
eq "dry-run 打印的 make-initramfs argv == 真跑 exec 的" "$_real_mk" "$_dry_mk"
eq "dry-run 打印的 assemble-image argv == 真跑 exec 的" "$_real_as" "$_dry_as"
contains "真跑的 assemble-image 收到 --btrfs-label phase1" '--btrfs-label phase1' "$_real_as"
eq "build.sh 里 make-initramfs 只有一处调用" '1' "$(grep -c -F 'run sh "${MK}" --stage' "$BUILD")"
eq "build.sh 里 assemble-image 只有一处调用" '1' "$(grep -c -F 'run sh "${AS}"' "$BUILD")"

# ---------------------------------------------------------------------------
# 10. 大小闸：与实际字节数不符 ⇒ 拒绝产出（半成品不能当成功）
# ---------------------------------------------------------------------------
echo "== 10. 大小闸（--size 8K vs 桩产出的 4096 字节 ⇒ 必须失败）=="
if sh "$HARNESS/phase1/build.sh" --type prod --rootfs "$FIX" --kernel "$KERNEL" \
	--image-out "$SB_ROOT/bad-size.img.gz" --size 8K --work "$WORK" \
	>"$SB_ROOT/badsize.log" 2>&1; then RC=0; else RC=$?; fi
ne "尺寸不符 ⇒ 非 0" '0' "$RC"
contains "提示是半成品镜像" '半成品' "$(cat "$SB_ROOT/badsize.log")"
eq "尺寸不符时不产出 .img.gz" 'no' "$([ -e "$SB_ROOT/bad-size.img.gz" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 11. --work 护栏：系统目录 / 太浅 / 规范化后是 / 都要拒绝
# ---------------------------------------------------------------------------
echo "== 11. --work 护栏 =="
for _w in /tmp /tmp/.. /; do
	if sh "$HARNESS/phase1/build.sh" --type prod --rootfs "$FIX" --kernel "$KERNEL" \
		--image-out "$SB_ROOT/w.img.gz" --size 4K --work "$_w" --dry-run \
		>"$SB_ROOT/work.log" 2>&1; then RC=0; else RC=$?; fi
	# --dry-run 不建目录、不做 rm，所以这里只验"真跑口径"的护栏
	if sh "$HARNESS/phase1/build.sh" --type prod --rootfs "$FIX" --kernel "$KERNEL" \
		--image-out "$SB_ROOT/w.img.gz" --size 4K --work "$_w" \
		>"$SB_ROOT/work-real.log" 2>&1; then RC=0; else RC=$?; fi
	ne "--work $_w ⇒ 非 0" '0' "$RC"
	contains "--work $_w 的拒绝理由" '拒绝 --work' "$(cat "$SB_ROOT/work-real.log")"
done
eq "护栏拒绝时没有产出镜像" 'no' "$([ -e "$SB_ROOT/w.img.gz" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 12. STAGE 载荷边界：可选项缺失只 WARN；多版本 libubox 必须点名失败
# ---------------------------------------------------------------------------
echo "== 12. STAGE 载荷边界 =="
FIXNOMOD=$SB_ROOT/fixture-no-modinfo
mkdir -p "$FIXNOMOD"
cp -a "$FIX/." "$FIXNOMOD/"
rm -f "$FIXNOMOD/lib/modules/$KVER/modules.builtin.modinfo"
if sh "$HARNESS/phase1/build.sh" --type prod --rootfs "$FIXNOMOD" --kernel "$KERNEL" \
	--image-out "$SB_ROOT/nomod.img.gz" --size 4K --work "$WORK" \
	>"$SB_ROOT/nomod.log" 2>&1; then RC=0; else RC=$?; fi
eq "缺 modules.builtin.modinfo 不影响构建（可选）" '0' "$RC"
contains "缺 modinfo 只有 WARN" 'WARN' "$(cat "$SB_ROOT/nomod.log")"
eq "STAGE 里没有 modinfo（也没有假装有）" 'no' \
	"$([ -e "$WORK/stage/lib/modules/$KVER/modules.builtin.modinfo" ] && echo yes || echo no)"

FIXMULTI=$SB_ROOT/fixture-multi-libubox
mkdir -p "$FIXMULTI"
cp -a "$FIX/." "$FIXMULTI/"
printf 'fake-libubox-old\n' >"$FIXMULTI/lib/libubox.so.20240101"
if sh "$HARNESS/phase1/build.sh" --type prod --rootfs "$FIXMULTI" --kernel "$KERNEL" \
	--image-out "$SB_ROOT/multi.img.gz" --size 4K --work "$WORK" \
	>"$SB_ROOT/multi.log" 2>&1; then RC=0; else RC=$?; fi
ne "两个 libubox 版本 ⇒ 非 0" '0' "$RC"
contains "两个版本都被点名" 'libubox.so.20240101' "$(cat "$SB_ROOT/multi.log")"
contains "两个版本都被点名（第二个）" "libubox.so.${LIBUBOX_VER}" "$(cat "$SB_ROOT/multi.log")"
eq "多版本时不产出镜像" 'no' "$([ -e "$SB_ROOT/multi.img.gz" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 13. STAGE 缺必需载荷：必须非 0，并把缺项点名到包（不静默跳过）
# ---------------------------------------------------------------------------
echo "== 13. STAGE 缺必需载荷 ⇒ 非 0 且点名到包 =="
FIXBAD=$SB_ROOT/fixture-missing
mkdir -p "$FIXBAD"
cp -a "$FIX/." "$FIXBAD/"
rm -f "$FIXBAD/lib/modules/$KVER/btrfs.ko"
rm -f "$FIXBAD/usr/bin/setfattr"
if sh "$HARNESS/phase1/build.sh" --type prod --rootfs "$FIXBAD" --kernel "$KERNEL" \
	--image-out "$SB_ROOT/never2.img.gz" --size 4K --work "$WORK" \
	>"$SB_ROOT/missing.log" 2>&1; then RC=0; else RC=$?; fi
ne "缺载荷 ⇒ 非 0" '0' "$RC"
contains "缺项点名 kmod-fs-btrfs" 'kmod-fs-btrfs' "$(cat "$SB_ROOT/missing.log")"
contains "缺项点名 attr" 'attr' "$(cat "$SB_ROOT/missing.log")"
contains "缺项提示补 PACKAGES 后重跑" 'PACKAGES' "$(cat "$SB_ROOT/missing.log")"
eq "缺载荷时不产出镜像" 'no' "$([ -e "$SB_ROOT/never2.img.gz" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 14. 排除清单与 assemble-image.sh 的 extract_rootfs 逐项一致
# ---------------------------------------------------------------------------
echo "== 14. rootfs 排除清单与 assemble-image.sh 同源 =="
_ex_build=$(grep -o -- '--exclude=[^ ]*' "$BUILD" | LC_ALL=C sort -u | tr '\n' ' ')
if grep -q '^extract_rootfs()' "$AS" 2>/dev/null; then
	_ex_as=$(sed -n '/^extract_rootfs()/,/^}/p' "$AS" | grep -o -- '--exclude=[^ ]*' | LC_ALL=C sort -u | tr '\n' ' ')
	eq "排除清单一致" "$_ex_as" "$_ex_build"
else
	ok "assemble-image.sh 里没有 extract_rootfs（跳过一致性比对）"
fi
contains "排除清单含挂载点 ./proc" '--exclude=./proc' "$_ex_build"
contains "排除清单含 ./opt/docker" '--exclude=./opt/docker' "$_ex_build"
contains "排除清单含 ./data" '--exclude=./data' "$_ex_build"

finish "$NAME"
