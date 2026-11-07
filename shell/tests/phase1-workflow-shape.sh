#!/bin/sh
# ac-6：.github/workflows/Build-phase1-btrfs.yml 的结构契约（离线、只读新文件）。
#
# 这点用例只做**文本结构断言**：不调用 GitHub、不跑 docker、不依赖 PyYAML，
# 在 macOS 的 /bin/sh（bash 3.2）与 Ubuntu 的 mawk 上都能跑。
#
# 覆盖：输入面（mode=dev|prod）、fe53232 基线 + 80_mount_root 叠加、legacy 基座拒绝、
#       包注入必须走 build25.sh 的 PACKAGES（**不许**污染 apk-custom-packages.sh）、
#       ImageBuilder 容器形制、rootfs 双路 + 内核三段式、宿主机工具安装、
#       自检与 --image 真跑**委派**给 phase1/ 的脚本、artifact 与失败日志上传、
#       trap 清理、以及"不写仓库/不写个人信息"的反例。
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

WF=$REPO/.github/workflows/Build-phase1-btrfs.yml

if [ ! -f "$WF" ]; then
	bad "缺少 .github/workflows/Build-phase1-btrfs.yml"
	finish PHASE1-WORKFLOW-SHAPE
fi
ok "存在 .github/workflows/Build-phase1-btrfs.yml（只读本文件，不比对其它 workflow）"

has() { # 描述 固定子串
	if grep -qF -- "$2" "$WF"; then
		ok "$1"
	else
		bad "$1"
		printf '       期望出现 [%s]\n' "$2"
	fi
}

hasre() { # 描述 ERE
	if grep -qE -- "$2" "$WF"; then
		ok "$1"
	else
		bad "$1"
		printf '       期望匹配 /%s/\n' "$2"
	fi
}

hasnt() { # 描述 不应出现的固定子串
	if grep -qF -- "$2" "$WF"; then
		bad "$1"
		printf '       不应出现 [%s]\n' "$2"
	else
		ok "$1"
	fi
}

# 取某一步的 YAML 片段（从 `      - name: <名>` 到下一个 `      - ` 开头的行为止）。
step_block() { # 步骤名
	awk -v name="$1" '
		$0 == "      - name: " name { found = 1; print; next }
		found && /^      - / { exit }
		found { print }
	' "$WF"
}

block_has() { # 描述 片段 固定子串
	if printf '%s\n' "$2" | grep -qF -- "$3"; then
		ok "$1"
	else
		bad "$1"
		printf '       该步骤里期望出现 [%s]\n' "$3"
	fi
}

block_hasnt() { # 描述 片段 不应出现的固定子串
	if printf '%s\n' "$2" | grep -qF -- "$3"; then
		bad "$1"
		printf '       该步骤里不应出现 [%s]\n' "$3"
	else
		ok "$1"
	fi
}

has_count() { # 描述 期望次数 ERE
	_n=$(grep -cE -- "$3" "$WF" || true)
	if [ "${_n:-0}" = "$2" ]; then
		ok "$1"
	else
		bad "$1"
		printf '       期望 %s 处 /%s/，实得 %s\n' "$2" "$3" "${_n:-0}"
	fi
}

echo "== 1. 文件与 YAML 基本结构 =="
has "显示名正确" "name: Build phase1 btrfs image"
hasre "顶层有 on:（workflow_dispatch 入口）" '^on:[[:space:]]*$'
hasre "顶层有 permissions:" '^permissions:[[:space:]]*$'
hasre "顶层有 jobs:" '^jobs:[[:space:]]*$'
has "workflow_dispatch 触发" "workflow_dispatch:"
has "只申请 contents: read（不需要写仓库）" "contents: read"
has "跑在 ubuntu-22.04" "runs-on: ubuntu-22.04"
# 制表符不能用来做缩进（YAML 硬规则）
if grep -q "$(printf '\t')" "$WF"; then
	bad "文件里出现了制表符（YAML 缩进只允许空格）"
else
	ok "文件里没有制表符"
fi
# 所有 `- name:` 步骤项必须齐在同一缩进（6 空格），否则 steps 列表结构已坏
_names=$(grep -cE '^      - name: ' "$WF" || true)
_allitems=$(grep -cE '^[[:space:]]+- name: ' "$WF" || true)
eq "全部步骤项缩进一致" "${_names:-0}" "${_allitems:-0}"
# 有 PyYAML 就顺手做一次真解析（没有也不失败：下面全是文本断言）
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
	if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$WF" >/dev/null 2>&1; then
		ok "PyYAML 解析通过"
	else
		bad "PyYAML 解析失败"
	fi
else
	printf '  skip PyYAML 未安装（改用文本结构断言）\n'
fi

echo "== 2. 输入面：5 个 input，mode 恰为 dev|prod =="
_inputs=$(awk '
	/^    inputs:[[:space:]]*$/ { inp = 1; next }
	inp && /^    [^[:space:]]/ { inp = 0 }
	inp && /^    [a-z_]/ { inp = 0 }
	inp && /^      [a-z_]+:[[:space:]]*$/ {
		line = $0
		sub(/^ +/, "", line)
		sub(/:.*$/, "", line)
		print line
	}
' "$WF" | sort | tr '\n' ' ')
eq "inputs 恰为 mode/luci_version/include_docker/image_size/custom_router_ip" \
	"custom_router_ip image_size include_docker luci_version mode " "$_inputs"

_mode_opts=$(awk '
	/^      mode:[[:space:]]*$/ { m = 1; next }
	m && /^      [a-z_]+:[[:space:]]*$/ { m = 0 }
	m && /^          - [A-Za-z0-9._-]+[[:space:]]*$/ {
		line = $0
		sub(/^ +- /, "", line)
		gsub(/[[:space:]]/, "", line)
		print line
	}
' "$WF" | sort | tr '\n' ' ')
eq "mode 的选项恰为 dev/prod" "dev prod " "$_mode_opts"

_luci_opts=$(awk '
	/^      luci_version:[[:space:]]*$/ { m = 1; next }
	m && /^      [a-z_]+:[[:space:]]*$/ { m = 0 }
	m && /^          - / { line = $0; sub(/^ +- /, "", line); gsub(/[[:space:]]/, "", line); print line }
' "$WF" | sort | tr '\n' ' ')
eq "luci_version 的选项为 25.12.0/1/2" "25.12.0 25.12.1 25.12.2 " "$_luci_opts"

# yes/no 在 YAML 里写作带引号的字符串；引号交给 tr 去掉（不用 awk 的 \x27，mawk 不保证支持）
_docker_opts=$(awk '
	/^      include_docker:[[:space:]]*$/ { m = 1; next }
	m && /^      [a-z_]+:[[:space:]]*$/ { m = 0 }
	m && /^          - / { line = $0; sub(/^ +- /, "", line); gsub(/[[:space:]]/, "", line); print line }
' "$WF" | tr -d "\"'" | sort | tr '\n' ' ')
eq "include_docker 的选项为 yes/no" "no yes " "$_docker_opts"

has "mode 默认 prod（dev 必须显式选）" 'default: "prod"'
has "image_size 默认 8G" 'default: "8G"'
has "custom_router_ip 默认 192.168.100.1（固件默认 LAN）" 'default: "192.168.100.1"'

echo "== 3. mode 真的传进了构建（dev/prod 由参数决定） =="
BLOCK_BUILD_IMG=$(step_block "Build phase1 image")
block_has "构建步骤调 phase1/build.sh" "$BLOCK_BUILD_IMG" "phase1/build.sh"
block_has "构建步骤传 --type" "$BLOCK_BUILD_IMG" "--type"
block_has "构建步骤用 inputs.mode 作类型" "$BLOCK_BUILD_IMG" "inputs.mode"
block_has "构建步骤传 --rootfs" "$BLOCK_BUILD_IMG" "--rootfs"
block_has "构建步骤传 --kernel" "$BLOCK_BUILD_IMG" "--kernel"
block_has "构建步骤传 --image-out（.img.gz 产物）" "$BLOCK_BUILD_IMG" "--image-out"
block_has "构建步骤传 --size（image_size 输入）" "$BLOCK_BUILD_IMG" "--size"
block_has "构建步骤用 inputs.image_size" "$BLOCK_BUILD_IMG" "inputs.image_size"
block_has "内核路径取自 Extract 步骤导出的 KERNEL" "$BLOCK_BUILD_IMG" 'KERNEL="${KERNEL:?'

echo "== 4. 内容基线 = fe53232 + 80_mount_root 叠加 + legacy 基座拒绝 =="
BLOCK_CO=$(step_block "Checkout code")
block_has "检出用 actions/checkout" "$BLOCK_CO" "actions/checkout@v6"
block_has "检出 fetch-depth: 0（浅克隆取不到 fe53232）" "$BLOCK_CO" "fetch-depth: 0"

BLOCK_BASE=$(step_block "Materialize fe53232 baseline content")
block_has "用 git archive 取 fe53232 基线" "$BLOCK_BASE" "git archive fe53232"
block_has "基线只取 files/x86-64/shell 三个目录" "$BLOCK_BASE" "files x86-64 shell"
has "叠加 files/lib/preinit/80_mount_root（§O.1 守卫）" "files/lib/preinit/80_mount_root"
block_has "80_mount_root 来自检出后的工作树" "$BLOCK_BASE" 'cp files/lib/preinit/80_mount_root'
block_has "拒绝 etc/init.d/btrfs-subvols" "$BLOCK_BASE" "etc/init.d/btrfs-subvols"
block_has "拒绝 etc/uci-defaults/95-overlay-setup.sh" "$BLOCK_BASE" "etc/uci-defaults/95-overlay-setup.sh"
block_has "拒绝 lib/preinit/79-btrfs" "$BLOCK_BASE" "lib/preinit/79-btrfs"
block_has "拒绝 usr/sbin/overlay-setup" "$BLOCK_BASE" "usr/sbin/overlay-setup"
block_has "legacy 基座出现即 exit 1" "$BLOCK_BASE" "exit 1"

echo "== 5. 包注入：走 build25.sh 的 PACKAGES，不碰 CUSTOM_PACKAGES =="
block_has "在 packages echo 之前插入 PACKAGES 追加（否则日志里看不到，会误判没注入）" "$BLOCK_BASE" "sed -i '/- Building image with the following packages:/i PACKAGES=\"\$PACKAGES attr"
block_has "注入 attr" "$BLOCK_BASE" "attr"
block_has "注入 kmod-fs-vfat" "$BLOCK_BASE" "kmod-fs-vfat"
block_has "注入 kmod-nls-cp437" "$BLOCK_BASE" "kmod-nls-cp437"
block_has "注入 kmod-nls-iso8859-1" "$BLOCK_BASE" "kmod-nls-iso8859-1"
block_has "注入 kmod-nls-utf8" "$BLOCK_BASE" "kmod-nls-utf8"
block_has "注入后回显确认（grep -n kmod-nls-utf8）" "$BLOCK_BASE" "grep -n 'kmod-nls-utf8'"
block_hasnt "不再往 apk-custom-packages.sh 追加（会触发第三方商店分支）" "$BLOCK_BASE" \
	'>> "$BASE/shell/apk-custom-packages.sh"'
block_has "反向断言 apk-custom-packages.sh 没被污染" "$BLOCK_BASE" \
	'grep -q '"'"'kmod-nls-utf8'"'"' "$BASE/shell/apk-custom-packages.sh"'
block_has "构建后打印 CUSTOM_PACKAGES 实测值" "$BLOCK_BUILD_IMG" "CUSTOM_PACKAGES=["
block_has "CUSTOM_PACKAGES 非空即失败" "$BLOCK_BUILD_IMG" "基线被第三方商店污染"
block_has "最终 PACKAGES 里必须有 kmod-nls-utf8" "$BLOCK_BUILD_IMG" "kmod-nls-utf8"
block_has "取证落 pkg-baseline.txt" "$BLOCK_BUILD_IMG" "pkg-baseline.txt"

echo "== 6. ImageBuilder 容器形制（照抄现有 workflow） =="
BLOCK_IB=$(step_block "Build rootfs with ImageBuilder")
block_has "用 immortalwrt/imagebuilder 镜像" "$BLOCK_IB" "immortalwrt/imagebuilder:x86-64-openwrt-"
block_has "版本取自 inputs.luci_version" "$BLOCK_IB" "inputs.luci_version"
block_has "以 root 身份跑" "$BLOCK_IB" "--user root"
block_has "入口是 build.sh" "$BLOCK_IB" "/bin/bash /home/build/immortalwrt/build.sh"
block_has "透传 INCLUDE_DOCKER" "$BLOCK_IB" "INCLUDE_DOCKER"
block_has "挂 bin 输出目录" "$BLOCK_IB" "/home/build/immortalwrt/bin"
block_has "挂 files/" "$BLOCK_IB" "/home/build/immortalwrt/files"
block_has "挂 imm25.config → .config" "$BLOCK_IB" "imm25.config:/home/build/immortalwrt/.config"
block_has "挂 shell/" "$BLOCK_IB" "shell:/home/build/immortalwrt/shell"
block_has "挂 build25.sh → build.sh" "$BLOCK_IB" "build25.sh:/home/build/immortalwrt/build.sh"
block_has "custom_router_ip 走单文件挂载" "$BLOCK_IB" \
	"custom_router_ip.txt:/home/build/immortalwrt/files/etc/config/custom_router_ip.txt"
block_has "给基线 build25.sh 的 \$PROFILE 提供取值（否则 ROOTFS_PARTSIZE 为空）" "$BLOCK_IB" "-e PROFILE=1024"
# 结构护栏：`\` 续行之间不许出现注释行。写在续行里会被 bash 当成整条命令的行内注释，
# 把后面的参数连同镜像名一起吞掉（首跑实测：docker run 报 "requires at least 1 argument"）。
_bad_cont=$(awk '
	prev ~ /\\$/ && $0 ~ /^[[:space:]]*#/ { printf "%d:%s\n", NR, $0 }
	{ prev = $0 }
' "$WF")
if [ -z "$_bad_cont" ]; then
	ok "续行之间没有夹注释（否则 bash 会把整条命令的剩余部分当注释吞掉）"
else
	bad "续行之间夹了注释：$_bad_cont"
fi

block_has "PROFILE 必须 > 512：rootfs 未压缩 564MB，512 会让 root.ext4 分配失败（首跑实测）" "$BLOCK_IB" "-e PROFILE=1024"
block_has "容器跑在 pipefail 下（退出码不被 tee 吞掉）" "$BLOCK_IB" "set -euo pipefail"
block_has "docker 输出落 build.sh.log（失败时可上传）" "$BLOCK_IB" 'tee "$WORK/build.sh.log"'

echo "== 7. rootfs 双路 + 内核三段式 =="
BLOCK_EX=$(step_block "Extract rootfs and kernel")
block_has "rootfs 优先路径 rootfs.tar.gz" "$BLOCK_EX" "rootfs.tar.gz"
block_has "rootfs 退化路径 unsquashfs" "$BLOCK_EX" "unsquashfs"
block_has "退化路径要 loop 设备" "$BLOCK_EX" "losetup -fP --show"
block_has "打印 rootfs 用了哪条" "$BLOCK_EX" "rootfs source:"
block_has "内核候选 1：ImageBuilder 的 *-kernel.bin" "$BLOCK_EX" '*-kernel.bin'
block_has "内核候选 2：rootfs/boot/vmlinuz" "$BLOCK_EX" "rootfs/boot/vmlinuz"
block_has "内核候选 3：组合镜像的 vfat boot 分区" "$BLOCK_EX" 'grep -q '"'"'^vfat$'"'"''
block_has "内核候选 3 会挂 boot 分区取值" "$BLOCK_EX" 'mnt-efi/boot/vmlinuz'
block_has "三条都失败要点名报错" "$BLOCK_EX" "三条内核来源都没有找到 vmlinuz"
block_has "找不到内核就 exit 1" "$BLOCK_EX" "exit 1"
block_has "内核导出给后续步骤（GITHUB_ENV）" "$BLOCK_EX" 'KERNEL=$KERNEL" >> "$GITHUB_ENV'
block_has "提取后打印磁盘余量" "$BLOCK_EX" 'df -h "$RUNNER_TEMP"'

echo "== 8. 宿主机工具必须先装（grub-pc-bin 提供 i386-pc 模块树） =="
BLOCK_TOOLS=$(step_block "Install host tools")
block_has "有 Install host tools 步骤" "$BLOCK_TOOLS" "apt-get install -y"
block_has "装 grub-pc-bin（缺它 grub-install 必失败）" "$BLOCK_TOOLS" "grub-pc-bin"
block_has "装 grub-common（grub-script-check）" "$BLOCK_TOOLS" "grub-common"
block_has "装 gdisk（sgdisk）" "$BLOCK_TOOLS" "gdisk"
block_has "装 dosfstools（mkfs.vfat）" "$BLOCK_TOOLS" "dosfstools"
block_has "装 btrfs-progs（mkfs.btrfs/btrfs）" "$BLOCK_TOOLS" "btrfs-progs"
block_has "装 coreutils（truncate）" "$BLOCK_TOOLS" "coreutils"
block_has "装 e2fsprogs" "$BLOCK_TOOLS" "e2fsprogs"
block_has "装 cpio（复核 initrd）" "$BLOCK_TOOLS" "cpio"
block_has "装 squashfs-tools" "$BLOCK_TOOLS" "squashfs-tools"
block_has "逐个 command -v 复核" "$BLOCK_TOOLS" 'command -v "$t"'
block_has "复核清单含 grub-install" "$BLOCK_TOOLS" "grub-install"
block_has "复核清单含 mkfs.btrfs" "$BLOCK_TOOLS" "mkfs.btrfs"
block_has "装完打印磁盘余量" "$BLOCK_TOOLS" 'df -h "$RUNNER_TEMP"'

echo "== 9. 自检与 --image 真跑：委派给 phase1/ 的脚本（不内联判定） =="
BLOCK_SC=$(step_block "Self-check image")
block_has "自检调用 phase1/tools/image-selfcheck.sh" "$BLOCK_SC" "phase1/tools/image-selfcheck.sh"
block_has "把 mode 传进自检" "$BLOCK_SC" '--mode "$mode"'
block_has "把 INIT_SHA 传进自检（ac-3）" "$BLOCK_SC" '--init-sha "$INIT_SHA"'
block_has "从构建日志抓 INIT_SHA" "$BLOCK_SC" "grep -oE 'INIT_SHA=[0-9a-f]{64}'"
block_has "没有 INIT_SHA 即失败" "$BLOCK_SC" "构建日志里没有 INIT_SHA"
block_has "自检结果 tee 到 selfcheck.txt" "$BLOCK_SC" 'tee "$WORK/selfcheck.txt"'
block_has "自检结果写 job summary" "$BLOCK_SC" "GITHUB_STEP_SUMMARY"
block_has "非 0 即 job 失败" "$BLOCK_SC" "镜像自检失败"
block_has "自检完删 rootfs 腾空间" "$BLOCK_SC" 'rm -rf "$WORK/rootfs"'
block_has "生成 sha256 旁边文件" "$BLOCK_SC" 'tee "$gz.sha256"'
# 判定逻辑必须在脚本里，不能又长回 YAML
block_hasnt "YAML 里不再内联 sgdisk -p" "$BLOCK_SC" "sgdisk -p"
hasnt "全文件不再出现 524288（布局断言已进脚本）" "524288"
hasnt "全文件不再出现 btrfs subvolume list（子卷断言已进脚本）" "btrfs subvolume list"

BLOCK_REAL=$(step_block "Verify --image mode end-to-end")
block_has "有 --image 真跑步骤" "$BLOCK_REAL" "phase1/tests/assemble-image-mode.sh"
block_has "真跑开关 PHASE1_IMAGE_REAL=1" "$BLOCK_REAL" "PHASE1_IMAGE_REAL=1"
block_has "变量交给 sudo 自己设（避免 env_reset 静默 PEND）" "$BLOCK_REAL" "sudo env PHASE1_IMAGE_REAL=1"

echo "== 10. artifact / 失败日志 / 摘要 =="
has "上传 artifact 用 actions/upload-artifact@v4" "actions/upload-artifact@v4"
has_count "两个上传步骤（成功产物 + 失败日志）" 2 'uses: actions/upload-artifact@v4'
has "artifact 含 .img.gz" "*.img.gz"
has "artifact 含 .img.gz.sha256" "*.img.gz.sha256"
has "生成 sha256sum" "sha256sum"
has "缺文件即失败（if-no-files-found: error）" "if-no-files-found: error"
has "保留 14 天" "retention-days: 14"
BLOCK_LOG=$(step_block "Upload build logs on failure")
block_has "失败日志上传条件是 if: failure()" "$BLOCK_LOG" "if: failure()"
block_has "失败日志上传 upload-artifact" "$BLOCK_LOG" "actions/upload-artifact@v4"
block_has "失败日志含 *.log" "$BLOCK_LOG" "*.log"
BLOCK_SUM=$(step_block "Write job summary")
block_has "摘要写 GITHUB_STEP_SUMMARY" "$BLOCK_SUM" 'GITHUB_STEP_SUMMARY'
block_has "摘要里带 mode" "$BLOCK_SUM" "inputs.mode"
block_has "摘要里带 sha256" "$BLOCK_SUM" "sha256"
block_has "摘要里带包基线取证" "$BLOCK_SUM" "pkg-baseline.txt"
block_has "摘要里带 CUSTOM_PACKAGES" "$BLOCK_SUM" "CUSTOM_PACKAGES"

echo "== 11. 十二个步骤齐备且顺序正确 =="
_prev=0
_order=0
for _n in \
	"Checkout code" \
	"Materialize fe53232 baseline content" \
	"Build rootfs with ImageBuilder" \
	"Extract rootfs and kernel" \
	"Install host tools" \
	"Build phase1 image" \
	"Self-check image" \
	"Boot smoke (UEFI + legacy)" \
	"Verify --image mode end-to-end" \
	"Upload artifacts" \
	"Upload build logs on failure" \
	"Write job summary"; do
	_ln=$(grep -nF -- "      - name: $_n" "$WF" | head -n 1 | cut -d: -f1)
	if [ -z "$_ln" ]; then
		bad "缺少步骤 [$_n]"
		_order=1
		continue
	fi
	ok "存在步骤 [$_n]"
	if [ "$_ln" -le "$_prev" ]; then
		bad "步骤顺序错：[$_n] 应排在更后"
		_order=1
	fi
	_prev=$_ln
done
eq "十二个步骤顺序正确" 0 "$_order"
# 不再断言"字面总数=12"：那是 change-detector（插一个无关步骤就得来改测试），
# 而且它保护的"步骤齐备"已由上面的名单+顺序循环覆盖。改成"名单覆盖全部步骤"。
_expected=$(printf '%s\n' 	"Checkout code" 	"Materialize fe53232 baseline content" 	"Build rootfs with ImageBuilder" 	"Extract rootfs and kernel" 	"Install host tools" 	"Build phase1 image" 	"Self-check image" 	"Boot smoke (UEFI + legacy)" 	"Verify --image mode end-to-end" 	"Upload artifacts" 	"Upload build logs on failure" 	"Write job summary" | grep -c .)
eq "名单覆盖全部步骤（不多不少）" "${_expected}" "${_names:-0}"

echo "== 11b. 冷启动冒烟步骤本身必须 fail-closed（新门禁的关键属性）=="
BLOCK_BOOT=$(step_block "Boot smoke (UEFI + legacy)")
block_has "调用 qemu-boot-check.sh" "$BLOCK_BOOT" "qemu-boot-check.sh"
block_has "跑 UEFI 档" "$BLOCK_BOOT" "for fw in uefi bios"
block_has "带超时 BOOT_TIMEOUT" "$BLOCK_BOOT" "BOOT_TIMEOUT"
block_has "失败要 exit 1（不许吞）" "$BLOCK_BOOT" "exit 1"
block_has "UEFI 档失败即红（把 rc 记为 rc_all）" "$BLOCK_BOOT" 'rc_all=$rc'
block_has "BIOS 档暂记告警（::warning::）" "$BLOCK_BOOT" "::warning::"
block_has "报告落盘为 boot-smoke-*.txt" "$BLOCK_BOOT" "boot-smoke-"
block_has "两种固件各用一份干净镜像（避免旧日志冒充）" "$BLOCK_BOOT" "cp --reflink=auto"
block_has "失败要保留现场（--log-out 归档串口/qemu 日志）" "$BLOCK_BOOT" "--log-out"

echo "== 12. trap 清理：不留脏挂载 / 脏 loop =="
has "rootfs/内核提取步骤装了 EXIT trap" "trap cleanup EXIT"
has "清理 SQ_LOOP" 'SQ_LOOP=""'
has "清理 BOOT_LOOP" 'BOOT_LOOP=""'
has "trap 里 losetup -d" "losetup -d"
has "trap 里 umount" "umount"

echo "== 13. bash 步骤统一 shell: bash + set -euo pipefail =="
_shell_n=$(grep -cE '^        shell: bash$' "$WF" || true)
_pipe_n=$(grep -cE '^          set -euo pipefail$' "$WF" || true)
eq "shell: bash 与 set -euo pipefail 数量一致" "${_shell_n:-0}" "${_pipe_n:-0}"
if [ "${_shell_n:-0}" -ge 8 ]; then
	ok "至少 8 个 bash 步骤（${_shell_n}）"
else
	bad "bash 步骤只有 ${_shell_n:-0} 个（期望 ≥8）"
fi

echo "== 14. 反例：不写仓库、不写个人信息、不写固定 /tmp 路径 =="
hasnt "不 git add" "git add"
hasnt "不 git commit" "git commit"
hasnt "不 git push" "git push"
hasnt "不出现真实家庭网段 192.168.2." "192.168.2."
hasnt "不出现本机用户路径 /Users/" "/Users/"
hasnt "不写固定 /tmp 路径（并发会撞）" "/tmp/"
has "临时目录走 RUNNER_TEMP" "RUNNER_TEMP"

finish PHASE1-WORKFLOW-SHAPE
