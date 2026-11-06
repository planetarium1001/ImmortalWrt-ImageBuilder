#!/bin/sh
# /etc/uci-defaults/10-grow-p2.sh —— 首启一次性动作：把 p2（btrfs root）扩到盘尾。
#
# 为什么要它：交付镜像按固定尺寸（例如 8G）构建，不是按用户盘建；整盘 dd 到更大的
# NVMe 上之后 p2 仍然只有 8G。首启把 p2 撑到盘尾，用户才有整盘空间。
#
# 为什么这样改是安全的（几何前提，别乱改顺序）：
#   本布局的分区顺序是 p1 → p128 → p2，**p2 物理上最后一个**。
#   所以"删掉 p2、按原 start 重建到盘尾"不会挪动 p1 / p128 的起始扇区，
#   p1 里的 GRUB core.img 与 /boot 内容一个字节都不受影响。
#   动分区表之前先断言"p128.start < p2.start"，几何不符就一个字节都不改（宁可少扩一次）。
#   PARTUUID 会变：本系统全链路不用 PARTUUID 锚定（GRUB 用 btrfs 文件系统 UUID，
#   initrd 用内核设备名 + 子卷名），见 phase1/grub/grub.cfg.in 的注释。
#
# 退出语义（uci-defaults：exit 0 ⇒ 本文件被删、不再跑；非 0 ⇒ 文件保留、下次开机再来一次）：
#   * 瞬时失败（sgdisk 写表失败 / sgdisk -p 读不到表 / partx 两条路都失败 / btrfs resize 失败）
#     ⇒ **exit 1**：不阻断启动（boot 只是跳过删文件），下次开机自动重试。
#   * "不该重试"的分支 ⇒ **exit 0**（脚本该退休了，重试一万次也一样）：
#     已满、分区号不是 2、几何异常（p128.start ≥ p2.start）、推不出整盘、缺 sgdisk/partx/btrfs。
#   * 任何失败都只写日志（/dev/kmsg 与 /boot/phase1-grow.log，能写才写）。
#
# 不猜盘：从 /proc/mounts（或 findmnt）认出承载 btrfs 的设备，再推出整盘与分区号；
# 分区号不是 2 就跳过（只动我们自己的 p2）。resize 只对**可写**挂载点做。
# 运行期 / 是 overlayfs，btrfs 挂的是 /rom（@root，ro）与 /overlay（@overlay，rw）
# —— 所以 resize 必须挑可写挂载点（本设计里是 /overlay），不能写死 /。
#
# 测试/调试用路径覆盖（默认值就是固件真路径，生产不需要设）：
#   PROC_MOUNTS       挂载表      默认 /proc/mounts
#   PHASE1_GROW_LOG   日志文件    默认 /boot/phase1-grow.log
#   PHASE1_GROW_KMSG  kmsg 设备   默认 /dev/kmsg
set -u

PROC_MOUNTS=${PROC_MOUNTS:-/proc/mounts}
GROW_LOG=${PHASE1_GROW_LOG:-/boot/phase1-grow.log}
GROW_KMSG=${PHASE1_GROW_KMSG:-/dev/kmsg}

log() {
	if [ -n "${GROW_LOG}" ]; then
		printf '%s 10-grow-p2: %s\n' "$(date '+%F %T' 2>/dev/null || printf '-')" "$*" >>"${GROW_LOG}" 2>/dev/null
	fi
	if [ -n "${GROW_KMSG}" ] && [ -w "${GROW_KMSG}" ] 2>/dev/null; then
		# 追加（不是覆盖）：kmsg 要留完整过程，排障时才看得到"失败发生在哪一步"
		printf '10-grow-p2: %s\n' "$*" >>"${GROW_KMSG}" 2>/dev/null
	fi
	return 0
}

# 跑一条命令并把它自己的输出也写进日志；失败只记日志（本脚本没有 set -e，
# 调用点显式处理返回值 —— 瞬时失败 exit 1 让下次开机重试，绝不 exit 0 假装成功）。
try() { # <说明> <命令...>
	_descr=$1
	shift
	printf '$ %s\n' "$*" >>"${GROW_LOG}" 2>/dev/null
	if "$@" >>"${GROW_LOG}" 2>&1; then
		log "ok: ${_descr}"
		return 0
	fi
	log "FAIL: ${_descr}（命令: $*）"
	return 1
}

# ---------------------------------------------------------------------------
# 0. 认盘：btrfs 挂在哪个设备、挂载点是否可写
# ---------------------------------------------------------------------------
btrfs_dev() { # 输出 "<设备> <挂载点>"；找不到返回非 0
	# 按挂载表顺序取**第一个** fstype=btrfs 且 rw 的挂载：
	# /init 先挂 @overlay（rw）再挂 @root（ro）与 @lower（ro），ro 的会被过滤掉，
	# 所以这里拿到的就是 /overlay —— 也正是 btrfs resize 需要的可写挂载点。
	if [ -r "${PROC_MOUNTS}" ]; then
		_out=$(awk '$3 == "btrfs" && $4 ~ /(^|,)rw(,|$)/ && $1 ~ /^\/dev\// { print $1 " " $2; exit }' \
			"${PROC_MOUNTS}" 2>/dev/null)
		if [ -n "${_out}" ]; then
			printf '%s\n' "${_out}"
			return 0
		fi
	fi
	# 兜底：findmnt（util-linux）。设备上不一定有。
	command -v findmnt >/dev/null 2>&1 || return 1
	_out=$(findmnt -n -o SOURCE,TARGET,OPTIONS -t btrfs 2>/dev/null |
		awk '$1 ~ /^\/dev\// && $3 ~ /(^|,)rw(,|$)/ { print $1 " " $2; exit }') || _out=''
	if [ -n "${_out}" ]; then
		printf '%s\n' "${_out}"
		return 0
	fi
	return 1
}

_res=$(btrfs_dev) || _res=''
DEV=${_res%% *}
MNT=${_res#* }
if [ -z "${DEV}" ] || [ -z "${MNT}" ] || [ "${MNT}" = "${DEV}" ]; then
	log "找不到可写的 btrfs 挂载点（看了 ${PROC_MOUNTS} 与 findmnt）：不重试，需手工确认 btrfs 子卷挂载"
	exit 0
fi
if [ ! -d "${MNT}" ] || [ ! -w "${MNT}" ]; then
	log "btrfs 挂载点 ${MNT} 不可写（btrfs resize 需要可写挂载）：不重试，需手工修正挂载"
	exit 0
fi

# 设备名 → 整盘 + 分区号：/dev/nvme0n1p2 → /dev/nvme0n1 + 2；/dev/sda2 → /dev/sda + 2
_name=${DEV##*/}
case "${_name}" in
*[0-9]) ;;
*)
	log "根设备 ${DEV} 看起来不是分区（结尾没有数字）：不重试，需手工确认布局"
	exit 0
	;;
esac
PN=${_name##*[!0-9]}
_head=${_name%"${PN}"}
case "${_head}" in
*p) DISK=${DEV%p"${PN}"} ;;
*) DISK=${DEV%"${PN}"} ;;
esac
if [ "${PN}" != 2 ]; then
	log "根分区号是 ${PN}（不是 2）：这不是本布局的 p2，不重试、不动盘"
	exit 0
fi
case "${DISK}" in
/dev/*) ;;
*)
	log "推不出整盘名（设备 ${DEV}）：不重试，需手工确认布局"
	exit 0
	;;
esac

# ---------------------------------------------------------------------------
# 1. 工具自检：缺工具就只记日志（不重试也没用，工具不会自己长出来）
# ---------------------------------------------------------------------------
_have_all=1
for _t in sgdisk partx btrfs; do
	if ! command -v "${_t}" >/dev/null 2>&1; then
		log "缺少 ${_t}（apk add gdisk / partx-utils / btrfs-progs）：不重试，补齐工具后手工跑一次"
		_have_all=0
	fi
done
if [ "${_have_all}" != 1 ]; then
	exit 0
fi

log "开始：DEV=${DEV} DISK=${DISK} PN=${PN} BTRFS_MNT=${MNT}"

# ---------------------------------------------------------------------------
# 2. sgdisk -e：先把备份 GPT 挪到盘尾（否则"扩到盘尾"没有盘尾可扩）
# ---------------------------------------------------------------------------
if ! try "sgdisk -e ${DISK}（备份 GPT 挪到盘尾）" sgdisk -e "${DISK}"; then
	log "sgdisk -e 失败：瞬时失败，退出码 1（脚本保留，下次开机会重试）"
	exit 1
fi

# ---------------------------------------------------------------------------
# 3. 读几何 + 三道断言
# ---------------------------------------------------------------------------
_table=$(sgdisk -p "${DISK}" 2>>"${GROW_LOG}") || _table=''
if [ -z "${_table}" ]; then
	log "sgdisk -p ${DISK} 读不到分区表：瞬时失败，退出码 1（下次开机会重试）"
	exit 1
fi

LAST=$(printf '%s\n' "${_table}" | sed -n 's/.*last usable sector is \([0-9][0-9]*\).*/\1/p' | head -1)
_p2=$(printf '%s\n' "${_table}" | awk '$1 == 2 { print $2, $3; exit }')
_p128=$(printf '%s\n' "${_table}" | awk '$1 == 128 { print $2, $3; exit }')
P2_START=${_p2%% *}
P2_END=${_p2#* }
P128_START=${_p128%% *}

for _v in "${LAST}" "${P2_START}" "${P2_END}" "${P128_START}"; do
	case "${_v}" in
	'' | *[!0-9]*)
		log "分区表解析失败（last=[${LAST}] p2=[${_p2}] p128=[${_p128}]）：几何不是本布局，不重试，需手工核对"
		exit 0
		;;
	esac
done

# 断言 1：p2 的 end 已到盘尾 ⇒ 已满，什么都不做（幂等的核心）
if [ "${P2_END}" -ge "${LAST}" ]; then
	log "already-full：p2 end=${P2_END} 已到盘尾 ${LAST}，无需扩容"
	exit 0
fi

# 断言 2：p128（EF02，GRUB core.img 预留）必须在 p2 之前。
# 反了的话"重建 p2 到盘尾"会覆盖 p128 或挪动它的起始扇区 ⇒ 拒绝，不动盘。
if [ "${P128_START}" -ge "${P2_START}" ]; then
	log "几何异常：p128 start=${P128_START} >= p2 start=${P2_START}，拒绝改分区表（不动盘）；不重试，需手工核对"
	exit 0
fi

log "几何: p128 start=${P128_START} < p2 start=${P2_START}, p2 end=${P2_END}, 盘尾=${LAST}"

# ---------------------------------------------------------------------------
# 4. 重建 p2：同 start、end=0（盘尾），类型 8300、名字保持 phase1-root
# ---------------------------------------------------------------------------
if ! try "sgdisk -d 2 -n 2:${P2_START}:0 ${DISK}" \
	sgdisk -d 2 -n "2:${P2_START}:0" -t 2:8300 -c 2:phase1-root "${DISK}"; then
	log "重建 p2 失败：瞬时失败，退出码 1（下次开机会重试）"
	exit 1
fi

# ---------------------------------------------------------------------------
# 5. 让内核重读分区表：partx -u 优先，不可用退化 partx -a -n 2:2
# ---------------------------------------------------------------------------
if ! try "partx -u ${DISK}" partx -u "${DISK}"; then
	if ! try "partx -a -n 2:2 ${DISK}（partx -u 不可用，退化）" partx -a -n 2:2 "${DISK}"; then
		log "分区表已改但内核没重读（partx 两种用法都失败）：瞬时失败，退出码 1（下次开机会重试）"
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# 6. btrfs 扩到 max（对可写挂载点做，见文件头）
# ---------------------------------------------------------------------------
if ! try "btrfs filesystem resize max ${MNT}" btrfs filesystem resize max "${MNT}"; then
	log "btrfs resize 失败：瞬时失败，退出码 1（下次开机会重试；若反复失败手工跑 btrfs filesystem resize max ${MNT}）"
	exit 1
fi

log "done：p2 已扩到盘尾（原 end=${P2_END}，盘尾=${LAST}），btrfs filesystem resize max ${MNT} 完成"
exit 0
