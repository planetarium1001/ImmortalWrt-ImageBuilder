#!/bin/sh
# =============================================================================
# phase1/build.sh —— Phase 1 镜像构建的**单一入口**（CI 与本机都只调它）
#
# 分工（别把职责挪来挪去）：
#   本脚本            解包 rootfs → 注入 firstboot(+dev) → 组 initrd 的 STAGE 载荷
#                     → make-initramfs.sh → assemble-image.sh --image 出**未压缩** .img
#                     → gzip -9 -n 压成 .img.gz → 打印 sha256 与大小
#   assemble-image.sh 分区表 / 子卷 / 解包 / grub / loop 挂载（--image 模式）
#
# dev 与 prod 的差异**只在注入层**，全部静态可判定，判据是"镜像里有没有"：
#   prod = firstboot 注入（首启扩容）
#   dev  = firstboot 注入 + phase1/dev/rootfs 注入：
#          /etc/DEV-IMAGE（标记）+ etc/uci-defaults/90-dev-image（首启 + hostname -dev）
#          + **构建期就把 firewall 规则 dev-open-wan append 进 /etc/config/firewall**
#            （只在首启脚本里写等于"镜像里没有"，ac-4 的判据会落空；脚本保留作兜底，判重后自动跳过）
#   --type 必填且只认 dev|prod：不设默认值，避免"误把 dev 当正式版发出去 / 反之"。
#
# 用法：sh phase1/build.sh --help
# =============================================================================
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "${SCRIPT_DIR}/.." && pwd)
PROG=phase1/build.sh
MK=${SCRIPT_DIR}/make-initramfs.sh
AS=${SCRIPT_DIR}/assemble-image.sh
DEV_TREE=${SCRIPT_DIR}/dev/rootfs
FB_TREE=${SCRIPT_DIR}/firstboot/rootfs
# dev 的 firewall 规则段（构建期 append 进 /etc/config/firewall，不是整份替换上游配置）
DEV_RULE_SRC=${DEV_TREE}/etc/config/firewall.dev-rule

# initrd 里烘焙的设备名：镜像以整盘 dd 交付，设备名由**内核**按盘型决定。
# 本任务的交付介质是 NVMe（dd 到 /dev/nvme0n1），所以默认 nvme0n1pN；
# 换 SATA/USB 盘时用 --rootdev/--bootdev 覆盖，别改默认值（改了等于写死另一种盘型）。
ROOTDEV_DEF=/dev/nvme0n1p2
BOOTDEV_DEF=/dev/nvme0n1p1

# initrd 必需载荷（名字必须与 phase1/make-initramfs.sh 的 STAGE 校验逐字一致）
MODS_BTRFS='xxhash zstd_common zstd_compress zstd_decompress raid6_pq lzo_compress lzo_decompress xor libcrc32c btrfs'
MODS_FS_VFAT='vfat fat'
MODS_NLS_CP437='nls_cp437'
MODS_NLS_ISO8859='nls_iso8859-1'
MODS_NLS_UTF8='nls_utf8'

# ---- 默认值 ---------------------------------------------------------------
TYPE=''
ROOTFS=''
KERNEL=''
IMAGE_OUT=''
SIZE=8G
# 不写死内核版本：--kver 不给时从 rootfs 的 lib/modules/ 自动探测（CI 里 ImageBuilder
# 的内核版本随上游变，写死会在"找不到 kmod"上浪费一整轮 CI）
KVER=''
KVER_FALLBACK=6.12.103
INITRD_OUT=''
WORK=''
BTRFS_LABEL=phase1
WITH_DATA_SUBVOL=0
PREPARE=''
DRY_RUN=0
ROOTDEV=${ROOTDEV_DEF}
BOOTDEV=${BOOTDEV_DEF}
BOOTSUB=boot
LOWER=@root
OVL=@overlay

BUILD_TIME=${BUILD_TIME:-}
GIT_SHA=${GIT_SHA:-}
MISSING=''
WORK_OWNED=0

# ---------------------------------------------------------------------------
# 输出与退出
# ---------------------------------------------------------------------------
step() { printf '\n=== %s ===\n' "$*"; }
say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

usage_fail() { # <原因>
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf '  用法: sh phase1/build.sh --help\n' >&2
	exit 2
}

die() { # <原因> [下一步]
	printf '%s: %s\n' "$PROG" "$1" >&2
	if [ "$#" -ge 2 ]; then
		printf '  下一步: %s\n' "$2" >&2
	fi
	exit 1
}

usage() {
	cat <<'EOF'
phase1/build.sh —— Phase 1 镜像构建单一入口（POSIX sh）

必需：
  --type dev|prod               构建类型（必填，没有默认值：dev 会放行 WAN 全端口）
  --rootfs FILE|DIR             上游 rootfs（rootfs.tar.gz 或已解开的目录；目录会被复制，不就地改）
  --kernel FILE                 内核（vmlinuz，原样拷进镜像的 /boot）
  --image-out FILE              产物路径（.img.gz；gzip -9 -n 压缩）
  --size 8G                     镜像总大小（传给 assemble-image.sh --size；压 gzip 前会
                                校验产物字节数恰好等于它，半成品镜像直接拒绝）

可选：
  --kver 6.12.103               initrd 里的模块目录名（默认从 rootfs 的 lib/modules/ 自动探测）
  --initrd-out FILE             initrd 产物（默认 <work>/initrd.cpio.gz）
  --work DIR                    临时目录（默认 mktemp -d；给了就不删）
  --btrfs-label phase1          p2 的 btrfs 标签（透传 assemble-image.sh）
  --with-data-subvol            额外建 @data 子卷（透传；HEAD 时代基座才需要）
  --rootdev /dev/nvme0n1p2      initrd 烘焙的根分区（默认 nvme0n1p2）
  --bootdev /dev/nvme0n1p1      initrd 烘焙的引导分区（默认 nvme0n1p1）
  --bootsub boot                p1 内的引导目录（initrd --bootsub）
  --lower @root                 ro lower 子卷名（initrd --lower）
  --overlay @overlay            写层子卷名（initrd --overlay）
  --prepare-rootfs DIR          **只**做"解包 → 注入（含 dev 的 firewall 规则）→ 写到 DIR"，
                                不碰 loop/分区/grub，然后退出 0
  --dry-run                     只打印将执行的完整 argv（含 STAGE 清单、大小闸期望字节数），不写盘
                                （例外：为了打印 INIT_SHA，会在 TMPDIR 里临时渲染一份 /init 后删除）

环境变量（可选）：
  BUILD_TIME / GIT_SHA          渲染 /etc/DEV-IMAGE 用的构建时间与提交号
                                （不给就取当前 UTC 时间 / git rev-parse；CI 可显式给以复现）

退出码：0 成功；1 流水线失败（已打印"下一步"）；2 用法错误。
EOF
}

# ---------------------------------------------------------------------------
# 执行原语：打印与执行**同一份** argv
#   --dry-run 打印出来的就是真跑时要 exec 的那条命令（不是另写一份"计划文本"），
#   所以"打印的 argv 与实际调用一致"是结构上保证的，不靠人肉同步。
# ---------------------------------------------------------------------------
show_cmd() { printf '  $'; for _a in "$@"; do printf ' %s' "$_a"; done; }

run() {
	show_cmd "$@"
	printf '\n'
	if [ "${DRY_RUN}" = 1 ]; then
		return 0
	fi
	"$@"
}

# --size 换算成字节（支持 8G / 8192M / 512K / 裸字节）。压 gzip 前要用它做"镜像是不是满尺寸"的闸。
size_to_bytes() { # <8G|8192M|512K|N>：输出字节数，解析不了返回 1
	_v=$1
	case ${_v} in
	*[Gg]) _n=${_v%?} _mul=1073741824 ;;
	*[Mm]) _n=${_v%?} _mul=1048576 ;;
	*[Kk]) _n=${_v%?} _mul=1024 ;;
	*) _n=${_v} _mul=1 ;;
	esac
	_n=$(printf '%s' "${_n}" | sed 's/^0*//')
	[ -n "${_n}" ] || _n=0
	case ${_n} in
	*[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$((_n * _mul))"
}

# 带重定向的两步（sed 渲染 / gzip 输出）不能走 run()：打印行里要带 "> 目标"。
render_template() { # <模板> <目标>
	_tpl=$1
	_out=$2
	set -- sed -e "s|@TYPE@|${TYPE}|g" \
		-e "s|@BUILD_TIME@|${BUILD_TIME}|g" \
		-e "s|@GIT_SHA@|${GIT_SHA}|g" "$_tpl"
	show_cmd "$@"
	printf ' > %s\n' "$_out"
	if [ "${DRY_RUN}" = 1 ]; then
		return 0
	fi
	"$@" >"$_out" || die "渲染模板失败: ${_tpl} -> ${_out}" "确认目标目录可写、模板里没有写错的占位符"
	chmod 644 "$_out" || die "chmod 644 ${_out} 失败" "确认 rootfs tree 可写"
}

gzip_image() { # <未压缩 img> <输出 .img.gz>
	show_cmd gzip -9 -n -c "$1"
	printf ' > %s\n' "$2"
	if [ "${DRY_RUN}" = 1 ]; then
		return 0
	fi
	[ -s "$1" ] || die "assemble-image.sh 没有产出镜像（或产物为空）: ${1}" \
		"看上面 assemble-image.sh 的日志：确认 --size 够大、loop 设备可用、rootfs 没解包失败"
	gzip -9 -n -c "$1" >"$2" || die "gzip 失败: ${1} -> ${2}" "确认目标目录可写、磁盘空间够"
	[ -s "$2" ] || die "gzip 产物为空: ${2}" "确认 gzip 可用、磁盘没满"
}

# 第二道闸（audit A4）：镜像实际字节数必须等于 --size。
# 不等 ⇒ assemble-image.sh 提前返回/truncate 没生效 ⇒ 那是一块**半成品**的盘，
# 压成 .img.gz 会被当成"构建成功"，刷上去分区表或文件系统就是残的。所以宁可不产出。
check_img_full_size() { # <未压缩 img>
	_want=$(size_to_bytes "${SIZE}") || die "--size 解析不了: ${SIZE}" \
		"只支持 整数 + K/M/G 后缀（例如 8G / 8192M）"
	if [ "${DRY_RUN}" = 1 ]; then
		say "  # 大小闸: --size ${SIZE} => ${_want} bytes（压 gzip 前会与实际字节数逐一比对）"
		return 0
	fi
	_got=$(wc -c <"$1" | tr -d ' ')
	case ${_got} in
	'' | *[!0-9]*) die "读不出镜像大小: $1" "确认文件存在且可读" ;;
	esac
	[ "${_got}" = "${_want}" ] || die \
		"镜像实际大小 ${_got} bytes ≠ --size ${SIZE}（${_want} bytes）：这是半成品镜像，拒绝压成 .img.gz" \
		"看 assemble-image.sh 的日志（truncate/losetup/解包是否半路返回）；产物大小不对就不是成功构建"
	say "  大小闸: $(basename "$1") = ${_got} bytes = --size ${SIZE}"
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

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
need_val() { # <选项名> <剩余参数个数>
	[ "${2}" -ge 2 ] || usage_fail "选项 ${1} 缺少值"
}

while [ "$#" -gt 0 ]; do
	case $1 in
	--help | -h)
		usage
		exit 0
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--with-data-subvol)
		WITH_DATA_SUBVOL=1
		shift
		;;
	--*=*)
		_k=${1#--}
		_v=${_k#*=}
		_k=${_k%%=*}
		case ${_k} in
		type) TYPE=${_v} ;;
		rootfs) ROOTFS=${_v} ;;
		kernel) KERNEL=${_v} ;;
		image-out) IMAGE_OUT=${_v} ;;
		size) SIZE=${_v} ;;
		kver) KVER=${_v} ;;
		initrd-out) INITRD_OUT=${_v} ;;
		work) WORK=${_v} ;;
		btrfs-label) BTRFS_LABEL=${_v} ;;
		rootdev) ROOTDEV=${_v} ;;
		bootdev) BOOTDEV=${_v} ;;
		bootsub) BOOTSUB=${_v} ;;
		lower) LOWER=${_v} ;;
		overlay) OVL=${_v} ;;
		prepare-rootfs) PREPARE=${_v} ;;
		*) usage_fail "未知选项: --${_k}（--help 看用法）" ;;
		esac
		shift
		;;
	--type)
		need_val --type "$#"
		TYPE=$2
		shift 2
		;;
	--rootfs)
		need_val --rootfs "$#"
		ROOTFS=$2
		shift 2
		;;
	--kernel)
		need_val --kernel "$#"
		KERNEL=$2
		shift 2
		;;
	--image-out)
		need_val --image-out "$#"
		IMAGE_OUT=$2
		shift 2
		;;
	--size)
		need_val --size "$#"
		SIZE=$2
		shift 2
		;;
	--kver)
		need_val --kver "$#"
		KVER=$2
		shift 2
		;;
	--initrd-out)
		need_val --initrd-out "$#"
		INITRD_OUT=$2
		shift 2
		;;
	--work)
		need_val --work "$#"
		WORK=$2
		shift 2
		;;
	--btrfs-label)
		need_val --btrfs-label "$#"
		BTRFS_LABEL=$2
		shift 2
		;;
	--rootdev)
		need_val --rootdev "$#"
		ROOTDEV=$2
		shift 2
		;;
	--bootdev)
		need_val --bootdev "$#"
		BOOTDEV=$2
		shift 2
		;;
	--bootsub)
		need_val --bootsub "$#"
		BOOTSUB=$2
		shift 2
		;;
	--lower)
		need_val --lower "$#"
		LOWER=$2
		shift 2
		;;
	--overlay)
		need_val --overlay "$#"
		OVL=$2
		shift 2
		;;
	--prepare-rootfs)
		need_val --prepare-rootfs "$#"
		PREPARE=$2
		shift 2
		;;
	*)
		usage_fail "未知选项: ${1}（--help 看用法）"
		;;
	esac
done

[ -n "${TYPE}" ] || usage_fail "必须显式给 --type dev|prod（不设默认值：dev/prod 的差异是安全边界）"
case ${TYPE} in
dev | prod) ;;
*) usage_fail "--type 只接受 dev|prod（给的是: ${TYPE}）" ;;
esac
[ -n "${ROOTFS}" ] || usage_fail "缺 --rootfs <tar.gz|dir>"

if [ -f "${ROOTFS}" ]; then
	say "rootfs: ${ROOTFS}（tar 归档）"
elif [ -d "${ROOTFS}" ]; then
	say "rootfs: ${ROOTFS}（目录，会复制一份再改）"
else
	die "rootfs 不存在: ${ROOTFS}" "给 ImageBuilder 产出的 rootfs.tar.gz，或已解开的 rootfs 目录"
fi

# ---------------------------------------------------------------------------
# 构建时间 / 提交号（只用于渲染 /etc/DEV-IMAGE，dev 才注入）
# ---------------------------------------------------------------------------
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown'; }
if [ -z "${BUILD_TIME}" ]; then
	BUILD_TIME=$(now_utc)
fi
if [ -z "${GIT_SHA}" ]; then
	GIT_SHA=$(cd "${REPO}" && git rev-parse --short HEAD 2>/dev/null) || GIT_SHA=''
	[ -n "${GIT_SHA}" ] || GIT_SHA=unknown
fi

# ---------------------------------------------------------------------------
# 工作目录与清理
# ---------------------------------------------------------------------------
cleanup() {
	# 只删自己 mktemp 出来的临时目录：--work 是用户给的，一个字都不删。
	# 挂载点与 loop 设备由 assemble-image.sh 自己的 trap 负责（本脚本不 mount、不 losetup）。
	if [ "${WORK_OWNED}" = 1 ] && [ -n "${WORK}" ]; then
		rm -rf "${WORK}"
	fi
	return 0
}

setup_work() {
	if [ -n "${WORK}" ]; then
		_work_in=${WORK}
		mkdir -p "${_work_in}" || die "无法创建 --work 目录: ${_work_in}" "确认父目录存在且可写"
		# 先规范化成真实绝对路径，再做护栏：`--work /tmp/..` 规范化后是 `/`，后面
		# `rm -rf "$WORK/rootfs"` 就成了删 `/rootfs`。规范化放在 rm 之前，这类输入才拦得住。
		WORK=$(cd "${_work_in}" && pwd -P) || die "--work 无法规范化: ${_work_in}" "确认目录存在且可进入"
		# 两道护栏：
		#   a) 规范化的结果不许是系统目录本身（macOS 的 /tmp 会被解析成 /private/tmp，所以两边都列）
		#   b) 至少两级（/a/b）：一级目录一律拒绝 —— `--work /x` 拼上 /rootfs 就是危险的删除目标
		_why=''
		case ${WORK} in
		/ | // | /home | /tmp | /mnt | /usr | /var | /etc | /root | /opt | /srv | /boot | \
			/dev | /proc | /sys | /bin | /sbin | /lib | /lib64 | /run | /private | \
			/private/tmp | /private/var | /private/etc | /private/home)
			_why='这是系统目录本身'
			;;
		esac
		if [ -z "${_why}" ]; then
			case ${WORK#/} in
			*/*) ;;
			*) _why='路径太浅（至少两级，例如 /tmp/phase1-build）' ;;
			esac
		fi
		if [ -n "${_why}" ]; then
			die "拒绝 --work: ${WORK}（${_why}）
    rm -rf 会把 <work>/rootfs 落到系统目录上，可能删掉别人的目录" \
				"给一个专用子目录，例如 /var/tmp/phase1-build"
		fi
		WORK_OWNED=0
	else
		WORK=$(mktemp -d "${TMPDIR:-/tmp}/phase1-build.XXXXXX") || die "mktemp -d 失败" "确认 TMPDIR 可写，或用 --work DIR"
		WORK=$(cd "${WORK}" && pwd -P) || die "mktemp 目录无法规范化: ${WORK}" "确认 TMPDIR 可进入"
		WORK_OWNED=1
	fi
	trap cleanup EXIT INT TERM
	ROOTFS_TREE=${WORK}/rootfs
	STAGE_DIR=${WORK}/stage
	clean_work_subdirs
}

clean_work_subdirs() {
	# rm -rf 只允许作用于 <WORK>/rootfs 与 <WORK>/stage；删之前再断言一次字面前缀，
	# 这样即使哪天有人改了路径拼法，也不会在 --work 上误删别的东西。
	for _p in "${ROOTFS_TREE}" "${STAGE_DIR}"; do
		case ${_p} in
		"${WORK}/rootfs" | "${WORK}/stage") ;;
		*) die "拒绝删除非工作子目录: ${_p}" "这是 build.sh 的 bug，报给 Lead（--work=${WORK}）" ;;
		esac
		if [ -e "${_p}" ] || [ -L "${_p}" ]; then
			# --work 可复用（CI 缓存）⇒ 先清掉上一次的两棵子树，避免上一次注入的文件残留
			# （典型事故：上一次 dev、这一次 prod ⇒ prod 的 rootfs 里冒出 /etc/DEV-IMAGE）
			rm -rf "${_p}" || die "无法清理 ${_p}" "换一个 --work 目录"
		fi
	done
}

# ---------------------------------------------------------------------------
# 1. 准备 rootfs tree（排除清单与 phase1/assemble-image.sh 的 extract_rootfs 逐项一致）
# ---------------------------------------------------------------------------
extract_tree() { # <源 tar.gz|目录> <目标目录>
	_src=$1
	_dst=$2
	# 这些目录在基座里必须是空挂载点：绝不能把宿主内容拷进镜像（与 extract_rootfs 同源）
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
	if [ "${DRY_RUN}" = 0 ]; then
		mkdir -p "$_dst" || die "无法创建 ${_dst}" "确认目标可写"
	fi
	if [ -d "$_src" ]; then
		# 目录源：两段式（先落临时 tar 并判 rc，再解）。不用 `tar -c … | tar -x …`：
		# POSIX sh 没有 pipefail，源侧失败会被解包侧的 0 吞掉，结果是一台半残基座。
		_tmp=${WORK}/.rootfs-tree.tar
		run tar -cf "$_tmp" "$@" -C "$_src" . ||
			die "归档 rootfs 目录失败: ${_src}" "确认目录可读；目标盘空间够（目录大小 + 同尺寸临时 tar）"
		run tar -xpf "$_tmp" -C "$_dst" ||
			die "解包 rootfs 归档失败: ${_tmp} -> ${_dst}" "确认目标可写、空间够"
		if [ "${DRY_RUN}" = 0 ]; then
			rm -f "$_tmp"
		fi
	else
		run tar -xpf "$_src" "$@" -C "$_dst" ||
			die "解包失败: ${_src} -> ${_dst}" "确认它是未损坏的 rootfs.tar.gz（tar -tzf 自检）"
	fi
}

# ---------------------------------------------------------------------------
# 2. 注入（firstboot 两类型都注入；dev 再叠 dev/rootfs）
# ---------------------------------------------------------------------------
list_tree() { # <目录>：输出相对路径清单（本仓库里的注入文件名不含空格）
	(cd "$1" && find . ! -type d -print | sed 's|^\./||' | LC_ALL=C sort)
}

inject_one() { # <覆盖树> <目标 rootfs> <相对路径>；真的写了目标文件才返回 0
	_src=$1
	_dst=$2
	_rel=$3
	_from=${_src}/${_rel}
	_to=${_dst}/${_rel}
	if [ "${DRY_RUN}" = 0 ]; then
		mkdir -p "${_dst}/$(dirname "${_rel}")" || die "无法创建 ${_dst}/$(dirname "${_rel}")" "确认目标可写"
	fi
	case ${_rel} in
	*.in)
		# *.in 是模板：渲染成去掉 .in 的目标文件，模板本身**不进**镜像
		printf '  注入 %s（由 %s 渲染）\n' "${_rel%.in}" "${_rel}"
		render_template "${_from}" "${_to%.in}"
		;;
	*.dev-rule)
		# 配置片段：不能当成 /etc/config/firewall.dev-rule 塞进镜像（那是另一个 uci 包），
		# 只能由 inject_dev_firewall 追加进 /etc/config/firewall
		printf '  片段 %s（不直接拷入：由 build.sh 追加到 etc/config/firewall）\n' "${_rel}"
		return 1
		;;
	*)
		_note=新增
		if [ -e "${_to}" ] || [ -L "${_to}" ]; then
			_note=覆盖
		fi
		printf '  注入 %s（%s）\n' "${_rel}" "${_note}"
		run cp -a "${_from}" "${_to}"
		;;
	esac
	return 0
}

inject_tree() { # <覆盖树> <目标 rootfs> <标签>
	_src=$1
	_dst=$2
	_label=$3
	[ -d "$_src" ] || die "缺少注入树: ${_src}" "确认仓库里 phase1/${_label}/rootfs 没被删"
	_n=0
	for _rel in $(list_tree "$_src"); do
		if inject_one "$_src" "$_dst" "$_rel"; then
			_n=$((_n + 1))
		fi
	done
	say "  ${_label}: 写入 ${_n} 个文件"
}

check_inject_conflict() { # 同一路径被两处写且内容不同 ⇒ 点名报错
	if [ ! -d "${DEV_TREE}" ] || [ ! -d "${FB_TREE}" ]; then
		return 0
	fi
	if [ "${DRY_RUN}" = 1 ]; then
		say '  （--dry-run：不比对两处注入的冲突）'
		return 0
	fi
	for _rel in $(list_tree "${DEV_TREE}"); do
		[ -f "${FB_TREE}/${_rel}" ] || continue
		cmp -s "${DEV_TREE}/${_rel}" "${FB_TREE}/${_rel}" || die \
			"注入冲突: ${_rel} 在 phase1/dev/rootfs 与 phase1/firstboot/rootfs 里内容不同" \
			"同一个路径只允许一处定义（删掉其中一份，或让两份内容一致）"
	done
}

# dev 的 WAN 全放行必须**在镜像里**就生效：ac-4 的判据是"镜像里有没有这条规则"，
# 只写在首启 uci-defaults 里等于镜像里没有（首启没跑到就没有规则）。
# 所以构建期把规则段 append 进 /etc/config/firewall；90-dev-image 保留作兜底，
# 它按 name 判重，构建期已写入就自动跳过（幂等，不会叠两条）。
inject_dev_firewall() { # <目标 rootfs tree>
	_dst=$1
	[ "${TYPE}" = dev ] || return 0
	_fw=${_dst}/etc/config/firewall
	[ -f "${DEV_RULE_SRC}" ] || die "缺 dev firewall 规则片段: ${DEV_RULE_SRC}" \
		"确认 phase1/dev/rootfs/etc/config/firewall.dev-rule 在仓库里"
	if [ "${DRY_RUN}" = 1 ]; then
		printf '  $ cat %s >> %s\n' "${DEV_RULE_SRC}" "${_fw}"
		printf '  注入 firewall 规则 dev-open-wan（src=wan proto=all target=ACCEPT）\n'
		return 0
	fi
	if [ ! -f "${_fw}" ]; then
		die "dev 注入后找不到 ${_fw}" \
			"rootfs 里没解出 firewall 包（/etc/config/firewall 不存在）：确认 ImageBuilder 的 PACKAGES 含 firewall4 且 rootfs 解包没失败"
	fi
	if grep -q 'dev-open-wan' "${_fw}" 2>/dev/null; then
		say '  注入 firewall 规则 dev-open-wan：已存在，跳过（幂等）'
		return 0
	fi
	# 上游 firewall 末尾没有换行时直接 cat 会粘成一行（UCI 解析直接坏掉）⇒ 先补换行
	if [ -n "$(tail -c 1 "${_fw}" 2>/dev/null)" ]; then
		printf '\n' >>"${_fw}" || die "写 ${_fw} 失败" "确认 rootfs tree 可写"
	fi
	cat "${DEV_RULE_SRC}" >>"${_fw}" || die "追加规则到 ${_fw} 失败" "确认 rootfs tree 可写"
	printf '  注入 firewall 规则 dev-open-wan（src=wan proto=all target=ACCEPT）\n'
}

assert_prod_clean() { # <rootfs tree>：prod 里不许出现任何 dev 痕迹
	_dst=$1
	[ "${TYPE}" = prod ] || return 0
	[ "${DRY_RUN}" = 0 ] || return 0
	for _f in etc/DEV-IMAGE etc/uci-defaults/90-dev-image; do
		[ ! -e "${_dst}/${_f}" ] || die "prod 镜像里出现了 dev 专有文件: ${_f}" \
			"检查 phase1/firstboot/rootfs 有没有误放 dev 内容"
	done
	_hit=$(grep -rl 'dev-open-wan' "${_dst}" 2>/dev/null | sed "s#^${_dst}##" | head -3 | tr '\n' ' ')
	[ -z "${_hit}" ] || die "prod 镜像里出现了 dev-open-wan 规则: ${_hit}" \
		"确认 build.sh 的 inject_dev_firewall 只在 --type dev 下执行"
}

prepare_and_inject() { # <目标 rootfs tree>：解包 + 注入 + dev 规则；两类型共用一份实现
	_dst=$1
	extract_tree "${ROOTFS}" "${_dst}"
	inject_tree "${FB_TREE}" "${_dst}" firstboot
	if [ "${TYPE}" = dev ]; then
		inject_tree "${DEV_TREE}" "${_dst}" dev
	fi
	check_inject_conflict
	inject_dev_firewall "${_dst}"
	assert_prod_clean "${_dst}"
}

# ---------------------------------------------------------------------------
# 3. 组 STAGE（initrd 载荷）；缺任何一项就点名到包并失败（不静默跳过）
# ---------------------------------------------------------------------------
missing_add() { # <包名> <路径>
	MISSING="${MISSING}${MISSING:+; }${2}（需要包 ${1}）"
}

stage_fail() {
	die "STAGE 缺少 initrd 必需载荷，拒绝继续（不做半残 initrd）:
    ${MISSING}
    下一步: 在 ImageBuilder 的 PACKAGES 里加上面点名的包后重跑
      kmod-fs-btrfs（含 xxhash/zstd/raid6/lzo/xor/libcrc32c 依赖）
      kmod-fs-vfat / kmod-nls-cp437 / kmod-nls-iso8859-1 / kmod-nls-utf8
      attr（usr/bin/{getfattr,setfattr}）/ libgcc / libubox / busybox / kmodloader" \
		"确认 rootfs 里有 /lib/modules/${KVER}/、/bin/busybox、/sbin/kmodloader"
}

stage_plan() { # <包名> <目标相对路径> <源>
	printf '  STAGE %s <- %s（包: %s）\n' "$2" "$3" "$1"
}

first_existing() { # <相对路径...>：输出第一个存在的绝对路径
	for _c in "$@"; do
		if [ -e "${ROOTFS_TREE}/${_c}" ] || [ -L "${ROOTFS_TREE}/${_c}" ]; then
			printf '%s\n' "${ROOTFS_TREE}/${_c}"
			return 0
		fi
	done
	return 1
}

stage_copy() { # <源绝对路径> <目标相对路径>
	mkdir -p "${STAGE_DIR}/$(dirname "$2")" || die "无法创建 ${STAGE_DIR}/$(dirname "$2")" "确认 WORK 可写"
	cp -a "$1" "${STAGE_DIR}/$2" || die "拷贝 STAGE 项失败: $1 -> ${STAGE_DIR}/$2" "确认源文件可读、空间够"
	printf '  STAGE %s <- %s\n' "$2" "${1#"${ROOTFS_TREE}/"}"
}

stage_take() { # <包名> <目标相对路径> <源相对路径候选...>
	_pkg=$1
	_dstrel=$2
	shift 2
	if [ "${DRY_RUN}" = 1 ]; then
		stage_plan "${_pkg}" "${_dstrel}" "${ROOTFS_TREE}/${1}"
		return 0
	fi
	if ! _srcp=$(first_existing "$@"); then
		missing_add "${_pkg}" "${_dstrel}"
		return 0
	fi
	stage_copy "${_srcp}" "${_dstrel}"
}

stage_glob() { # <包名> <目标相对路径> <源目录（空格分隔）> <模式>
	# 用于 libattr*（可有可无）
	_pkg=$1
	_dstrel=$2
	_dirs=$3
	_pat=$4
	if [ "${DRY_RUN}" = 1 ]; then
		_d1=${_dirs%% *}
		stage_plan "${_pkg}" "${_dstrel}" "${ROOTFS_TREE}/${_d1}/${_pat}"
		return 0
	fi
	_found=''
	for _d in ${_dirs}; do
		for _f in "${ROOTFS_TREE}/${_d}"/${_pat}; do
			if [ -e "${_f}" ] || [ -L "${_f}" ]; then
				_found=$_f
				break
			fi
		done
		if [ -n "${_found}" ]; then
			break
		fi
	done
	if [ -z "${_found}" ]; then
		missing_add "${_pkg}" "${_dstrel}"
		return 0
	fi
	stage_copy "${_found}" "${_dstrel}"
}

stage_libubox() {
	# libubox 的文件名带版本日期（libubox.so.<日期>），**这个名字就是 kmodloader 的
	# DT_NEEDED（soname）**：改名 ⇒ initrd 里动态链接器找不到库 ⇒ kmodloader 起不来
	# ⇒ 模块加载不了、/init 直接死。所以必须**原样保留 rootfs 里的那个文件名**。
	# make-initramfs.sh 侧也按 glob `lib/libubox.so.*` 认，两边约定一致。
	if [ "${DRY_RUN}" = 1 ]; then
		stage_plan libubox 'lib/libubox.so.<版本>（原名）' "${ROOTFS_TREE}/lib/libubox.so.*"
		return 0
	fi
	_names=''
	for _d in lib usr/lib; do
		for _f in "${ROOTFS_TREE}/${_d}"/libubox.so.*; do
			if [ ! -e "${_f}" ] && [ ! -L "${_f}" ]; then
				continue
			fi
			# 同名只算一次（/lib → usr/lib 是同一个文件时不该报"两个版本"）
			case " ${_names} " in
			*" ${_f##*/} "*) ;;
			*) _names="${_names}${_names:+ }${_f##*/}" ;;
			esac
		done
	done
	if [ -z "${_names}" ]; then
		missing_add libubox 'lib/libubox.so.*'
		return 0
	fi
	case ${_names} in
	*' '*) die "rootfs 里有多个 libubox 版本（${_names}）：无法判断该带哪个" \
		"典型原因：/lib 与 /usr/lib 各留了一份不同版本。清掉旧版本（只留 kmodloader 真正 DT_NEEDED 的那个）后重跑" ;;
	esac
	if ! _srcp=$(first_existing "lib/${_names}" "usr/lib/${_names}"); then
		missing_add libubox "lib/${_names}"
		return 0
	fi
	stage_copy "${_srcp}" "lib/${_names}"
}

stage_optional() { # <目标相对路径> <源相对路径候选...>：缺失只 warn（不进 MISSING）
	_dstrel=$1
	shift
	if [ "${DRY_RUN}" = 1 ]; then
		stage_plan '(可选)' "${_dstrel}" "${ROOTFS_TREE}/$1"
		return 0
	fi
	if ! _srcp=$(first_existing "$@"); then
		warn "STAGE 没有 ${_dstrel}（可选文件：裁剪过的 rootfs 常把它剥掉，make-initramfs.sh 也只 WARN，不拦）"
		return 0
	fi
	stage_copy "${_srcp}" "${_dstrel}"
}

stage_link_optional() { # <目标相对路径> <源相对路径>（kmodloader 的 applet 软链：make-initramfs 会自建，缺了不算错）
	if [ "${DRY_RUN}" = 1 ]; then
		stage_plan kmodloader "$1" "${ROOTFS_TREE}/$2"
		return 0
	fi
	if [ -e "${ROOTFS_TREE}/$2" ] || [ -L "${ROOTFS_TREE}/$2" ]; then
		stage_copy "${ROOTFS_TREE}/$2" "$1"
	else
		printf '  STAGE %s：rootfs 里没有（make-initramfs.sh 会按 kmodloader 自建软链）\n' "$1"
	fi
}

stage_module() { # <包名> <模块名>
	_pkg=$1
	_mod=$2
	_dstrel="lib/modules/${KVER}/${_mod}.ko"
	if [ "${DRY_RUN}" = 1 ]; then
		stage_plan "${_pkg}" "${_dstrel}" "${ROOTFS_TREE}/${_dstrel}"
		return 0
	fi
	_srcp=''
	if [ -f "${ROOTFS_TREE}/${_dstrel}" ]; then
		_srcp=${ROOTFS_TREE}/${_dstrel}
	elif [ -d "${ROOTFS_TREE}/lib/modules/${KVER}" ]; then
		# OpenWrt 的模块目录是平铺的，但别假设（子目录也认）
		_srcp=$(find "${ROOTFS_TREE}/lib/modules/${KVER}" -name "${_mod}.ko" -type f 2>/dev/null | head -1) || _srcp=''
	fi
	if [ -z "${_srcp}" ]; then
		missing_add "${_pkg}" "${_dstrel}"
		# 顺便点出"压缩模块"这个坑：make-initramfs.sh 只认未压缩 .ko
		_c=$(find "${ROOTFS_TREE}/lib/modules/${KVER}" -name "${_mod}.ko.*" -type f 2>/dev/null | head -1) || _c=''
		if [ -n "${_c}" ]; then
			printf '  ! %s 在 rootfs 里是压缩模块（%s）：make-initramfs.sh 只接受未压缩 .ko\n' \
				"${_dstrel}" "${_c#"${ROOTFS_TREE}/"}" >&2
		fi
		return 0
	fi
	stage_copy "${_srcp}" "${_dstrel}"
}

detect_kver() { # --kver 没给时，从 rootfs 的 lib/modules/ 探测（必须在 build_stage 之前调）
	if [ -n "${KVER}" ]; then
		say "  kver: ${KVER}（--kver 指定）"
		return 0
	fi
	_pick=''
	_count=0
	for _d in "${ROOTFS_TREE}/lib/modules"/*; do
		if [ -d "${_d}" ]; then
			_pick=${_d##*/}
			_count=$((_count + 1))
		fi
	done
	if [ "${_count}" = 0 ]; then
		KVER=${KVER_FALLBACK}
		warn "rootfs 里没有 lib/modules/，退回默认 kver=${KVER}（initrd 大概率组不出来，原因会在 STAGE 检查里点名）"
		return 0
	fi
	if [ "${_count}" -gt 1 ]; then
		die "rootfs 的 lib/modules/ 下有 ${_count} 个内核目录（${_pick} 等）：无法判断该用哪个" \
			"用 --kver <版本> 显式指定（版本 = rootfs 里 lib/modules/ 的目录名）"
	fi
	KVER=${_pick}
	say "  kver: ${KVER}（从 rootfs 的 lib/modules/ 自动探测；要覆盖请给 --kver）"
}

build_stage() {
	MISSING=''
	# --dry-run 不读真 rootfs（ROOTFS_TREE 只是占位），所以 KVER 可能还是空：用默认值打印
	[ -n "${KVER}" ] || KVER=${KVER_FALLBACK}
	# 目录布局必须与 make-initramfs.sh 的 STAGE 校验逐字一致（它按这些名字找文件）
	stage_take busybox bin/busybox bin/busybox
	stage_take libc lib/ld-musl-x86_64.so.1 lib/ld-musl-x86_64.so.1 usr/lib/ld-musl-x86_64.so.1
	stage_take libc lib/libc.so lib/libc.so usr/lib/libc.so
	# 名字不能改：见 stage_libubox 的注释（soname = 文件名）
	stage_libubox
	stage_take libgcc lib/libgcc_s.so.1 lib/libgcc_s.so.1 usr/lib/libgcc_s.so.1
	stage_take kmodloader sbin/kmodloader sbin/kmodloader
	for _a in modprobe insmod rmmod lsmod; do
		stage_link_optional "sbin/${_a}" "sbin/${_a}"
	done
	for _m in ${MODS_BTRFS}; do
		stage_module kmod-fs-btrfs "${_m}"
	done
	for _m in ${MODS_FS_VFAT}; do
		stage_module kmod-fs-vfat "${_m}"
	done
	stage_module kmod-nls-cp437 "${MODS_NLS_CP437}"
	stage_module kmod-nls-iso8859-1 "${MODS_NLS_ISO8859}"
	stage_module kmod-nls-utf8 "${MODS_NLS_UTF8}"
	stage_take kernel "lib/modules/${KVER}/modules.builtin" "lib/modules/${KVER}/modules.builtin"
	# modules.builtin.modinfo 在裁剪过的 rootfs 里常被剥掉：可选，缺了只 WARN（make-initramfs.sh 也这么办）
	stage_optional "lib/modules/${KVER}/modules.builtin.modinfo" "lib/modules/${KVER}/modules.builtin.modinfo"
	stage_take attr usr/bin/getfattr usr/bin/getfattr
	stage_take attr usr/bin/setfattr usr/bin/setfattr
	# libattr 可有可无（make-initramfs.sh 只在有它时才带上）：缺了不算错
	if [ "${DRY_RUN}" = 0 ]; then
		_la=''
		for _d in usr/lib lib; do
			for _f in "${ROOTFS_TREE}/${_d}"/libattr.so*; do
				if [ -e "${_f}" ] || [ -L "${_f}" ]; then
					_la=$_f
					break
				fi
			done
			if [ -n "${_la}" ]; then
				break
			fi
		done
		if [ -n "${_la}" ]; then
			stage_copy "${_la}" "usr/lib/${_la##*/}"
		else
			printf '  STAGE usr/lib/libattr*：rootfs 里没有（attr 是静态链接时可忽略）\n'
		fi
	else
		stage_plan attr 'usr/lib/libattr*' "${ROOTFS_TREE}/usr/lib/libattr.so.*"
	fi
	if [ "${DRY_RUN}" = 0 ]; then
		if [ -n "${MISSING}" ]; then
			stage_fail
		fi
		say "  STAGE 汇总: $(cd "${STAGE_DIR}" && find . ! -type d | wc -l | tr -d ' ') 个文件 -> ${STAGE_DIR}"
	fi
}

# ---------------------------------------------------------------------------
# 4-6. 真跑流水线
# ---------------------------------------------------------------------------
image_mode_supported() {
	grep -q -- '--image' "${AS}" 2>/dev/null
}

full_build() {
	[ -n "${KERNEL}" ] || usage_fail "缺 --kernel <vmlinuz>"
	[ -n "${IMAGE_OUT}" ] || usage_fail "缺 --image-out OUT.img.gz"
	[ -f "${KERNEL}" ] || die "内核不存在: ${KERNEL}" "给 ImageBuilder 产出的 vmlinuz"
	[ -f "${MK}" ] || die "缺 ${MK}" "确认仓库完整（git status）"
	[ -f "${AS}" ] || die "缺 ${AS}" "确认仓库完整（git status）"
	[ -d "${FB_TREE}" ] || die "缺 firstboot 注入树: ${FB_TREE}" "确认 phase1/firstboot/rootfs 存在"
	if [ "${TYPE}" = dev ] && [ ! -d "${DEV_TREE}" ]; then
		die "缺 dev 注入树: ${DEV_TREE}" "确认 phase1/dev/rootfs 存在"
	fi

	if [ "${DRY_RUN}" = 1 ]; then
		WORK=${WORK:-${TMPDIR:-/tmp}/phase1-build.XXXXXX}
		# 已存在的 --work 也按真跑的口径规范化（pwd -P），否则打印出来的 argv 与真跑不是同一条
		# （macOS 上 /tmp 是 /private/tmp 的软链，不规范化就对不上）。dry-run 不创建任何目录。
		if [ -d "${WORK}" ]; then
			WORK=$(cd "${WORK}" && pwd -P) || die "--work 无法规范化: ${WORK}" "确认目录存在且可进入"
		fi
		ROOTFS_TREE=${WORK}/rootfs
		STAGE_DIR=${WORK}/stage
		INITRD=${INITRD_OUT:-${WORK}/initrd.cpio.gz}
		say '# --dry-run：不创建目录、不写盘；WORK 用 mktemp 模板占位、不实际创建'
		say '# --dry-run 不做 --work 的删除/护栏动作（真跑才会规范化后拒系统目录）'
	else
		setup_work
		INITRD=${INITRD_OUT:-${WORK}/initrd.cpio.gz}
	fi

	step "1/6 准备 rootfs tree -> ${ROOTFS_TREE}"
	prepare_and_inject "${ROOTFS_TREE}"

	step "2/6 注入完成：type=${TYPE}"
	say "  firstboot: etc/uci-defaults/10-grow-p2.sh（首启 p2 扩容，两种类型都有）"
	if [ "${TYPE}" = dev ]; then
		say "  dev      : etc/DEV-IMAGE + etc/uci-defaults/90-dev-image + etc/config/firewall 里的 dev-open-wan（构建期写入）"
	else
		say "  dev      : 无（prod 不含 DEV-IMAGE / 90-dev-image / dev-open-wan）"
	fi

	step "3/6 组 STAGE（initrd 载荷，缺项即失败并点名到包）"
	detect_kver
	build_stage

	step "4/6 渲染 /init（取证）+ 生成 initrd（make-initramfs.sh）"
	# rootdev/bootdev 是**烘焙进 initrd** 的设备名：整盘 dd 到 NVMe 后内核给的就是 nvme0n1pN；
	# 换盘型用 --rootdev/--bootdev 覆盖。trial 项的 cmdline 不同，但 /init 的默认设备来自这里。
	#
	# 这一组参数**只写一次**，渲染与打包共用同一份 "$@"：
	# INIT_SHA 是给 CI 自检逐字比对用的（ac-3），参数不一致就是假证据 —— 所以绝不能让
	# 渲染那一条走 make-initramfs.sh 的默认值。
	set -- --kver "${KVER}" --rootdev "${ROOTDEV}" --bootdev "${BOOTDEV}" \
		--bootsub "${BOOTSUB}" --lower "${LOWER}" --overlay "${OVL}"
	INIT_RENDERED=${WORK}/init.rendered
	run sh "${MK}" --render-init-only "${INIT_RENDERED}" "$@" ||
		die "渲染 /init 失败（取证用）" "看上面日志；确认 phase1/initramfs/init 模板存在、无残留占位符"
	if [ "${DRY_RUN}" = 1 ]; then
		# --dry-run 不写 WORK / rootfs / 镜像，但 CI 想在只跑 dry-run 的阶段就拿到 INIT_SHA：
		# 用**同一份参数**在 TMPDIR 里临时渲染一份 /init，算完 sha256 立刻删掉。
		# 这样打印的 sha 与真跑一致（参数同一份），又不违反"dry-run 不写盘"的边界。
		_it=$(mktemp "${TMPDIR:-/tmp}/phase1-init.XXXXXX") || die "mktemp 失败" "确认 TMPDIR 可写"
		if sh "${MK}" --render-init-only "${_it}" "$@" >/dev/null 2>&1; then
			_isha=$(sha256_of "${_it}") || _isha=''
		else
			_isha=''
		fi
		rm -f "${_it}"
		if [ -n "${_isha}" ]; then
			say "INIT_SHA=${_isha}"
			say '  # （--dry-run 的 INIT_SHA：TMPDIR 里临时渲染后已删除；与真跑同参数，可直接对比）'
		else
			say '  # （--dry-run 预渲染 /init 失败 → 拿不到 INIT_SHA；真跑会在这一步报错）'
		fi
	else
		_init_sha=$(sha256_of "${INIT_RENDERED}") || die "没有 sha256sum 也没有 shasum" "apk add coreutils / 本机装 coreutils"
		_sha_len=$(printf '%s' "${_init_sha}" | wc -c | tr -d ' ')
		case ${_init_sha} in
		*[!0-9a-f]*) die "渲染出的 /init 的 sha256 形状不对: ${_init_sha}" "确认渲染产物是真的文件" ;;
		esac
		[ "${_sha_len}" = 64 ] || die "渲染出的 /init 的 sha256 长度不对（${_sha_len}）: ${_init_sha}" \
			"确认渲染产物是真的文件、不是空文件"
		say "INIT_SHA=${_init_sha}"
	fi
	run sh "${MK}" --stage "${STAGE_DIR}" --out "${INITRD}" "$@" ||
		die "make-initramfs.sh 失败" "看上面日志；缺载荷会点名包名，补 PACKAGES 后重跑"

	step "5/6 出镜像（assemble-image.sh --image，产物是未压缩 .img）"
	# --image 是 assemble-image.sh 的正式模式（phase1/README.md §5.5）。
	# 这里保留一次廉价的存在性检查：缺了就在花时间组 initrd 之前失败，而不是跑到最后才发现。
	if ! image_mode_supported; then
		die "phase1/assemble-image.sh 没有 --image 模式（本脚本靠它产出未压缩 .img）" \
			"确认仓库完整（git status）；--image 模式的说明见 phase1/README.md §5.5"
	fi
	IMG=${WORK}/out.img
	set -- --image "${IMG}" --size "${SIZE}" --rootfs "${ROOTFS_TREE}" \
		--kernel "${KERNEL}" --initrd "${INITRD}"
	if [ -n "${BTRFS_LABEL}" ]; then
		set -- "$@" --btrfs-label "${BTRFS_LABEL}"
	fi
	if [ "${WITH_DATA_SUBVOL}" = 1 ]; then
		set -- "$@" --with-data-subvol
	fi
	run sh "${AS}" "$@" ||
		die "assemble-image.sh --image 失败" "看上面日志（分区/loop/解包/grub 任一步失败都会打印原因）"

	step "6/6 大小闸 + 压缩 + 校验（gzip -9 -n，带 sha256）"
	check_img_full_size "${IMG}"
	gzip_image "${IMG}" "${IMAGE_OUT}"
	if [ "${DRY_RUN}" = 1 ]; then
		say '  # （--dry-run：没有产物，跳过 sha256/size 自检）'
		say ''
		say '--dry-run 完成：以上每条 "$ ..." 就是真跑时会 exec 的 argv。'
		return 0
	fi
	_sum=$(sha256_of "${IMAGE_OUT}") || die "没有 sha256sum 也没有 shasum" "apk add coreutils / 本机装 coreutils"
	_sz=$(wc -c <"${IMAGE_OUT}" | tr -d ' ')
	case ${_sz} in
	'' | *[!0-9]*) die "产物大小异常: ${_sz}" "重新构建" ;;
	esac
	[ "${_sz}" -gt 0 ] || die "产物大小为 0: ${IMAGE_OUT}" "确认 gzip 可用、磁盘没满"
	say ''
	say "产物: ${IMAGE_OUT}"
	say "大小: ${_sz} bytes"
	say "sha256: ${_sum}"
	say "type: ${TYPE}   size: ${SIZE}   kver: ${KVER}"
}

# ---------------------------------------------------------------------------
# --prepare-rootfs：离线入口（用例走这条路；不碰 loop/分区/grub）
# ---------------------------------------------------------------------------
prepare_only() {
	if [ "${DRY_RUN}" = 0 ]; then
		if [ -d "${PREPARE}" ] && [ -n "$(ls -A "${PREPARE}" 2>/dev/null)" ]; then
			usage_fail "--prepare-rootfs 的目标目录必须为空: ${PREPARE}"
		fi
		mkdir -p "${PREPARE}" || die "无法创建 ${PREPARE}" "确认父目录存在且可写"
	fi
	if [ "${DRY_RUN}" = 1 ]; then
		WORK=${WORK:-${TMPDIR:-/tmp}/phase1-build.XXXXXX}
	else
		setup_work
	fi
	_dev_tag=''
	if [ "${TYPE}" = dev ]; then
		_dev_tag=' + dev'
	fi
	step "prepare 1/2 解包 + 注入（firstboot${_dev_tag} + dev firewall 规则）"
	prepare_and_inject "${PREPARE}"
	step "prepare 2/2 完成"
	if [ "${DRY_RUN}" = 0 ]; then
		say "  目标目录: ${PREPARE}"
		say "  type    : ${TYPE}"
		say "  文件数  : $(cd "${PREPARE}" && find . ! -type d | wc -l | tr -d ' ')"
		if [ "${TYPE}" = dev ]; then
			say "  firewall: $(grep -c 'dev-open-wan' "${PREPARE}/etc/config/firewall" 2>/dev/null || printf '0') 处 dev-open-wan"
		fi
	fi
	exit 0
}

if [ -n "${PREPARE}" ]; then
	prepare_only
fi
full_build
