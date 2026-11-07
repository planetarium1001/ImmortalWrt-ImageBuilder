#!/bin/sh
# phase1/assemble-image.sh —— Phase 1 装机骨架（分区 / 子卷 / 解包 / manifest / grub）
#
# 目标几何（权威：.workflow/assets/2026-11-06-btrfs-ab-decisions.md §0.1）：
#   p1    FAT32  256M   <p1>/boot/grub/grub.cfg  /boot/vmlinuz  /boot/initrd.cpio.gz
#   p128  EF02    4M    GRUB core.img 预留（Phase 1 只按 4M 建，本轮不重建 core.img）
#   p2    btrfs   至盘尾 @root(只读基座) / @overlay(upper+work) / @docker(→/opt/docker) / @swap(→/swap)
#
# 三个模式对机器无害、可以随便跑：
#   --dry-run        只打印完整计划（分区表 / 子卷 / 解包目标 / manifest / grub / cmdline），
#                    不写盘、不 mkfs、不碰 /dev，退出码 0。
#   --grub-dir DIR   只把 grub.cfg 渲染到 DIR/grub.cfg（真机试跑用），其它什么都不动。
#   --image OUT.img --size 8G
#                    镜像文件模式（CI 用）：truncate 出一个普通文件 → losetup -P →
#                    分区/格式化/子卷/解包/manifest/grub-install → detach。**只写 OUT.img**，
#                    绝不碰 /dev 下的任何整盘设备，也不需要人工 yes（目标是一个新文件）。
#                    OUT.img 是未压缩镜像；gzip 与 sha256 由 phase1/build.sh 负责。
#
# 真装机路径（两个开关都不给时）写在文件末尾：分层校验（p1 元数据 → 文件系统 UUID →
# 子卷枚举比对，全部打印）→ 手工输入 yes → destructive_install()。
# 破坏性动作**只允许**：sgdisk / mkfs.vfat / mkfs.btrfs / btrfs subvolume create / 解包，
# 且全部集中在 destructive_install() 里（--zap-all 已经清空 p2，所以本轮不删子卷）。
# 本脚本不使用递归强制删除，也不使用通配删除（只对写死的单个文件用 rm -f）。
#
# 用法：sh phase1/assemble-image.sh --help
set -u

PROG=phase1/assemble-image.sh
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEMPLATE=$SCRIPT_DIR/grub/grub.cfg.in

# ---- 默认值（全部可被命令行选项覆盖）----
DRY_RUN=0
GRUB_DIR=''
PRESERVE=''
TRIAL_INDEX_SET=0
# H3：装机几何必须能与基座对上。Phase 1 的基座是 fe53232 内容（无 btrfs-subvols / 无 extroot fstab），
# 所以默认标签 phase1、不建 @data；HEAD 时代基座要 label=wrt-overlay + @data，必须显式放行。
BTRFS_LABEL=phase1
WITH_DATA_SUBVOL=0
ALLOW_LEGACY_ROOTFS=0
ROOTFS=''
KERNEL=''
INITRD=''
DISK=''
# 镜像文件模式（--image OUT.img --size 8G）：写新文件，不碰 /dev 下的整盘
IMAGE=''
IMAGE_SIZE=''
IMAGE_FORCE=0
IMAGE_MIN_MB=2048
BOOT_SIZE=256M
ESP_SIZE=4M
BOOT_SUBDIR=boot
TIMEOUT=3
TITLE=''
TRIAL=0
TRIAL_INDEX=1
KERNEL_PATH=''
INITRD_PATH=''
MARKER_PATH=''
MARKER_PATH_ALT=''
TRIAL_KERNEL=''
TRIAL_INITRD=''
TRIAL_TITLE=''
CMDLINE=''
ROOTDEV=''
BOOTDEV=''
LOWER_SUBVOL='@root'
OVERLAY_SUBVOL='@overlay'
CONSOLE='console=ttyS0,115200n8 console=tty1'

# 装机期挂载点（只在真装机路径用；不进最终镜像的 fstab）
BOOT_MNT=/mnt/phase1-boot
DATA_MNT=/mnt/phase1-btrfs
SUBVOLS='@root @overlay @docker @swap'
GRUB_MODULES='part_msdos part_gpt fat normal linux search search_fs_uuid search_label test echo serial terminal'

# ---------------------------------------------------------------------------
# 输出与退出
# ---------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

fail() { # <原因> [下一步提示]
	printf '%s: %s\n' "$PROG" "$1" >&2
	if [ $# -ge 2 ]; then
		printf '  下一步: %s\n' "$2" >&2
	fi
	exit 1
}

usage_fail() { # <原因>
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf '  用法: sh %s --help\n' "$PROG" >&2
	exit 2
}

usage() {
	cat <<'EOF'
phase1/assemble-image.sh —— Phase 1 装机骨架（dry-run / 渲染 grub.cfg / 镜像文件模式 / 真装机）

只读模式（对机器无害）：
  --dry-run                     只打印完整装机计划，不写盘、不 mkfs、不碰 /dev；退出码 0
  --grub-dir DIR                只把 grub.cfg 渲染到 DIR/grub.cfg（真机试跑用），不碰磁盘

镜像文件模式（CI 用；只写 OUT.img，不碰 /dev 下的整盘）：
  --image OUT.img               产出可 dd 的镜像文件（Linux + root；需要 losetup）
  --size 8G                     镜像文件大小（与 --image 配套；下限 2G；要写成 8G 或 8192M）
                                配 --dry-run 时只打印同一套计划、什么都不写
  --force-overwrite             允许覆盖已存在的非空镜像文件（默认拒绝，防止手滑清掉宿主文件）

真装机模式（需要全部参数；会先做分层校验并要求手工输入 yes）：
  --rootfs FILE|DIR             上游 rootfs（rootfs.tar.gz 或已解开的目录）
  --kernel FILE                 内核文件（拷到引导分区；grub 路径默认 /<boot-subdir>/<basename>）
  --initrd FILE                 initrd 文件，同上
  --disk /dev/DEV               目标整盘（分区表会被重建！）

可选：
  --btrfs-label NAME            p2（btrfs）文件系统标签（默认 phase1）。
                                HEAD 时代基座把它写死成 wrt-overlay，装那种基座必须显式给
                                --btrfs-label wrt-overlay 并加 --with-data-subvol
  --with-data-subvol            额外建 @data 子卷（默认关；HEAD 时代基座的 btrfs-subvols 会挂 /data）
  --allow-legacy-rootfs         允许用 HEAD 时代的 rootfs（含 /etc/init.d/btrfs-subvols 或
                                extroot/@overlay 的 fstab）。默认硬失败：Phase 1 要求 fe53232 基线
  --boot-size 256M              p1 大小（默认 256M；改动会让 p2 起点漂移，别乱改）
  --esp-size 4M                 p128 EF02 大小（默认 4M）
  --boot-subdir boot            引导分区内的前缀目录（grub 视角 /boot/... = FAT 内 boot/...）
  --timeout 3                   GRUB 等待秒数
  --title "..."                 0 号项标题
  --cmdline "..."               0 号项 cmdline（逐字可控）
  --trial                       渲染时多一条试跑项（标记文件存在时成为默认项）
  --preserve-existing FILE      真机试跑用：把现存 grub.cfg（设备上的 /boot/grub/grub.cfg 副本）逐行原样保留，
                                只在 set default 之后插入标记守卫、在末尾追加一条试跑项；
                                必须与 --grub-dir 一起用，且只校验我们自己生成的试跑项（保留行不参与硬规则）
  --trial-index N               试跑项的 menuentry 序号（默认自动 = 保留文件里 menuentry 的条数）
  --rootdev /dev/nvme0n1p2      试跑项 phase1_dev（默认由 --disk 推 p2）
  --bootdev /dev/nvme0n1p1      试跑项 phase1_boot（默认由 --disk 推 p1）
  --lower-subvol @root          试跑项 phase1_lower
  --overlay-subvol @overlay     试跑项 phase1_overlay
  --kernel-path PATH            覆盖 grub 视角的内核路径
  --initrd-path PATH            覆盖 grub 视角的 initrd 路径
  --marker-path PATH            试跑标记的 grub 视角路径（默认 /boot/try-phase1 =
                                引导分区 boot/ 下的同一个文件，与 live /boot 一致）
  --marker-path-alt PATH        兜底路径（默认 /try-phase1，仅 grub root 指到分区根时才命中）
  --trial-kernel PATH           试跑项用另一个内核（grub 视角路径）
  --trial-initrd PATH           试跑项用另一个 initrd（grub 视角路径）
  -h, --help                    本帮助

渲染后的 grub.cfg 一定会被校验（ac-5）：不许出现会让内核无限等待的 root* 参数，
不许用 root=PARTUUID= 锚定根，必须含 fstools_ignore_partname=1 与 panic=10，
必须含 set fallback=0；--trial 时还必须有标记守卫与四个 phase1_* 键。
校验不过直接退出非 0（不做任何"自动修补"）。

镜像文件模式（--image）的边界：唯一被写的路径就是 OUT.img 本身（普通文件）。
--image 与 --disk / --grub-dir / --trial 互斥；OUT.img 不许落在 /dev/ 下或是块设备。
镜像里的根设备来自 initrd 烘焙的默认值（phase1/make-initramfs.sh --rootdev），
因为最终镜像的 grub.cfg 不含 phase1_dev= 键（与 0 号项口径一致，ac-5 的校验也这么要求）。
EOF
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
basename_of() { printf '%s\n' "${1##*/}"; }

# derive_part <disk> <n>  → /dev/nvme0n1 + 2 = /dev/nvme0n1p2；/dev/sda + 2 = /dev/sda2
derive_part() {
	case $1 in
	*[0-9]) printf '%sp%s\n' "$1" "$2" ;;
	*) printf '%s%s\n' "$1" "$2" ;;
	esac
}

boot_prefix() { # grub 视角的引导目录前缀：/boot；--boot-subdir '' 时为空串
	if [ -n "$BOOT_SUBDIR" ]; then
		printf '/%s' "$BOOT_SUBDIR"
	fi
}

need_value() { # <选项名> <当前剩余参数个数>
	[ "$2" -ge 2 ] || usage_fail "$1 需要一个参数"
}

# image_size_mb <SIZE> → 打印 MB 数（8G → 8192，8192M → 8192）；格式非法返回 1
image_size_mb() {
	case ${1:-} in
	'' | *[!0-9GgMm]*) return 1 ;;
	esac
	case $1 in
	*[Gg]) _n=${1%?} _f=1024 ;;
	*[Mm]) _n=${1%?} _f=1 ;;
	*) return 1 ;;
	esac
	case $_n in '' | *[!0-9]*) return 1 ;; esac
	[ "$_n" -gt 0 ] || return 1
	printf '%s\n' "$((_n * _f))"
}

# 镜像模式的参数校验：全部在写任何字节之前完成（fail-closed）
image_validate() {
	[ -n "$IMAGE" ] || usage_fail "--size 只能与 --image 一起用（--size 是镜像文件大小）"
	[ -n "$IMAGE_SIZE" ] || usage_fail "--image 需要 --size（例如 --size 8G）"
	[ -z "$DISK" ] || usage_fail "--image 与 --disk 互斥（前者写镜像文件，后者重建整盘）"
	[ -z "$GRUB_DIR" ] || usage_fail "--image 与 --grub-dir 互斥（前者产出镜像，后者只渲染 grub.cfg）"
	[ "$TRIAL" = 0 ] || usage_fail "--image 与 --trial 互斥（最终镜像只保留 0 号项）"
	case $IMAGE in
	/dev/*) usage_fail "--image 必须是普通文件路径，不能是设备: $IMAGE" ;;
	esac
	if [ -b "$IMAGE" ]; then
		usage_fail "--image 必须是普通文件路径，不能是块设备: $IMAGE"
	fi
	if [ -d "$IMAGE" ]; then
		usage_fail "--image 指向的是目录，请给它一个文件路径: $IMAGE"
	fi
	# 覆盖一个已有的普通文件是不可逆的（随后 truncate 到 --size）：默认拒绝，要 --force-overwrite
	if [ -f "$IMAGE" ] && [ -s "$IMAGE" ] && [ "$IMAGE_FORCE" != 1 ]; then
		usage_fail "--image 已存在且非空（$(wc -c <"$IMAGE" | tr -d ' ') 字节），拒绝覆盖: ${IMAGE}（确实要覆盖请加 --force-overwrite）"
	fi
	if ! _mb=$(image_size_mb "$IMAGE_SIZE"); then
		usage_fail "--size 要写成 8G 或 8192M（收到: ${IMAGE_SIZE}）"
	fi
	if [ "$_mb" -lt "$IMAGE_MIN_MB" ]; then
		usage_fail "--size 低于下限（镜像下限 2G，收到: ${IMAGE_SIZE}）"
	fi
}

trial_cmdline() {
	# phase1_bootsub = 引导分区里的前缀子目录（= --boot-subdir）。它决定 /init 去
	#   <p1>/<bootsub>/try-phase1  删标记、写 <p1>/<bootsub>/phase1-boot.log。
	# 真机约定（PRD 硬规则 15）：p1 根下有 boot/ 与 efi/，内核/grub.cfg/标记都在 p1:/boot 下，
	# 而 live 的 /boot 也指向 p1:/boot ⇒ 空值表示"标记就在引导分区根"，不是"没设置"。
	printf '%s rdinit=/init phase1_dev=%s phase1_boot=%s phase1_bootsub=%s phase1_lower=%s phase1_overlay=%s' \
		"$CMDLINE" "$ROOTDEV" "$BOOTDEV" "$BOOT_SUBDIR" "$LOWER_SUBVOL" "$OVERLAY_SUBVOL"
}

# phase1_bootsub 是否与 --boot-subdir 一致（只有我们生成的项会进这个检查）
bootsub_violations() { # <文件>：只看我们生成的项（含 phase1_dev= 的 linux 行）
	awk -v want="$BOOT_SUBDIR" '/^[[:space:]]*linux[[:space:]]/ && /phase1_dev=/ {
		found = 0
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^phase1_bootsub=/) {
				val = $i
				sub(/^phase1_bootsub=/, "", val)
				found = 1
				if (val != want)
					print "  第 " NR " 行 phase1_bootsub 应为 [" want "] 实际 [" val "]（= --boot-subdir）: " $0
			}
		}
		if (found == 0)
			print "  第 " NR " 行缺 phase1_bootsub= 键（应等于 --boot-subdir [" want "]）: " $0
	}' "$1"
}

tool_state() { # <命令> → 有 / 缺
	if command -v "$1" >/dev/null 2>&1; then
		printf '有'
	else
		printf '缺'
	fi
}

mountpoint_present() { # <设备>：在 /proc/mounts 里出现就算"在忙"
	[ -r /proc/mounts ] || return 1
	grep -q "^$1 " /proc/mounts 2>/dev/null
}

# ---------------------------------------------------------------------------
# H3：rootfs 基线检查（Phase 1 要求 fe53232 内容）
#
# 为什么必须拦：HEAD 时代的基座里 /etc/init.d/btrfs-subvols 用
#   btrfs filesystem show wrt-overlay
# 找 p3，并会挂 @data；而我们默认 -L phase1、只建 @root/@overlay/@docker/@swap。
# 装那种基座后每次启动 btrfs-subvols 在 p3_dev 就 return 1（一个子卷都不挂、不跑 swapctl、
# /data 缺失），而且因为 /init 已经把 @docker/@swap 挂好而**被掩盖**，到 Phase 2 才爆。
# 所以这里不是"改默认值"，而是显式拦截。
# ---------------------------------------------------------------------------
rootfs_baseline_suspects() { # <rootfs FILE|DIR>：打印疑点，空输出 = 通过
	_r=$1
	if [ -d "$_r" ]; then
		if [ -e "$_r/etc/init.d/btrfs-subvols" ]; then
			printf '  存在 /etc/init.d/btrfs-subvols（HEAD 时代基座）\n'
		fi
		if [ -f "$_r/etc/config/fstab" ] && grep -qE 'extroot|@overlay' "$_r/etc/config/fstab" 2>/dev/null; then
			printf '  /etc/config/fstab 含 extroot/@overlay 段（HEAD 时代基座）\n'
		fi
		return 0
	fi
	_tl=$(tar -tf "$_r" 2>/dev/null) || {
		printf '  （无法列出 %s 的内容，跳过基线检查）\n' "$_r" >&2
		return 0
	}
	if printf '%s\n' "$_tl" | grep -qE '(^|/)etc/init\.d/btrfs-subvols$'; then
		printf '  存在 /etc/init.d/btrfs-subvols（HEAD 时代基座）\n'
	fi
	if printf '%s\n' "$_tl" | grep -qE '(^|/)etc/config/fstab$'; then
		if tar -xOf "$_r" ./etc/config/fstab 2>/dev/null | grep -qE 'extroot|@overlay'; then
			printf '  /etc/config/fstab 含 extroot/@overlay 段（HEAD 时代基座）\n'
		fi
	fi
	return 0
}

check_rootfs_baseline() {
	if [ ! -e "$ROOTFS" ]; then
		warn "rootfs 源不存在（${ROOTFS}）：跳过基线检查（真装机前 require_inputs 会再挡一次）"
		return 0
	fi
	_sus=$(rootfs_baseline_suspects "$ROOTFS")
	[ -n "$_sus" ] || return 0

	if [ "$ALLOW_LEGACY_ROOTFS" = 1 ]; then
		warn "rootfs 看着是 HEAD 时代内容，已用 --allow-legacy-rootfs 放行："
		printf '%s\n' "$_sus" >&2
		if [ "$BTRFS_LABEL" != wrt-overlay ] || [ "$WITH_DATA_SUBVOL" != 1 ]; then
			warn "强烈建议同时给 --btrfs-label wrt-overlay --with-data-subvol："
			warn "  HEAD 基座的 btrfs-subvols 用 'btrfs filesystem show wrt-overlay' 找 p3，且会挂 @data"
		fi
		return 0
	fi

	printf '%s: 这份 rootfs 是 HEAD 时代内容，Phase 1 要求 **fe53232 基线**\n' "$PROG" >&2
	printf '%s\n' "$_sus" >&2
	printf '  为什么拦：HEAD 基座的 /etc/init.d/btrfs-subvols 用 btrfs filesystem show wrt-overlay 找 p3，\n' >&2
	printf '            还要挂 @data；本脚本默认 -L %s 且只建 [%s]，装完每次启动都会 return 1\n' "$BTRFS_LABEL" "$SUBVOLS" >&2
	printf '            （这个故障会被 /init 已挂好的 @docker/@swap 掩盖，到 Phase 2 才爆）\n' >&2
	printf '  下一步: 换成 fe53232 基座；或显式 --allow-legacy-rootfs --btrfs-label wrt-overlay --with-data-subvol\n' >&2
	exit 1
}

# ---------------------------------------------------------------------------
# M3：目标盘正在被使用时硬失败（在设备本机跑 = 重建正在运行的分区表）
# ---------------------------------------------------------------------------
assert_target_not_in_use() {
	_hits=''
	_re="^$DISK(p[0-9]+|[0-9]+)?$"
	if [ -r /proc/mounts ]; then
		_hits=$(awk -v re="$_re" '$1 ~ re { print "  " $1 " 已挂载在 " $2 }' /proc/mounts 2>/dev/null)
	fi
	if [ -r /proc/cmdline ]; then
		_c=$(tr '\n' ' ' </proc/cmdline 2>/dev/null)
		case $_c in
		*"$DISK"*)
			_hits="$_hits
  /proc/cmdline 里出现 ${DISK}（当前系统可能就跑在它上面）"
			;;
		esac
	fi
	if command -v swapon >/dev/null 2>&1; then
		_sw=$(swapon -s 2>/dev/null | awk -v re="$_re" 'NR > 1 && $1 ~ re { print "  swap 在用: " $1 }')
		if [ -n "$_sw" ]; then
			_hits="$_hits
$_sw"
		fi
	fi
	if [ -n "$_hits" ]; then
		printf '%s: 目标盘 %s 正在被使用，拒绝重建它的分区表：%s\n' "$PROG" "$DISK" "$_hits" >&2
		printf '  下一步: 从另一介质（U 盘 / Live 环境）运行本脚本；或先卸载该盘上的挂载点、swapoff 后重试\n' >&2
		exit 1
	fi
	say "  目标盘占用检查: $DISK 无已挂载分区、无 swap、不在 /proc/cmdline 里"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
	case $1 in
	--dry-run) DRY_RUN=1 ;;
	--grub-dir)
		need_value "$1" $#
		shift
		GRUB_DIR=$1
		;;
	--rootfs)
		need_value "$1" $#
		shift
		ROOTFS=$1
		;;
	--kernel)
		need_value "$1" $#
		shift
		KERNEL=$1
		;;
	--initrd)
		need_value "$1" $#
		shift
		INITRD=$1
		;;
	--disk)
		need_value "$1" $#
		shift
		DISK=$1
		;;
	--image)
		need_value "$1" $#
		shift
		IMAGE=$1
		;;
	--size)
		need_value "$1" $#
		shift
		IMAGE_SIZE=$1
		;;
	--force-overwrite) IMAGE_FORCE=1 ;;
	--boot-size)
		need_value "$1" $#
		shift
		BOOT_SIZE=$1
		;;
	--esp-size)
		need_value "$1" $#
		shift
		ESP_SIZE=$1
		;;
	--boot-subdir)
		need_value "$1" $#
		shift
		BOOT_SUBDIR=$1
		;;
	--timeout)
		need_value "$1" $#
		shift
		TIMEOUT=$1
		;;
	--title)
		need_value "$1" $#
		shift
		TITLE=$1
		;;
	--cmdline)
		need_value "$1" $#
		shift
		CMDLINE=$1
		;;
	--trial) TRIAL=1 ;;
	--btrfs-label)
		need_value "$1" $#
		shift
		BTRFS_LABEL=$1
		;;
	--with-data-subvol) WITH_DATA_SUBVOL=1 ;;
	--allow-legacy-rootfs) ALLOW_LEGACY_ROOTFS=1 ;;
	--preserve-existing)
		need_value "$1" $#
		shift
		PRESERVE=$1
		;;
	--trial-index)
		need_value "$1" $#
		shift
		TRIAL_INDEX=$1
		TRIAL_INDEX_SET=1
		;;
	--rootdev)
		need_value "$1" $#
		shift
		ROOTDEV=$1
		;;
	--bootdev)
		need_value "$1" $#
		shift
		BOOTDEV=$1
		;;
	--lower-subvol)
		need_value "$1" $#
		shift
		LOWER_SUBVOL=$1
		;;
	--overlay-subvol)
		need_value "$1" $#
		shift
		OVERLAY_SUBVOL=$1
		;;
	--kernel-path)
		need_value "$1" $#
		shift
		KERNEL_PATH=$1
		;;
	--initrd-path)
		need_value "$1" $#
		shift
		INITRD_PATH=$1
		;;
	--marker-path)
		need_value "$1" $#
		shift
		MARKER_PATH=$1
		;;
	--marker-path-alt)
		need_value "$1" $#
		shift
		MARKER_PATH_ALT=$1
		;;
	--trial-kernel)
		need_value "$1" $#
		shift
		TRIAL_KERNEL=$1
		;;
	--trial-initrd)
		need_value "$1" $#
		shift
		TRIAL_INITRD=$1
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	*) usage_fail "未知参数: $1" ;;
	esac
	shift
done

# ---- 派生默认值 ------------------------------------------------------------
# H3：@data 只在 --with-data-subvol 时建（Phase 1 的 fe53232 基线不需要它）
if [ "$WITH_DATA_SUBVOL" = 1 ]; then
	SUBVOLS="$SUBVOLS @data"
fi

[ -n "$KERNEL" ] || KERNEL=vmlinuz
[ -n "$INITRD" ] || INITRD=initrd.cpio.gz
[ -n "$TITLE" ] || TITLE='phase1 btrfs @root(ro) + @overlay'

if [ -z "$KERNEL_PATH" ]; then
	KERNEL_PATH=$(boot_prefix)/$(basename_of "$KERNEL")
fi
if [ -z "$INITRD_PATH" ]; then
	INITRD_PATH=$(boot_prefix)/$(basename_of "$INITRD")
fi
# 试跑标记（PRD 硬规则 15，F-1 真机实测裁定）：标记在**引导分区的 boot/ 子目录**下。
#   设备 live 视图 : /boot/try-phase1      （79_move_config 把 p1 挂到 /boot 后 bind /boot/boot /boot）
#   GRUB 视图      : /boot/try-phase1      （grub root = p1 根，p1:/boot/try-phase1）
#   /init 视图     : <p1>/<bootsub>/try-phase1（bootsub 由 phase1_bootsub 传入）
# 三者是**同一个文件**。所以主守卫用 /boot/try-phase1；/try-phase1 只作"grub root 指到
# 引导分区根"这类布局的兜底（上一版曾把两者写反，导致 /init 删不掉标记 ⇒ 无限重启）。
if [ -z "$MARKER_PATH" ]; then
	MARKER_PATH=$(boot_prefix)/try-phase1
fi
if [ -z "$MARKER_PATH_ALT" ]; then
	MARKER_PATH_ALT=/try-phase1
fi
[ -n "$TRIAL_KERNEL" ] || TRIAL_KERNEL=$KERNEL_PATH
[ -n "$TRIAL_INITRD" ] || TRIAL_INITRD=$INITRD_PATH
[ -n "$TRIAL_TITLE" ] || TRIAL_TITLE='phase1 trial（失败自动回 0 号项；手工删 /boot/try-phase1 立即生效）'

if [ -z "$CMDLINE" ]; then
	CMDLINE="fstools_ignore_partname=1 panic=10 $CONSOLE"
fi

# 试跑项的设备：没显式给就用 --disk 推（整盘 p1/p2）
if [ -n "$DISK" ]; then
	[ -n "$BOOTDEV" ] || BOOTDEV=$(derive_part "$DISK" 1)
	[ -n "$ROOTDEV" ] || ROOTDEV=$(derive_part "$DISK" 2)
fi

# ---------------------------------------------------------------------------
# grub.cfg 渲染 + 校验（ac-5）
# ---------------------------------------------------------------------------
validate_cfg() { # <渲染结果文件>
	_vf=$1
	_bad=''

	# 只认已知占位符（模板里的 #@TRIAL_BEGIN@ 之类是段落标记，不是占位符）
	_leftover=''
	for _p in TIMEOUT TITLE CMDLINE MARKER MARKER_ALT TRIAL_INDEX TRIAL_TITLE TRIAL_CMDLINE \
		KERNEL INITRD TRIAL_KERNEL TRIAL_INITRD; do
		if grep -q "@$_p@" "$_vf"; then
			_leftover="$_leftover @$_p@"
		fi
	done
	if [ -n "$_leftover" ]; then
		_bad="$_bad
  - 模板占位符没替换:$_leftover"
	fi

	grep -q '^set fallback=0$' "$_vf" || _bad="$_bad
  - 缺 'set fallback=0'（内核/initrd 加载失败时要回落 0 号项）"

	# 逐条 linux 行检查 cmdline（模板模式下文件里全是我们的项，所以全文都查）：
	#   * 禁 rootwait —— 找不到根时无限等待，panic=10 永不触发（handoff §5 坑 1）
	#   * 禁 root=PARTUUID= —— 上游每次构建都会换 PARTUUID（handoff §5 坑 14），根由 initrd 决定
	#   * 必含 fstools_ignore_partname=1（否则 fstools 可能把整盘抹成 ext4，坑 8）与 panic=10
	_cmdbad=$(cmdline_violations "$_vf")
	if [ -n "$_cmdbad" ]; then
		_bad="$_bad
  - cmdline 硬规则不满足:
$_cmdbad"
	fi

	if [ "$TRIAL" = 1 ]; then
		for _m in "$MARKER_PATH" "$MARKER_PATH_ALT"; do
			if ! grep -q "\[ -f $_m \]" "$_vf"; then
				_bad="$_bad
  - 缺试跑标记守卫: if [ -f $_m ]"
			fi
		done
		if ! grep -q "^[[:space:]]*set default=$TRIAL_INDEX\$" "$_vf"; then
			_bad="$_bad
  - 标记存在时没有 set default=$TRIAL_INDEX"
		fi
		for _k in phase1_dev= phase1_boot= phase1_bootsub= phase1_lower= phase1_overlay=; do
			if ! grep -q "$_k" "$_vf"; then
				_bad="$_bad
  - 试跑项缺 cmdline 键 $_k"
			fi
		done
		_bootsub_bad=$(bootsub_violations "$_vf")
		if [ -n "$_bootsub_bad" ]; then
			_bad="$_bad
  - phase1_bootsub 与 --boot-subdir 不一致:
$_bootsub_bad"
		fi
	else
		# 最终镜像：不许有试跑项，也不许有指向不存在序号的 default
		if grep -q 'try-phase1' "$_vf"; then
			_bad="$_bad
  - 没有 --trial 却渲染出了试跑标记逻辑"
		fi
		if grep -q 'phase1_dev=' "$_vf"; then
			_bad="$_bad
  - 没有 --trial 却渲染出了试跑项 cmdline"
		fi
	fi

	_n=$(grep -c '^menuentry ' "$_vf")
	_want=1
	[ "$TRIAL" = 1 ] && _want=2
	if [ "$_n" != "$_want" ]; then
		_bad="$_bad
  - menuentry 数量应为 ${_want}，实际 $_n"
	fi

	if [ -n "$_bad" ]; then
		printf '%s: 渲染结果不合格（%s）:%s\n' "$PROG" "$_vf" "$_bad" >&2
		printf '  下一步: 检查 --cmdline / --trial-* 与模板 phase1/grub/grub.cfg.in\n' >&2
		rm -f "$_vf"
		exit 1
	fi
}

# 模板头（占位符说明、硬规则说明）只留在仓库里：渲染结果从 #@TEMPLATE_HEADER_END@ 之后开始，
# 免得渲染出来的 grub.cfg 里带着 "rootwait"、"PARTUUID" 之类说明字样被误判。
strip_template_header() {
	sed '1,/^#@TEMPLATE_HEADER_END@$/d' "$TEMPLATE"
}

render_cfg() { # <输出目录>
	_out=$1
	[ -f "$TEMPLATE" ] || fail "模板缺失: $TEMPLATE" "确认仓库里 phase1/grub/grub.cfg.in 存在"
	grep -q '^#@TEMPLATE_HEADER_END@$' "$TEMPLATE" ||
		fail "模板缺 #@TEMPLATE_HEADER_END@ 头结束标记: $TEMPLATE" "恢复模板头结束行后再渲染"
	mkdir -p "$_out" || fail "无法创建目录: $_out" "换一个可写目录（--grub-dir DIR）"

	case $MARKER_PATH in
	*@*) fail "标记路径不能含 @: $MARKER_PATH" "换一个不含 @ 的 --marker-path" ;;
	esac
	case $MARKER_PATH_ALT in
	*@*) fail "标记路径不能含 @: $MARKER_PATH_ALT" "换一个不含 @ 的 --marker-path-alt" ;;
	esac
	if [ "$TRIAL" = 1 ]; then
		[ -n "$ROOTDEV" ] || usage_fail "--trial 需要 --rootdev（或给 --disk 让脚本推 p2）"
		[ -n "$BOOTDEV" ] || usage_fail "--trial 需要 --bootdev（或给 --disk 让脚本推 p1）"
	fi

	_tmp=$_out/.grub.cfg.rendering
	_trial_cmd=$(trial_cmdline)

	# 值里出现 & | \ 会让 sed 替换出错，提前挡住（不做静默转义）
	for _v in "$CMDLINE" "$TITLE" "$TRIAL_TITLE" "$KERNEL_PATH" "$INITRD_PATH" "$MARKER_PATH" "$MARKER_PATH_ALT"; do
		case $_v in
		*'&'* | *'|'* | *'\\'*)
			fail "参数里不能有 & | \\ 这三个字符: $_v" "换一种写法，或去掉该字符后重试"
			;;
		esac
	done

	_sedscript=$_out/.grub.sed
	{
		printf 's|@TIMEOUT@|%s|g\n' "$TIMEOUT"
		printf 's|@TITLE@|%s|g\n' "$TITLE"
		printf 's|@KERNEL@|%s|g\n' "$KERNEL_PATH"
		printf 's|@INITRD@|%s|g\n' "$INITRD_PATH"
		printf 's|@CMDLINE@|%s|g\n' "$CMDLINE"
		printf 's|@MARKER@|%s|g\n' "$MARKER_PATH"
		printf 's|@MARKER_ALT@|%s|g\n' "$MARKER_PATH_ALT"
		printf 's|@TRIAL_INDEX@|%s|g\n' "$TRIAL_INDEX"
		printf 's|@TRIAL_TITLE@|%s|g\n' "$TRIAL_TITLE"
		printf 's|@TRIAL_KERNEL@|%s|g\n' "$TRIAL_KERNEL"
		printf 's|@TRIAL_INITRD@|%s|g\n' "$TRIAL_INITRD"
		printf 's|@TRIAL_CMDLINE@|%s|g\n' "$_trial_cmd"
		# 主/兜底标记路径相同时，整段删掉兜底守卫（否则会出两条一模一样的 test）
		if [ "$MARKER_PATH" = "$MARKER_PATH_ALT" ]; then
			printf '/^#@MARKER_ALT_BEGIN@$/,/^#@MARKER_ALT_END@$/d\n'
		fi
		# 段落标记只属于模板，不进渲染结果
		printf '/^#@TRIAL_BEGIN@$/d\n'
		printf '/^#@TRIAL_END@$/d\n'
		printf '/^#@MARKER_ALT_BEGIN@$/d\n'
		printf '/^#@MARKER_ALT_END@$/d\n'
	} >"$_sedscript" || fail "无法写 sed 脚本: $_sedscript" "检查 --grub-dir 权限"

	if [ "$TRIAL" = 1 ]; then
		strip_template_header | sed -f "$_sedscript" >"$_tmp" ||
			fail "渲染失败: $TEMPLATE" "检查模板是否完整"
	else
		# 非试跑渲染：整段删掉 #@TRIAL_BEGIN@ .. #@TRIAL_END@（含两端标记行）
		strip_template_header |
			sed '/^#@TRIAL_BEGIN@$/,/^#@TRIAL_END@$/d' |
			sed -f "$_sedscript" >"$_tmp" ||
			fail "渲染失败: $TEMPLATE" "检查模板是否完整"
	fi
	rm -f "$_sedscript"

	validate_cfg "$_tmp"
	mv "$_tmp" "$_out/grub.cfg" || fail "无法写出 $_out/grub.cfg" "检查 --grub-dir 的权限"

	if [ "$TRIAL" = 1 ]; then
		say "已渲染 grub.cfg -> $_out/grub.cfg（含试跑项，标记 ${MARKER_PATH}）"
	else
		say "已渲染 grub.cfg -> $_out/grub.cfg（只有 0 号项）"
	fi
}

# ---------------------------------------------------------------------------
# --preserve-existing：真机试跑用的"保留上游 grub.cfg"渲染模式
#
# 真机上现存的已知良好项是**上游 squashfs 项**（`root=PARTUUID=... rootwait noinitrd`），
# 那是合法的：它不是我们的 initrd 项。所以本模式：
#   * 保留文件里每一行原样输出（serial/terminal/`set default`/`set timeout`/
#     `search -l kernel -s root`/全部 menuentry），一个字节都不改；
#   * 只在现存 `set default=...` 之后插入两条标记守卫（单行写法，不用 `-o`/`||`）；
#   * 在文件末尾追加一条试跑项，序号 = 现存 menuentry 条数（可用 --trial-index 覆盖）；
#   * cmdline 硬规则（禁 rootwait、禁 root=PARTUUID=、必含 fstools_ignore_partname=1 panic=10）
#     **只施加在我们生成的试跑项上**，保留行不参与校验 —— 这不是"放行"，
#     而是"上游项不是我们的项"，见 phase1/README.md 的「两种渲染模式」。
# ---------------------------------------------------------------------------
cmdline_violations() { # <文件>：逐条 linux 行检查硬规则；有输出 = 有违规
	awk '/^[[:space:]]*linux[[:space:]]/ {
		if (index($0, "rootwait") > 0)
			print "  第 " NR " 行出现 rootwait（禁：会无限等待，panic=10 不触发）: " $0
		if (index($0, "root=PARTUUID=") > 0)
			print "  第 " NR " 行出现 root=PARTUUID=（禁：每次构建漂移，根由 initrd 决定）: " $0
		if (index($0, "fstools_ignore_partname=1") == 0)
			print "  第 " NR " 行缺 fstools_ignore_partname=1: " $0
		if (index($0, "panic=10") == 0)
			print "  第 " NR " 行缺 panic=10: " $0
	}' "$1"
}

trial_block() { # 我们生成的试跑项（与模板里的试跑项同形）
	printf "menuentry '%s' {\n" "$TRIAL_TITLE"
	printf '\tlinux %s %s\n' "$TRIAL_KERNEL" "$(trial_cmdline)"
	printf '\tinitrd %s\n' "$TRIAL_INITRD"
	printf '}\n'
}

emit_guards() { # <1=先补 set fallback=0 | 0=不补>
	if [ "${1:-1}" = 1 ]; then
		printf 'set fallback=0\n'
	fi
	# 主路径（= 与 live /boot 一致的那个）在前；两者相同时只出一条
	printf 'if [ -f %s ]; then set default=%s; fi\n' "$MARKER_PATH" "$TRIAL_INDEX"
	if [ "$MARKER_PATH" != "$MARKER_PATH_ALT" ]; then
		printf 'if [ -f %s ]; then set default=%s; fi\n' "$MARKER_PATH_ALT" "$TRIAL_INDEX"
	fi
}

validate_trial_block() { # <我们生成的试跑片段>：只校验我们自己写的东西
	_vt=$1
	_bad=''
	case $TRIAL_TITLE in
	*"'"*) _bad="$_bad
  - 试跑项标题里不能有单引号: $TRIAL_TITLE" ;;
	esac
	_cmdbad=$(cmdline_violations "$_vt")
	if [ -n "$_cmdbad" ]; then
		_bad="$_bad
  - 试跑项 cmdline 硬规则不满足:
$_cmdbad"
	fi
	for _k in rdinit=/init phase1_dev= phase1_boot= phase1_bootsub= phase1_lower= phase1_overlay=; do
		if ! grep -q "$_k" "$_vt"; then
			_bad="$_bad
  - 试跑项缺 cmdline 键 $_k"
		fi
	done
	_bootsub_bad=$(bootsub_violations "$_vt")
	if [ -n "$_bootsub_bad" ]; then
		_bad="$_bad
  - phase1_bootsub 与 --boot-subdir 不一致:
$_bootsub_bad"
	fi
	if [ "$(grep -c '^menuentry ' "$_vt")" != 1 ]; then
		_bad="$_bad
  - 试跑项片段里应恰有 1 个 menuentry"
	fi
	if [ -n "$_bad" ]; then
		printf '%s: 试跑项不合格（%s）:%s\n' "$PROG" "$_vt" "$_bad" >&2
		printf '  下一步: 检查 --cmdline / --trial-* / --trial-index\n' >&2
		rm -f "$_vt"
		exit 1
	fi
}

assert_preserved_lines() { # <原文件> <渲染结果>：运行期断言"每一非空行都逐字还在"
	_miss=''
	while IFS= read -r _pl || [ -n "$_pl" ]; do
		case $_pl in
		'') continue ;;
		esac
		case $_pl in
		*[![:space:]]*) ;;
		*) continue ;;
		esac
		if ! grep -Fqx -e "$_pl" "$2"; then
			_miss="$_miss
  原样缺失: [$_pl]"
		fi
	done <"$1"
	if [ -n "$_miss" ]; then
		printf '%s: 保留行没有逐字出现在渲染结果里（%s）:%s\n' "$PROG" "$2" "$_miss" >&2
		printf '  下一步: 这是脚本 bug —— 保留模式只允许新增行，不允许改写已有行\n' >&2
		exit 1
	fi
}

render_cfg_preserve() { # <输出目录>
	_out=$1
	[ -n "$GRUB_DIR" ] || usage_fail "--preserve-existing 必须与 --grub-dir DIR 一起用（它只渲染 grub.cfg）"
	[ -f "$PRESERVE" ] || fail "要保留的 grub.cfg 不存在: $PRESERVE" "把设备上的 /boot/grub/grub.cfg 备份出来再指向它"
	[ -s "$PRESERVE" ] || fail "要保留的 grub.cfg 是空文件: $PRESERVE" "确认文件内容非空"
	mkdir -p "$_out" || fail "无法创建目录: $_out" "换一个可写目录（--grub-dir DIR）"

	case $MARKER_PATH in
	*@*) fail "标记路径不能含 @: $MARKER_PATH" "换一个不含 @ 的 --marker-path" ;;
	esac
	case $MARKER_PATH_ALT in
	*@*) fail "标记路径不能含 @: $MARKER_PATH_ALT" "换一个不含 @ 的 --marker-path-alt" ;;
	esac

	# 序号：默认 = 原文件里 menuentry 的条数（上游项占 0..N-1，试跑项排最后 ⇒ 序号 N）
	if [ "$TRIAL_INDEX_SET" = 0 ]; then
		TRIAL_INDEX=$(grep -c '^[[:space:]]*menuentry' "$PRESERVE")
	fi
	case $TRIAL_INDEX in
	'' | *[!0-9]*) fail "--trial-index 必须是数字，收到: $TRIAL_INDEX" "例：--trial-index 3" ;;
	esac

	# 插入点：现存 set default 之后（spec）；没有 set default 就插在第一个 menuentry 之前
	_last_default=$(grep -n '^[[:space:]]*set default=' "$PRESERVE" | tail -1 | cut -d: -f1)
	_first_men=$(grep -n '^[[:space:]]*menuentry' "$PRESERVE" | head -1 | cut -d: -f1)
	_need_fallback=0
	if [ "$TRIAL" = 1 ] && ! grep -q '^[[:space:]]*set fallback=' "$PRESERVE"; then
		# 上游文件没有 fallback：试跑项默认、内核/initrd 加载失败时 GRUB 会停在菜单等按键
		# （timeout="0" 也不会自动选），无人值守就等于挂死 ⇒ 补一行 set fallback=0。
		# 这是**新增**行，不改动任何保留行。
		_need_fallback=1
	fi

	_tmp=$_out/.grub.cfg.rendering
	_block=$_out/.grub.trial-block

	if [ "$TRIAL" = 1 ]; then
		trial_block >"$_block" || fail "无法写试跑片段: $_block" "检查 --grub-dir 权限"
		validate_trial_block "$_block"
	fi
	: >"$_tmp" || fail "无法写 $_tmp" "检查 --grub-dir 权限"

	_emitted=0
	_n=0
	while IFS= read -r _l || [ -n "$_l" ]; do
		_n=$((_n + 1))
		if [ "$TRIAL" = 1 ] && [ "$_emitted" = 0 ] && [ -z "$_last_default" ] &&
			[ -n "$_first_men" ] && [ "$_n" = "$_first_men" ]; then
			emit_guards "$_need_fallback" >>"$_tmp"
			_emitted=1
		fi
		printf '%s\n' "$_l" >>"$_tmp"
		if [ "$TRIAL" = 1 ] && [ "$_emitted" = 0 ] && [ -n "$_last_default" ] &&
			[ "$_n" = "$_last_default" ]; then
			emit_guards "$_need_fallback" >>"$_tmp"
			_emitted=1
		fi
	done <"$PRESERVE"

	if [ "$TRIAL" = 1 ]; then
		if [ "$_emitted" = 0 ]; then
			emit_guards "$_need_fallback" >>"$_tmp"
		fi
		printf '\n' >>"$_tmp"
		trial_block >>"$_tmp" || fail "无法追加试跑项" "检查 --grub-dir 权限"
	fi

	# 运行期断言：原文件每一非空行都必须逐字出现在输出里
	assert_preserved_lines "$PRESERVE" "$_tmp"
	rm -f "$_block"
	mv "$_tmp" "$_out/grub.cfg" || fail "无法写出 $_out/grub.cfg" "检查 --grub-dir 权限"

	_pn=$(wc -l <"$PRESERVE" | tr -d ' ')
	if [ "$TRIAL" = 1 ]; then
		say "已渲染 grub.cfg -> $_out/grub.cfg（保留 $PRESERVE 的 $_pn 行，试跑项序号 ${TRIAL_INDEX}，标记 $MARKER_PATH / ${MARKER_PATH_ALT}）"
		[ "$_need_fallback" = 1 ] && say "  注意: 原文件没有 set fallback，已补一行 set fallback=0（新增行，未改动保留行）"
	else
		say "已渲染 grub.cfg -> $_out/grub.cfg（只保留 $PRESERVE 的 $_pn 行，未加试跑项）"
	fi
}

# ---------------------------------------------------------------------------
# --dry-run：完整计划（不写盘、不 mkfs、不碰 /dev）
# ---------------------------------------------------------------------------
print_plan() {
	[ -n "$DISK" ] || usage_fail "--dry-run 需要 --disk /dev/DEV（计划里要写清目标盘）"
	[ -n "$ROOTFS" ] || usage_fail "--dry-run 需要 --rootfs FILE|DIR"
	case $DISK in
	/dev/*) ;;
	*) usage_fail "--disk 必须是 /dev/ 下的整盘设备，收到: $DISK" ;;
	esac
	if [ "$TRIAL" = 1 ] && { [ -z "$ROOTDEV" ] || [ -z "$BOOTDEV" ]; }; then
		usage_fail "--trial 的 dry-run 需要 --rootdev/--bootdev（或可用 --disk 推导）"
	fi
	# H3：rootfs 基线检查在 dry-run 也做（这样刷机前就能被拦住）
	check_rootfs_baseline
	if [ -n "$(rootfs_baseline_suspects "$ROOTFS" 2>/dev/null)" ]; then
		_baseline='HEAD 时代内容（已 --allow-legacy-rootfs 放行）'
	else
		_baseline='通过（没有 btrfs-subvols / extroot fstab 迹象）'
	fi

	_p1=$(derive_part "$DISK" 1)
	_p2=$(derive_part "$DISK" 2)
	_grubdir=$(boot_prefix)/grub

	say "=== phase1 装机计划（--dry-run：只打印，不写盘、不 mkfs、不碰 /dev）==="
	say ""
	say "磁盘          : $DISK"
	say "rootfs 源     : $ROOTFS"
	say "内核          : $KERNEL  -> grub 路径 $KERNEL_PATH"
	say "initrd        : $INITRD  -> grub 路径 $INITRD_PATH"
	say "引导分区前缀  : ${BOOT_SUBDIR:-<FAT 根>}（grub 视角路径都以此为前缀）"
	say "btrfs 标签    : ${BTRFS_LABEL}（--btrfs-label；HEAD 时代基座要求 wrt-overlay）"
	say "@data 子卷    : $([ "$WITH_DATA_SUBVOL" = 1 ] && echo '建（--with-data-subvol）' || echo '不建（Phase 1 的 fe53232 基线不需要）')"
	say "rootfs 基线   : ${_baseline}"
	say ""
	say "--- 1) 分区表（真装机时执行；整盘原有数据全部丢失）---"
	say "  sgdisk --zap-all $DISK"
	say "  p1    FAT32  $BOOT_SIZE   类型 ef00  名称 phase1-boot  -> $_p1"
	say "  p128  EF02   $ESP_SIZE    类型 ef02  名称 phase1-core  -> GRUB core.img 预留（本轮不重建）"
	say "  p2    btrfs  至盘尾        类型 8300  名称 phase1-root  -> ${_p2}（单块 btrfs，全部子卷）"
	say ""
	say "--- 2) btrfs 子卷（只建在 p2 这一块上）---"
	say "  @root     挂载 /rom（运行期只读 ro）   上游 rootfs 解包目标 = 只读基座"
	say "  @overlay  upper/ + work/               唯一读写层，运行期挂 /overlay"
	say "  @docker   → /opt/docker（chattr +C）   docker 数据独立子卷，避免写满 @overlay"
	say "  @swap     → /swap（chattr +C）          swapfile 必须独立子卷（overlayfs 上 swapon 不支持）"
	if [ "$WITH_DATA_SUBVOL" = 1 ]; then
		say "  @data     → /data（--with-data-subvol）HEAD 时代基座的 btrfs-subvols 会挂它"
	else
		say "  （@data 不建；HEAD 时代基座需要它 —— 那种基座默认会被基线检查拦住）"
	fi
	say "  文件系统标签: ${BTRFS_LABEL}（mkfs.btrfs -L）"
	say ""
	say "--- 3) 解包 @root（基座）---"
	say "  源    : $ROOTFS"
	say "  目标  : $DATA_MNT/@root"
	say "  排除  : /proc /sys /dev /tmp /run /boot /rom /overlay /opt/docker /swap /data"
	say "  理由  : tar 会把目录条目递归进去（实测误拷 22GB docker 镜像，decisions §O.2）"
	say ""
	say "--- 4) /.ab-base-manifest（基座清单，供后续 A/B 与 scrub 比对）---"
	say "  收集  : /etc /usr /lib /sbin /bin /www 下的普通文件（不含 /var /tmp /run）"
	say "  格式  : <path><TAB>sha256；真装机时打印条目数（预期数千）"
	say ""
	say "--- 5) 引导分区与 grub ---"
	say "  mkfs.vfat -F 32 -n PHASE1BOOT ${_p1}（装到 ${BOOT_MNT}）"
	say "  拷贝  : $KERNEL -> $BOOT_MNT$KERNEL_PATH"
	say "  拷贝  : $INITRD -> $BOOT_MNT$INITRD_PATH"
	say "  grub-install --target=i386-pc --boot-directory=$BOOT_MNT${BOOT_SUBDIR:+/$BOOT_SUBDIR} $DISK"
	say "  grub-install --target=x86_64-efi --efi-directory=$BOOT_MNT --boot-directory=$BOOT_MNT${BOOT_SUBDIR:+/$BOOT_SUBDIR} --removable --no-nvram ${DISK}（EFI 回退路径 EFI/BOOT/BOOTX64.EFI）"
	say "  渲染  : phase1/grub/grub.cfg.in -> $BOOT_MNT$_grubdir/grub.cfg"
	say "  试跑标记  : grub 视角 ${MARKER_PATH} 或 ${MARKER_PATH_ALT}（= 引导分区根上的 try-phase1）；最终镜像不创建"
	say ""
	say "--- 6) cmdline（渲染后自动校验）---"
	say "  0 号项 : $CMDLINE"
	if [ "$TRIAL" = 1 ]; then
		say "  试跑项 : $(trial_cmdline)"
		say "  试跑项成为默认项的条件: 引导分区根上有 try-phase1（grub 视角 ${MARKER_PATH} 或 ${MARKER_PATH_ALT}）"
	else
		say "  试跑项 : 无（最终镜像只有 0 号项）"
	fi
	say ""
	say "--- 7) 真装机前的分层校验与确认（dry-run 不执行）---"
	say "  a. p1 元数据    : sgdisk -p $DISK + blkid 逐分区"
	say "  b. 文件系统 UUID: blkid -s UUID -o value 逐分区"
	say "  c. 子卷枚举比对 : 建完后 btrfs subvolume list 必须恰为 $SUBVOLS"
	say "  d. 全部打印后才要求手工输入 yes（其它任何输入都取消）"
	say ""
	say "--- 工具检查（仅提示；dry-run 不阻断）---"
	say "  sgdisk=$(tool_state sgdisk) mkfs.vfat=$(tool_state mkfs.vfat) mkfs.btrfs=$(tool_state mkfs.btrfs)"
	say "  btrfs=$(tool_state btrfs) grub-install=$(tool_state grub-install) sha256sum=$(tool_state sha256sum)"
	say ""
	say "dry-run 结束：没有对任何设备执行写操作。"
}

# ---------------------------------------------------------------------------
# 真装机路径
# ---------------------------------------------------------------------------
need_cmd() { # <命令> <安装提示>
	command -v "$1" >/dev/null 2>&1 || fail "缺少工具: $1" "$2"
}

check_tools() {
	need_cmd sgdisk "Debian/Ubuntu: apt install gdisk；OpenWrt: opkg install gdisk"
	need_cmd mkfs.vfat "Debian/Ubuntu: apt install dosfstools；OpenWrt: opkg install dosfstools"
	need_cmd mkfs.btrfs "Debian/Ubuntu: apt install btrfs-progs；OpenWrt: opkg install btrfs-progs"
	need_cmd btrfs "Debian/Ubuntu: apt install btrfs-progs；OpenWrt: opkg install btrfs-progs"
	need_cmd blkid "Debian/Ubuntu: apt install util-linux；OpenWrt: busybox 版可能缺 -s/-o"
	need_cmd tar "Debian/Ubuntu: apt install tar；OpenWrt: busybox tar"
	need_cmd grub-install "Debian/Ubuntu: apt install grub-pc-bin grub-common；OpenWrt: opkg install grub2"
	command -v partx >/dev/null 2>&1 || warn "没有 partx：新分区节点可能要手工 partx -a -n N:N 才出现"
	command -v chattr >/dev/null 2>&1 || warn "没有 chattr：@docker/@swap 的 +C（nocow）会跳过"
}

require_inputs() {
	[ -n "$ROOTFS" ] || usage_fail "真装机需要 --rootfs FILE|DIR（只想看计划请用 --dry-run）"
	[ -n "$DISK" ] || usage_fail "真装机需要 --disk /dev/DEV（只想看计划请用 --dry-run）"
	case $DISK in
	/dev/*) ;;
	*) usage_fail "--disk 必须是整盘设备，收到: $DISK" ;;
	esac
	[ -e "$ROOTFS" ] || fail "rootfs 源不存在: $ROOTFS" "先准备上游 rootfs.tar.gz，或用 --dry-run 只看计划"
	[ -e "$KERNEL" ] || fail "内核文件不存在: $KERNEL" "从固件或 ImageBuilder 产物里取 vmlinuz"
	[ -e "$INITRD" ] || fail "initrd 不存在: $INITRD" "先跑 sh phase1/make-initramfs.sh 产出 initrd"
}

# --- 分层校验（只在真装机用；全部打印，供人工判读）---
preflight_inspect() {
	_p1=$(derive_part "$DISK" 1)
	_p2=$(derive_part "$DISK" 2)

	say "--- 分层校验 0/3：目标盘是否正在被使用 ---"
	assert_target_not_in_use

	say "--- 分层校验 1/3：p1 元数据 ---"
	say "  \$ sgdisk -p $DISK"
	sgdisk -p "$DISK" || fail "sgdisk -p $DISK 失败" "确认 $DISK 是整盘且未被占用"
	say "  \$ blkid $DISK / $_p1 / $_p2"
	blkid "$DISK" 2>/dev/null || warn "blkid $DISK 无输出（新盘正常）"
	if [ -e "$_p1" ]; then blkid "$_p1" 2>/dev/null; fi
	if [ -e "$_p2" ]; then blkid "$_p2" 2>/dev/null; fi

	say "--- 分层校验 2/3：文件系统 UUID（覆盖后全部作废）---"
	for _d in "$_p1" "$_p2"; do
		if [ -e "$_d" ]; then
			_u=$(blkid -s UUID -o value "$_d" 2>/dev/null)
			say "  $_d UUID=${_u:-<无>}"
		fi
	done

	say "--- 分层校验 3/3：子卷枚举比对（当前 p2 上已有的子卷）---"
	if mountpoint_present "$_p2"; then
		warn "$_p2 已挂载，跳过子卷枚举（覆盖前请自行确认）"
	elif [ -e "$_p2" ] && mount -t btrfs -o ro "$_p2" "$DATA_MNT" 2>/dev/null; then
		btrfs subvolume list "$DATA_MNT" || warn "btrfs subvolume list 无输出"
		umount "$DATA_MNT" || fail "无法卸载 $DATA_MNT" "手工 umount 后重跑"
	else
		warn "$_p2 不存在或不是 btrfs（新盘正常）"
	fi
	say "  期望（装完后）: $SUBVOLS"
}

postcheck_subvols() {
	_actual=$(btrfs subvolume list "$DATA_MNT" 2>/dev/null | awk '{print $NF}' | sed 's#.*/##' | sort | tr '\n' ' ')
	_want=$(printf '%s' "$SUBVOLS" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')
	say "  实际子卷: [$_actual]"
	say "  期望子卷: [$_want]"
	[ "$_actual" = "$_want" ] || fail "子卷枚举与期望不一致" "umount $DATA_MNT 后重跑，或手工核对 btrfs subvolume list"
}

confirm_yes() {
	printf '\n'
	printf '  !! 以上操作会重建 %s 的分区表并格式化 p1/p2，盘上原有数据全部丢失。\n' "$DISK"
	printf '  确认继续请输入 yes（其它任何输入都会取消）: '
	_ans=''
	read -r _ans || _ans=''
	[ "$_ans" = "yes" ] || fail "已取消（输入不是 yes）" "什么都没做；要真装机请重跑并输入 yes"
}

# --- 解包（必须排除挂载点，见 decisions §O.2）---
extract_rootfs() { # <源 FILE|DIR> <目标目录>
	_src=$1
	_dst=$2
	# 这些目录在基座里必须是空挂载点，绝不能把宿主内容拷进去
	set -- \
		--exclude=./proc \
		--exclude=./sys \
		--exclude=./dev \
		--exclude=./tmp \
		--exclude=./run \
		--exclude=./boot \
		--exclude=./rom \
		--exclude=./overlay \
		--exclude=./opt/docker \
		--exclude=./swap \
		--exclude=./data
	if [ -d "$_src" ]; then
		# M2：不能用 `tar -c … | tar -x …`（POSIX sh 没有 pipefail，源侧失败会被解包侧的 0 吞掉，
		# 结果是一台"装完起不来"的半残基座）。改成两段式：先落临时 tar 并判 rc，再解。
		_stage=$DATA_MNT/.phase1-stage.tar
		say "  归档（目录源 -> 临时 tar）: $_src -> $_stage"
		(cd "$_src" && tar -cf "$_stage" "$@" .) ||
			fail "归档失败: ${_src}（半残基座会被拒绝）" "确认 p2 空间够（rootfs 解包后大小 + 同尺寸临时 tar）"
		[ -s "$_stage" ] || fail "临时 tar 是空的: $_stage" "检查 rootfs 目录是不是空的"
		say "  解包（临时 tar -> @root）: $_stage -> $_dst"
		tar -xpf "$_stage" "$@" -C "$_dst" ||
			fail "解包失败: $_stage -> $_dst" "确认 p2 空间够（子卷 >= rootfs 解包后大小）"
		rm -f "$_stage"
	else
		say "  解包（tar 源）: $_src -> $_dst"
		tar -xpf "$_src" "$@" -C "$_dst" ||
			fail "解包失败: $_src -> $_dst" "确认 $ROOTFS 是未损坏的 rootfs.tar.gz"
	fi

	# 补回挂载点目录本体（**根因修复**，不只是运行时兜底）。
	# 为什么必须有这一步：上面那串 exclude 会把**目录项本身**一起排掉（GNU tar 语义，
	# 2026-11-07 用同样的 argv 复现过），而上游 base-files 是显式 `mkdir -p` 这些骨架目录并
	# `chmod 1777 /tmp` 的。目录缺席时 procd 的裸 mount(2) 全部 ENOENT 且不检查返回值 ⇒ 用户态没有
	# /proc /sys /dev ⇒ netifd 读不到 /sys/class/net ⇒ 一个网口都不配置（真机事故②）。
	# initramfs 里也补了一遍（defense-in-depth），但镜像本体必须是完整的：换任何别的引导路径
	# （上游 initramfs、将来 A/B 换槽）都不该重新踩这个坑。
	for _mp in proc sys dev tmp; do
		mkdir -p "$_dst/$_mp" || fail "补建挂载点失败: $_dst/$_mp" "确认 @root 可写"
	done
	chmod 1777 "$_dst/tmp" || fail "chmod 1777 $_dst/tmp 失败" "tmp 必须是 1777（上游约定）"
	for _mp in proc sys dev tmp; do
		[ -d "$_dst/$_mp" ] || fail "挂载点目录缺失: $_dst/$_mp" "排除清单把目录本体排掉了？"
	done
	say "  挂载点  : 已补建 /proc /sys /dev /tmp（tmp 为 1777）"
}

sha256_of() { # <文件>
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		return 1
	fi
}

write_manifest() { # <@root 挂载点>
	_root=$1
	_out=$_root/.ab-base-manifest
	: >"$_out" || fail "无法写 manifest: $_out" "确认 @root 可写（解包后仍是 rw 挂载）"

	set -- etc usr lib sbin bin www
	for _d in "$@"; do
		# /lib 常是指向 usr/lib 的软链：find 不跟软链，条目已由 usr 覆盖
		if [ -d "$_root/$_d" ]; then
			find "$_root/$_d" -type f 2>/dev/null
		fi
	done >"$_out.files" || fail "列举文件失败: $_out.files" "检查 @root 是否真的解开"

	while IFS= read -r _f; do
		_rel=${_f#"$_root"}
		if _sum=$(sha256_of "$_f"); then
			printf '%s\t%s\n' "$_rel" "$_sum"
		else
			fail "没有 sha256sum 也没有 shasum" "opkg install coreutils-sha256sum"
		fi
	done <"$_out.files" >"$_out" || fail "生成 manifest 失败: $_out" "检查 p2 空间与权限"
	rm -f "$_out.files"

	_n=$(wc -l <"$_out" | tr -d ' ')
	say "  manifest: $_out  条目数=$_n"
	case $_n in
	'' | *[!0-9]*) fail "manifest 条目数异常: $_n" "检查 @root 是否真的解开成功" ;;
	esac
	# 上游 rootfs 的 /etc /usr /lib /sbin /bin /www 有数千个文件；明显偏少 = 解包不完整，
	# 直接 fail（M2 的配套：宁可装不下去，也不要装出一台起不来的机器）
	if [ "$_n" -lt 1000 ]; then
		fail "manifest 只有 $_n 条（<1000），基座疑似半残" "重跑装机；确属精简 rootfs 请先把阈值改掉并说明理由"
	fi
}

install_grub() { # <内核文件> <initrd 文件> [目标设备，默认 $DISK] [额外参数，镜像模式传 --no-floppy 且不 --recheck]
	_kg=$1
	_ig=$2
	_target=${3:-$DISK}
	_extra=${4:-}
	_bootdir=$BOOT_MNT${BOOT_SUBDIR:+/$BOOT_SUBDIR}

	mkdir -p "$_bootdir" || fail "无法创建 $_bootdir" "确认 p1 已挂到 $BOOT_MNT"
	cp "$_kg" "$BOOT_MNT$KERNEL_PATH" || fail "拷贝内核失败: $KERNEL_PATH" "确认 p1 空间够（256M）"
	cp "$_ig" "$BOOT_MNT$INITRD_PATH" || fail "拷贝 initrd 失败: $INITRD_PATH" "确认 p1 空间够（256M）"
	say "  拷贝: $KERNEL -> $BOOT_MNT$KERNEL_PATH"
	say "  拷贝: $INITRD -> $BOOT_MNT$INITRD_PATH"

	# Phase 1：这里就是唯一一次写 core.img（装到 p128 EF02）。后续只在模块集合变化时
	# 才需要重建，那是 Phase 3 的事（见 decisions §0.1 的 p128 说明）。
	# 真装机：带 --recheck（重新探测设备映射，盘可能刚分区）。
	# 镜像模式：只带 --no-floppy、**不带** --recheck（目标是一个 loop；--recheck 会去探宿主设备，
	# 在 CI 上既慢又可能因"找不到设备映射"误报）。
	# `--no-recheck` 只是调用方的**内部标记**，不是 grub-install 的选项（grub-install 没有它，
	# 首跑实测：unrecognized option '--no-recheck'），所以这里要把它从真正下发的参数里滤掉。
	_skip_recheck=0
	_ghflags=''
	for _a in $_extra; do
		case $_a in
		--no-recheck) _skip_recheck=1 ;;
		*) _ghflags="${_ghflags}${_ghflags:+ }${_a}" ;;
		esac
	done
	if [ "$_skip_recheck" = 0 ]; then
		_ghflags="${_ghflags}${_ghflags:+ }--recheck"
	fi
	say "  \$ grub-install --target=i386-pc --boot-directory=$_bootdir --modules=\"$GRUB_MODULES\" ${_ghflags} $_target"
	# shellcheck disable=SC2086
	grub-install --target=i386-pc \
		--boot-directory="$_bootdir" \
		--modules="$GRUB_MODULES" \
		$_ghflags "$_target" ||
		fail "grub-install 失败" "确认 p128 EF02 分区存在（sgdisk -p $_target 的第 128 号）"

	# legacy 装完再装 UEFI：镜像要**双模**。理由（2026-11-07 真机事故）：
	#   N5105 的固件是纯 UEFI（AMI v2.70，无 CSM）。UEFI 只认 ESP 上的
	#   \EFI\BOOT\BOOTX64.EFI（可移动介质回退路径），而当时镜像只装了 i386-pc，
	#   固件枚举不到可引导项，直接落到内置 "UEFI Interactive Shell v2.2"。
	#   --removable 生成回退路径、--no-nvram 不写 NVRAM（整盘 dd 出来的盘本来也无法写）。
	install_grub_efi "$_target"
}

# UEFI（x86_64-efi）引导器安装。必须在 p1 以 vfat 挂载、且分区类型为 EF00 时调用。
install_grub_efi() { # <目标盘（仅日志用）>
	_efi_target=$1
	_efi_mods='part_gpt fat normal linux search search_fs_uuid search_label test echo serial terminal configfile'
	if [ ! -d /usr/lib/grub/x86_64-efi ] && [ ! -d /usr/share/grub/x86_64-efi ]; then
		fail "找不到 x86_64-efi 模块树" "装 grub-efi-amd64-bin（Debian/Ubuntu: apt install grub-efi-amd64-bin），否则打不出 UEFI 引导器"
	fi
	say "  \$ grub-install --target=x86_64-efi --efi-directory=$BOOT_MNT --boot-directory=$BOOT_MNT$(boot_prefix) --removable --no-nvram --modules=\"$_efi_mods\""
	grub-install --target=x86_64-efi \
		--efi-directory="$BOOT_MNT" \
		--boot-directory="$BOOT_MNT$(boot_prefix)" \
		--removable --no-nvram \
		--modules="$_efi_mods" \
		"$_efi_target" ||
		fail "grub-install --target=x86_64-efi 失败" "确认 p1 已按 vfat 挂载、类型 EF00；确认装了 grub-efi-amd64-bin"
	# 没落到 ESP 就不是"可 UEFI 引导"的镜像，必须当场失败（别把问题留到真机）
	[ -f "$BOOT_MNT/EFI/BOOT/BOOTX64.EFI" ] ||
		fail "EFI 引导器没落到 ESP" "期望 $BOOT_MNT/EFI/BOOT/BOOTX64.EFI（--removable 的产物）"
	_efi_magic=$(dd if="$BOOT_MNT/EFI/BOOT/BOOTX64.EFI" bs=1 count=2 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
	if [ "$_efi_magic" != "4d5a" ]; then
		fail "BOOTX64.EFI 不是 PE 可执行文件（magic=${_efi_magic}，应为 4d5a=MZ）" "确认装的是 x86_64-efi 而不是 arm64-efi"
	fi
	# `--removable` 把引导器的 prefix 写死成 /EFI/BOOT：它只在那下面找 grub.cfg 与 <platform>/*.mod。
	# 而 --boot-directory 指到 p1 的 boot/ 时，模块被装到 boot/grub/x86_64-efi ⇒ EFI 侧找不到，
	# 连 grub.cfg 都读不到 ⇒ 屏幕/串口一句不出、看起来像"没引导"（2026-11-07 CI 冒烟实测）。
	# 所以在 EFI/BOOT 下放一份模块树，配置由 render_cfg 之后 sync_efi_cfg 复制过去。
	# 注意：本仓有护栏禁止 assemble-image.sh 里出现**递归删除**（见 phase1/tests/assemble-dry-run.sh），
	# 所以这里用"合并拷贝"而不是先删后拷：
	# 目标目录先建好，再把源目录内容 cp -a 进去（幂等，重复构建不会嵌套出 x86_64-efi/x86_64-efi）。
	mkdir -p "$BOOT_MNT/EFI/BOOT/x86_64-efi" || fail "无法创建 $BOOT_MNT/EFI/BOOT/x86_64-efi" "确认 p1 可写"
	cp -a "$BOOT_MNT$(boot_prefix)/grub/x86_64-efi/." "$BOOT_MNT/EFI/BOOT/x86_64-efi/" ||
		fail "复制 x86_64-efi 模块到 EFI/BOOT 失败" "确认 --boot-directory 下有 grub/x86_64-efi（grub-efi-amd64-bin 装了吗）"
	[ -d "$BOOT_MNT/EFI/BOOT/x86_64-efi" ] ||
		fail "EFI/BOOT/x86_64-efi 缺失" "prefix=/EFI/BOOT 的引导器会找不到模块"
	say "  EFI 引导器: $BOOT_MNT/EFI/BOOT/BOOTX64.EFI（$(wc -c <"$BOOT_MNT/EFI/BOOT/BOOTX64.EFI" | tr -d ' ') 字节）+ 模块树 $(boot_prefix)/grub/x86_64-efi → EFI/BOOT/x86_64-efi"
}

# 渲染完 grub.cfg 后同步一份到 EFI/BOOT（prefix=/EFI/BOOT 的引导器读的是这一份）。
sync_efi_cfg() { # <已渲染的 grub.cfg>
	[ -d "$BOOT_MNT/EFI/BOOT" ] || return 0
	cp "$1" "$BOOT_MNT/EFI/BOOT/grub.cfg" || fail "同步 grub.cfg 到 EFI/BOOT 失败" "确认 p1 可写"
	say "  EFI 配置: EFI/BOOT/grub.cfg（与 $(boot_prefix)/grub/grub.cfg 同一份内容）"
}

# --- 唯一的破坏性入口：所有写盘动作都在这个函数里 ---
destructive_install() {
	_p1=$(derive_part "$DISK" 1)
	_p2=$(derive_part "$DISK" 2)
	_grubdir=$BOOT_MNT$(boot_prefix)/grub

	# M3：第一条就是"目标盘不能被自己用着"——在设备本机跑 = 重建正在运行的分区表
	assert_target_not_in_use

	mkdir -p "$BOOT_MNT" "$DATA_MNT" || fail "无法创建挂载点 $BOOT_MNT / $DATA_MNT" "确认 /mnt 可写"

	# 1) 分区表：按 p1 → p128 → p2 的顺序分配扇区（--set-alignment 固定对齐，避免几何漂移）
	say "  \$ sgdisk --zap-all $DISK"
	sgdisk --zap-all "$DISK" || fail "sgdisk --zap-all 失败" "确认 $DISK 未被挂载/占用"
	say "  \$ sgdisk --set-alignment=2048 --new=1:0:+$BOOT_SIZE --new=128:0:+$ESP_SIZE --new=2:0:0 $DISK"
	sgdisk --set-alignment=2048 \
		--new=1:0:+"$BOOT_SIZE" --typecode=1:ef00 --change-name=1:phase1-boot \
		--new=128:0:+"$ESP_SIZE" --typecode=128:ef02 --change-name=128:phase1-core \
		--new=2:0:0 --typecode=2:8300 --change-name=2:phase1-root \
		"$DISK" || fail "sgdisk 建分区失败" "确认 $DISK 容量够 $BOOT_SIZE + $ESP_SIZE + rootfs"

	# 让内核看到新分区：只加需要的号（整表重加会撞上已挂载分区，见 handoff §5）
	if command -v partx >/dev/null 2>&1; then
		partx -a -n 1:1 "$DISK" 2>/dev/null || warn "partx -a -n 1:1 失败（可忽略）"
		partx -a -n 2:2 "$DISK" 2>/dev/null || warn "partx -a -n 2:2 失败（可忽略）"
	fi
	[ -b "$_p1" ] || fail "分区节点缺失: $_p1" "手工 partx -a -n 1:1 $DISK 后重跑"
	[ -b "$_p2" ] || fail "分区节点缺失: $_p2" "手工 partx -a -n 2:2 $DISK 后重跑"

	# 2) 文件系统
	say "  \$ mkfs.vfat -F 32 -n PHASE1BOOT $_p1"
	mkfs.vfat -F 32 -n PHASE1BOOT "$_p1" || fail "mkfs.vfat 失败: $_p1" "确认 p1 是 256M 的 ef00 分区"
	say "  \$ mkfs.btrfs -f -L $BTRFS_LABEL $_p2"
	mkfs.btrfs -f -L "$BTRFS_LABEL" "$_p2" || fail "mkfs.btrfs 失败: $_p2" "确认 p2 存在且未挂载"

	# 3) 子卷
	mount -t btrfs -o noatime "$_p2" "$DATA_MNT" || fail "挂载 p2 失败: $_p2" "确认 mkfs.btrfs 已成功"
	for _s in $SUBVOLS; do
		say "  \$ btrfs subvolume create $DATA_MNT/$_s"
		btrfs subvolume create "$DATA_MNT/$_s" || fail "建子卷失败: $_s" "确认 p2 空间与挂载状态"
	done
	# docker / swap 关掉 COW：必须在目录为空时设置才生效
	say "  \$ chattr +C $DATA_MNT/@docker $DATA_MNT/@swap"
	chattr +C "$DATA_MNT/@docker" 2>/dev/null || warn "chattr +C @docker 失败（确认 e2fsprogs 已装）"
	chattr +C "$DATA_MNT/@swap" 2>/dev/null || warn "chattr +C @swap 失败（确认 e2fsprogs 已装）"

	# 4) 解包基座 + manifest
	extract_rootfs "$ROOTFS" "$DATA_MNT/@root"
	mkdir -p "$DATA_MNT/@overlay/upper" "$DATA_MNT/@overlay/work" ||
		fail "无法建 upper/work" "确认 @overlay 子卷创建成功"
	write_manifest "$DATA_MNT/@root"
	# @root 在这里是 rw（解包要写）；运行期由 /init 以 ro 挂到 /rom，装机阶段不需要改挂载
	sync

	# 5) 引导分区 + grub
	mount -t vfat "$_p1" "$BOOT_MNT" || fail "挂载 p1 失败: $_p1" "确认 mkfs.vfat 已成功"
	install_grub "$KERNEL" "$INITRD"
	mkdir -p "$_grubdir" || fail "无法创建 $_grubdir" "确认 p1 已挂载"
	render_cfg "$_grubdir" || fail "渲染 grub.cfg 失败" "检查 --cmdline 是否满足硬规则"
	sync_efi_cfg "$_grubdir/grub.cfg"
	# 最终镜像**不**创建试跑标记：0 号项就是唯一入口
	sync
	umount "$BOOT_MNT" || warn "卸载 $BOOT_MNT 失败（重启前请手工 umount）"

	# 6) 收尾比对
	postcheck_subvols
	umount "$DATA_MNT" || warn "卸载 $DATA_MNT 失败（重启前请手工 umount）"

	say ''
	say '装完。下一步：'
	say "  1) 核对 p2 上是 ${SUBVOLS}，p1 里有 $KERNEL_PATH / $INITRD_PATH / $(boot_prefix)/grub/grub.cfg"
	say '  2) 第一次启动前不要创建试跑标记（最终镜像只有 0 号项）'
	say '  3) 真机取证按 prd.md 的 ac-8..ac-12 执行（phase1/README.md 有步骤）'
}

# ---------------------------------------------------------------------------
# 镜像文件模式（--image OUT.img --size 8G）
#
# 边界（与真装机的唯一区别）：目标是一个普通文件 + 一个 loop 设备，**不碰 /dev 下的整盘**，
# 因此不需要人工 yes；但仍然全部 fail-closed，且用 trap 保证"失败也把 loop 拆掉"。
# ---------------------------------------------------------------------------
IMAGE_LOOP=''
IMAGE_P1=''
IMAGE_P2=''
IMAGE_P1_ON=0
IMAGE_P2_ON=0

image_teardown() { # [信号退出码]：失败/中断也必须把 loop 拆掉，绝不留半个 loop 设备
	# 信号 trap 里 $? 是"上一条命令"的状态（通常是 0），直接用它会把 Ctrl-C / CI 取消
	# 变成 exit 0 ⇒ build.sh 会接着把半截镜像压成 .img.gz 当成功产物。所以信号路径强制非 0。
	_rc=$?
	if [ "$#" -ge 1 ]; then
		_rc=$1
	fi
	if [ "$_rc" = 0 ]; then
		_rc=1
	fi
	trap - EXIT INT TERM HUP
	if [ "$IMAGE_P1_ON" = 1 ]; then
		umount "$BOOT_MNT" 2>/dev/null || warn "镜像 p1 卸载失败: ${BOOT_MNT}（detach loop 时内核会自行释放）"
		IMAGE_P1_ON=0
	fi
	if [ "$IMAGE_P2_ON" = 1 ]; then
		umount "$DATA_MNT" 2>/dev/null || warn "镜像 p2 卸载失败: ${DATA_MNT}（detach loop 时内核会自行释放）"
		IMAGE_P2_ON=0
	fi
	if [ -n "$IMAGE_LOOP" ]; then
		losetup -d "$IMAGE_LOOP" 2>/dev/null || warn "losetup -d $IMAGE_LOOP 失败（镜像文件仍可用，请手工 detach）"
		IMAGE_LOOP=''
	fi
	exit "$_rc"
}

image_check_platform() {
	if [ "$(uname -s 2>/dev/null)" != Linux ]; then
		fail "镜像模式只在 Linux 上跑（当前 $(uname -s 2>/dev/null || echo unknown)：macOS 没有 losetup/mkfs.vfat/mkfs.btrfs）" "在 CI（ubuntu-22.04）或任意 Linux 主机上 sudo 跑；macOS 只跑 --dry-run 与静态用例（phase1/tests/assemble-image-mode.sh）"
	fi
	if [ "$(id -u 2>/dev/null)" != 0 ]; then
		fail "镜像模式需要 root（losetup / mount / mkfs 都要特权）" "用 sudo sh $PROG --image ... --size ..."
	fi
}

image_check_tools() {
	# CI（ubuntu-22.04）一条命令装齐：apt-get install -y gdisk dosfstools btrfs-progs grub-pc-bin
	#   grub-common util-linux coreutils e2fsprogs cpio
	need_cmd truncate "Debian/Ubuntu: apt install coreutils"
	need_cmd losetup "Debian/Ubuntu: apt install util-linux"
	need_cmd sgdisk "Debian/Ubuntu: apt install gdisk"
	need_cmd mkfs.vfat "Debian/Ubuntu: apt install dosfstools"
	need_cmd mkfs.btrfs "Debian/Ubuntu: apt install btrfs-progs"
	need_cmd btrfs "Debian/Ubuntu: apt install btrfs-progs"
	need_cmd grub-install "Debian/Ubuntu: apt install grub-pc-bin grub-common（i386-pc 模块树在 grub-pc-bin）"
	need_cmd mount "Debian/Ubuntu: apt install util-linux"
	need_cmd umount "Debian/Ubuntu: apt install util-linux"
	need_cmd tar "Debian/Ubuntu: apt install tar"
	command -v partx >/dev/null 2>&1 || warn "没有 partx：分区节点可能不出现（util-linux 一般自带）"
	command -v chattr >/dev/null 2>&1 || warn "没有 chattr：@docker/@swap 的 +C（nocow）会跳过"
}

require_image_inputs() {
	[ -n "$ROOTFS" ] || usage_fail "镜像模式需要 --rootfs FILE|DIR（配 --image 时必填）"
	[ -n "$KERNEL" ] || usage_fail "镜像模式需要 --kernel FILE（配 --image 时必填）"
	[ -n "$INITRD" ] || usage_fail "镜像模式需要 --initrd FILE（配 --image 时必填）"
	[ -e "$ROOTFS" ] || fail "rootfs 源不存在: $ROOTFS" "先准备 rootfs.tar.gz 或用 --dry-run --image 只看计划"
	[ -e "$KERNEL" ] || fail "内核文件不存在: $KERNEL" "从 ImageBuilder 产物里取 boot/vmlinuz"
	[ -e "$INITRD" ] || fail "initrd 不存在: $INITRD" "先跑 sh phase1/make-initramfs.sh 产出 initrd"
}

image_wait_part() { # <分区节点>：等内核把分区节点建出来（最多 ~10s）
	_i=0
	while [ "$_i" -lt 10 ]; do
		if [ -b "$1" ]; then
			return 0
		fi
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

print_image_plan() {
	[ -n "$ROOTFS" ] || usage_fail "--dry-run --image 需要 --rootfs FILE|DIR（计划里要写清基座来源）"
	check_rootfs_baseline
	if [ -n "$(rootfs_baseline_suspects "$ROOTFS" 2>/dev/null)" ]; then
		_baseline='HEAD 时代内容（已 --allow-legacy-rootfs 放行）'
	else
		_baseline='通过（没有 btrfs-subvols / extroot fstab 迹象）'
	fi
	_mb=$(image_size_mb "$IMAGE_SIZE")

	say "=== phase1 镜像构建计划（--image：只打印，不写盘、不 mkfs、不碰 /dev）==="
	say ""
	say "镜像文件      : ${IMAGE}（大小 ${IMAGE_SIZE} = ${_mb}M，未压缩）"
	say "rootfs 源     : $ROOTFS"
	say "内核          : $KERNEL  -> grub 路径 $KERNEL_PATH"
	say "initrd        : $INITRD  -> grub 路径 $INITRD_PATH"
	say "引导分区前缀  : ${BOOT_SUBDIR:-<FAT 根>}"
	say "btrfs 标签    : ${BTRFS_LABEL}（--btrfs-label）"
	say "@data 子卷    : $([ "$WITH_DATA_SUBVOL" = 1 ] && echo '建（--with-data-subvol）' || echo '不建')"
	say "rootfs 基线   : ${_baseline}"
	say "安全边界      : 只写 ${IMAGE} 这一个普通文件；不碰 /dev 下任何整盘；不需要人工 yes"
	say ""
	say "--- 1) 建文件并挂成 loop ---"
	say "  truncate -s ${IMAGE_SIZE} ${IMAGE}"
	say "  losetup --find --show --partscan ${IMAGE}   # partscan = -P，让内核感知分区"
	say "  （失败退化：losetup -f --show + partx -u；分区节点最多等 10s）"
	say ""
	say "--- 2) 分区表（p2 物理最后，首启扩容只重建 p2）---"
	say "  sgdisk --zap-all <loop>"
	say "  p1    FAT32  ${BOOT_SIZE}   ef00  phase1-boot  -> mkfs.vfat -F 32 -n PHASE1BOOT"
	say "  p128  EF02   ${ESP_SIZE}    ef02  phase1-core  -> GRUB core.img"
	say "  p2    btrfs  至镜像末尾     8300  phase1-root  -> mkfs.btrfs -f -L ${BTRFS_LABEL}"
	say ""
	say "--- 3) 子卷（只建在 p2 上）---"
	say "  ${SUBVOLS}"
	say "  @docker / @swap 打完 mkfs 立刻 chattr +C（必须空目录时设置才生效）"
	say ""
	say "--- 4) 解包 @root + manifest ---"
	say "  源    : $ROOTFS"
	say "  排除  : /proc /sys /dev /tmp /run /boot /rom /overlay /opt/docker /swap /data"
	say "  manifest : <@root>/.ab-base-manifest（<path><TAB>sha256，条目 <1000 直接失败）"
	say ""
	say "--- 5) 引导分区 + grub ---"
	say "  拷贝  : $KERNEL -> <p1>$KERNEL_PATH"
	say "  拷贝  : $INITRD -> <p1>$INITRD_PATH"
	say "  grub-install --target=i386-pc --boot-directory=<p1>/${BOOT_SUBDIR} --modules=\"${GRUB_MODULES}\" <loop>"
	say "  渲染  : phase1/grub/grub.cfg.in -> <p1>$(boot_prefix)/grub/grub.cfg（只有 0 号项）"
	say "  试跑标记  : 不创建（最终镜像的 0 号项就是唯一入口）"
	say ""
	say "--- 6) cmdline（渲染后自动校验）---"
	say "  0 号项 : $CMDLINE"
	say "  根设备 : 由 initrd 烘焙（phase1/make-initramfs.sh --rootdev），镜像的 grub.cfg 不含 phase1_dev="
	say ""
	say "--- 7) 收尾与清理 ---"
	say "  btrfs subvolume list 比对恰为 ${SUBVOLS}"
	say "  umount <p1> / <p2> && losetup -d <loop>（trap 保证失败时也执行）"
	say "  产物  : ${IMAGE}（未压缩；gzip 与 sha256 由 phase1/build.sh 负责）"
	say ""
	say "dry-run 结束：没有对任何设备或文件执行写操作。"
}

image_write() {
	IMAGE_LOOP=''
	IMAGE_P1_ON=0
	IMAGE_P2_ON=0
	trap image_teardown EXIT
	trap 'image_teardown 130' INT
	trap 'image_teardown 143' TERM HUP

	say "=== 镜像文件模式（只写 ${IMAGE}）==="
	say "  rootfs 源 : $ROOTFS"
	say "  内核      : $KERNEL  -> ${KERNEL_PATH}"
	say "  initrd    : $INITRD  -> ${INITRD_PATH}"

	# 1) 建文件 + 挂 loop
	say "  1) 建镜像文件 + loop"
	say "  \$ truncate -s ${IMAGE_SIZE} ${IMAGE}"
	: >"$IMAGE" || fail "无法创建镜像文件: ${IMAGE}" "确认父目录存在且可写（不要指向 /dev 下的设备）"
	truncate -s "$IMAGE_SIZE" "$IMAGE" || fail "truncate 失败: ${IMAGE}" "确认磁盘空间够 ${IMAGE_SIZE}"
	IMAGE_LOOP=$(losetup --find --show --partscan "$IMAGE" 2>/dev/null) || IMAGE_LOOP=''
	if [ -z "$IMAGE_LOOP" ]; then
		IMAGE_LOOP=$(losetup -f --show "$IMAGE" 2>/dev/null) || IMAGE_LOOP=''
	fi
	[ -n "$IMAGE_LOOP" ] || fail "losetup 失败: ${IMAGE}" "确认 loop 模块可用（modprobe loop），且该镜像没有被别的 loop 占着"
	say "  loop 设备 : ${IMAGE_LOOP}"
	IMAGE_P1=$(derive_part "$IMAGE_LOOP" 1)
	IMAGE_P2=$(derive_part "$IMAGE_LOOP" 2)

	# 2) 分区表（与真装机同一套几何，只是目标换成 loop）
	say "  2) 分区表：p1 -> p128 -> p2（p2 物理最后）"
	say "  \$ sgdisk --zap-all ${IMAGE_LOOP}"
	sgdisk --zap-all "$IMAGE_LOOP" || fail "sgdisk --zap-all 失败: ${IMAGE_LOOP}" "确认 loop 设备未被占用"
	say "  \$ sgdisk --set-alignment=2048 --new=1:0:+${BOOT_SIZE} --new=128:0:+${ESP_SIZE} --new=2:0:0 ${IMAGE_LOOP}"
	sgdisk --set-alignment=2048 \
		--new=1:0:+"$BOOT_SIZE" --typecode=1:ef00 --change-name=1:phase1-boot \
		--new=128:0:+"$ESP_SIZE" --typecode=128:ef02 --change-name=128:phase1-core \
		--new=2:0:0 --typecode=2:8300 --change-name=2:phase1-root \
		"$IMAGE_LOOP" || fail "sgdisk 建分区失败" "确认 ${IMAGE_SIZE} 够 ${BOOT_SIZE} + ${ESP_SIZE} + rootfs"
	if command -v partx >/dev/null 2>&1; then
		# 新写出来的分区表在 loop 上第一次要"add"，之后才是"update"；两条都试，失败不算硬错
		# （losetup -P 已置 PARTSCAN 时内核自己会扫出来）
		partx -a "$IMAGE_LOOP" 2>/dev/null || partx -u "$IMAGE_LOOP" 2>/dev/null ||
			warn "partx 失败（只要分区节点随后出现就不影响结果）"
	fi
	image_wait_part "$IMAGE_P1" || fail "分区节点缺失: ${IMAGE_P1}" "手工 partx -u ${IMAGE_LOOP} 后重跑"
	image_wait_part "$IMAGE_P2" || fail "分区节点缺失: ${IMAGE_P2}" "手工 partx -u ${IMAGE_LOOP} 后重跑"

	# 3) 文件系统 + 子卷
	say "  3) 文件系统 + 子卷"
	say "  \$ mkfs.vfat -F 32 -n PHASE1BOOT ${IMAGE_P1}"
	mkfs.vfat -F 32 -n PHASE1BOOT "$IMAGE_P1" || fail "mkfs.vfat 失败: ${IMAGE_P1}" "确认 p1 是 ${BOOT_SIZE} 的 ef00 分区"
	say "  \$ mkfs.btrfs -f -L ${BTRFS_LABEL} ${IMAGE_P2}"
	mkfs.btrfs -f -L "$BTRFS_LABEL" "$IMAGE_P2" || fail "mkfs.btrfs 失败: ${IMAGE_P2}" "确认 p2 存在且未挂载"
	mkdir -p "$DATA_MNT" || fail "无法创建挂载点 $DATA_MNT" "确认 /mnt 可写"
	# 挂载点已占用时叠挂会让 postcheck_subvols 读到别的东西、teardown 的 umount 只摘顶层
	# ⇒ loop 变 busy、losetup -d 只 warn，等于"留半个 loop 设备"。所以先查。
	if mountpoint_present "$DATA_MNT"; then
		fail "挂载点 ${DATA_MNT} 已被占用（并发构建或上次失败的残留）" "先 umount ${DATA_MNT}（必要时 umount -l）再重跑"
	fi
	mount -t btrfs -o noatime "$IMAGE_P2" "$DATA_MNT" || fail "挂载 p2 失败: ${IMAGE_P2}" "确认 mkfs.btrfs 已成功"
	IMAGE_P2_ON=1
	for _s in $SUBVOLS; do
		say "  \$ btrfs subvolume create $DATA_MNT/$_s"
		btrfs subvolume create "$DATA_MNT/$_s" || fail "建子卷失败: $_s" "确认 p2 空间与挂载状态"
	done
	chattr +C "$DATA_MNT/@docker" 2>/dev/null || warn "chattr +C @docker 失败（确认 e2fsprogs 已装）"
	chattr +C "$DATA_MNT/@swap" 2>/dev/null || warn "chattr +C @swap 失败（确认 e2fsprogs 已装）"

	# 4) 解包 + manifest
	say "  4) 解包 @root + manifest"
	extract_rootfs "$ROOTFS" "$DATA_MNT/@root"
	mkdir -p "$DATA_MNT/@overlay/upper" "$DATA_MNT/@overlay/work" ||
		fail "无法建 upper/work" "确认 @overlay 子卷创建成功"
	write_manifest "$DATA_MNT/@root"
	sync

	# 5) 引导分区 + grub
	say "  5) 引导分区 + grub"
	mkdir -p "$BOOT_MNT" || fail "无法创建挂载点 $BOOT_MNT" "确认 /mnt 可写"
	if mountpoint_present "$BOOT_MNT"; then
		fail "挂载点 ${BOOT_MNT} 已被占用（并发构建或上次失败的残留）" "先 umount ${BOOT_MNT}（必要时 umount -l）再重跑"
	fi
	mount -t vfat "$IMAGE_P1" "$BOOT_MNT" || fail "挂载 p1 失败: ${IMAGE_P1}" "确认 mkfs.vfat 已成功"
	IMAGE_P1_ON=1
	install_grub "$KERNEL" "$INITRD" "$IMAGE_LOOP" "--no-floppy --no-recheck"
	_grubdir=$BOOT_MNT$(boot_prefix)/grub
	mkdir -p "$_grubdir" || fail "无法创建 $_grubdir" "确认 p1 已挂载"
	render_cfg "$_grubdir" || fail "渲染 grub.cfg 失败" "检查 --cmdline 是否满足硬规则"
	sync_efi_cfg "$_grubdir/grub.cfg"
	# 最终镜像**不**创建试跑标记：0 号项就是唯一入口
	sync
	umount "$BOOT_MNT" || fail "卸载镜像 p1 失败: $BOOT_MNT" "确认没有进程占着 $BOOT_MNT"
	IMAGE_P1_ON=0

	# 6) 收尾比对
	say "  6) 收尾比对"
	postcheck_subvols
	umount "$DATA_MNT" || fail "卸载镜像 p2 失败: $DATA_MNT" "确认没有进程占着 $DATA_MNT"
	IMAGE_P2_ON=0

	losetup -d "$IMAGE_LOOP" 2>/dev/null || warn "losetup -d $IMAGE_LOOP 失败（镜像文件可继续使用）"
	IMAGE_LOOP=''
	trap - EXIT INT TERM HUP

	_sum=$(sha256_of "$IMAGE" 2>/dev/null) || _sum='<无 sha256sum/shasum>'
	_size=$(wc -c <"$IMAGE" | tr -d ' ')
	say ''
	say "镜像完成（未压缩）: ${IMAGE}"
	say "  大小   : ${_size} 字节"
	say "  sha256 : ${_sum}"
	say '  下一步: gzip -9 -n 压缩并写 .sha256（phase1/build.sh 负责）'
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
# 镜像文件模式最先分流：--image 与 --disk/--grub-dir/--trial 互斥，校验在写任何字节之前
if [ -n "$IMAGE" ] || [ -n "$IMAGE_SIZE" ]; then
	image_validate
	if [ "$DRY_RUN" = 1 ]; then
		print_image_plan
		exit 0
	fi
	require_image_inputs
	check_rootfs_baseline
	image_check_platform
	image_check_tools
	image_write
	exit 0
fi

if [ -n "$PRESERVE" ] && [ -z "$GRUB_DIR" ]; then
	usage_fail "--preserve-existing 必须与 --grub-dir DIR 一起用（它只渲染 grub.cfg，不装机）"
fi
if [ -n "$PRESERVE" ] && [ "$DRY_RUN" = 1 ]; then
	usage_fail "--preserve-existing 与 --dry-run 互斥"
fi

if [ -n "$GRUB_DIR" ]; then
	[ "$DRY_RUN" = 0 ] || usage_fail "--grub-dir 与 --dry-run 互斥"
	if [ -n "$PRESERVE" ]; then
		render_cfg_preserve "$GRUB_DIR"
	else
		render_cfg "$GRUB_DIR"
	fi
	exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
	print_plan
	exit 0
fi

# ---- 真装机：分层校验 → 手工 yes → 破坏性动作 ----
require_inputs
check_rootfs_baseline
check_tools
mkdir -p "$BOOT_MNT" "$DATA_MNT" 2>/dev/null || true
preflight_inspect
say ''
say '--- 即将执行（全部集中在 destructive_install 里）---'
say '  sgdisk --zap-all（重建分区表）+ mkfs.vfat p1 + mkfs.btrfs p2'
say "  mkfs.btrfs -L $BTRFS_LABEL + btrfs subvolume create $SUBVOLS"
say "  解包 $ROOTFS -> @root（排除挂载点）+ 写 /.ab-base-manifest"
say "  grub-install + 渲染 grub.cfg（0 号项 cmdline: ${CMDLINE}）"
confirm_yes
destructive_install
exit 0
