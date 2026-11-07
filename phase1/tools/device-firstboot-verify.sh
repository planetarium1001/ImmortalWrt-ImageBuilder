#!/bin/sh
# phase1/tools/device-firstboot-verify.sh —— Phase 1 可刷镜像的**真机首启**判据（collect → assert）
#
# 为什么要有它（而不是复用 phase1/tools/device-verify.sh）：
#   旧脚本的默认值是**旧布局**（`@phase1-root`/`@phase1-overlay`/`phase1_dev=/dev/nvme0n1p3`，
#   配 `p1 32M + p2 512M squashfs + p3 btrfs`），而当前 CI 产物是
#   `p1 256M vfat + p128 EF02 4M + p2 btrfs 到盘尾`、子卷 `@root @overlay @docker @swap`。
#   拿旧脚本验新镜像会大面积 FAIL，而 FAIL 的原因与"镜像真的坏了"无法区分 —— 取证任务最怕这个。
#   所以：新几何用这个脚本，旧脚本保留但标 legacy（见其文件头），两者判据不混。
#
# 架构：**先抓取、再断言**。同一份断言既跑在刚抓下来的设备输出上（live 模式），
#       也跑在已归档的原始文件上（--collected 模式）——现场结论与事后复核因此可比。
#
# 判据为什么这么写（每一条都是踩过的坑）：
#   * fb-1 前提必须第一位：`/` 行要同时含 `lowerdir=/lower` 与 `upperdir=/overlay/upper`。
#     live 的 fstools extroot 也含 `upperdir=/overlay/upper`，只按它判会把"写层在 tmpfs 的旧系统"
#     判成通过（§O.1 教训：假阳性比漏判更贵）。前提不成立时**不再往下判**，避免拼出无意义的结论。
#   * fb-6 子卷要"恰为四个"：多出来的子卷说明盘上还躺着旧镜像的痕迹，不能算干净首启。
#   * fb-9 p2 的 end 必须等于 sgdisk 眼里的 last usable sector：这是"首启扩容真的做完了"的机器判据
#     （10-grow-p2.sh 失败会 exit 1 并下次开机重试，所以这里只判终态）。
#   * fb-11 校验 `git_sha`：证明设备上跑的就是这次 CI 构建，防"刷了旧镜像却以为验的是新的"。
#   * fb-16 dmesg 里不许出现内核的 `no usable overlay filesystem found, using tmpfs overlay`（ramoverlay
#     假阳性），且必须有 initramfs 的 `switching root upperdir=/overlay/upper` 那一行。
#
# 用法：
#   ROUTER=root@192.168.100.1 sh phase1/tools/device-firstboot-verify.sh   # 直连设备
#   ROUTER=local sh phase1/tools/device-firstboot-verify.sh               # 在设备本机跑
#   sh phase1/tools/device-firstboot-verify.sh --collected <证据目录>      # 不连设备，复核已归档证据
#
# 退出码（与 shell/tests/all.sh 的 PEND 约定一致）：
#   0 = DEVICE-FIRSTBOOT OK；1 = DEVICE-FIRSTBOOT FAILED；2 = DEVICE-FIRSTBOOT PEND（未设 ROUTER / 连不上）
#
# 测试钩子（默认值就是固件真路径，生产不要设）：
#   PROC_MOUNTS   挂载表       默认 /proc/mounts
#   FB_ROOT       文件读取根   默认空（即真 `/`）：拼在 /etc/DEV-IMAGE、/etc/dropbear、/etc/config、/boot 前面
#   FB_HOSTNAME   hostname 文件 默认 /proc/sys/kernel/hostname
set -u

PROC_MOUNTS=${PROC_MOUNTS:-/proc/mounts}
FB_ROOT=${FB_ROOT:-}
FB_HOSTNAME=${FB_HOSTNAME:-/proc/sys/kernel/hostname}

ROUTER="${ROUTER:-}"
MODE='device'
DIR=''
OUT=${PHASE1_FIRSTBOOT_OUT:-}
EXPECT_SHA=''   # 空 = 只要求证据里有 git_sha 行并记录；给了就必须逐字相等
KEEP=0
SSHOPT='-o ControlPath=none -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes'

# 本次产物的几何（改镜像就必须同步改这里，否则离线用例会红——这是有意的）
EXP_P1_START=2048
EXP_P1_SECTORS=524288        # 256 MiB
EXP_P128_SECTORS=8192        # 4 MiB
SUBVOLS_EXPECT='@docker @overlay @root @swap'

FAIL=0
NCHECK=0
SNAP=''

ok()   { NCHECK=$((NCHECK + 1)); printf '  ok   %s\n' "$*"; }
bad()  { NCHECK=$((NCHECK + 1)); FAIL=1; printf '  FAIL %s\n' "$*"; }
info() { printf '  ..   %s\n' "$*"; }

usage() {
	cat <<'USAGE'
phase1/tools/device-firstboot-verify.sh —— Phase 1 可刷镜像真机首启判据（collect → assert）

用法：
  ROUTER=root@<ip> sh phase1/tools/device-firstboot-verify.sh [选项]   # 直连设备抓取并判定
  ROUTER=local     sh phase1/tools/device-firstboot-verify.sh [选项]   # 设备本机跑（不 ssh）
  sh phase1/tools/device-firstboot-verify.sh --collected <证据目录>    # 只复核已归档证据

选项：
  --router USER@HOST    同环境变量 ROUTER；`local` = 本机跑
  --collected DIR       证据复核模式（不连设备）
  --out DIR             抓取输出目录（默认 .workflow/assets/wrt-ab-artifacts/phase1-device-firstboot）
  --expect-sha SHA      期望的 git_sha；不给则只记录证据里的值（避免写死导致下次构建假 FAIL）
  --keep                保留临时抓取目录
  -h, --help

判据（id 稳定，改动会破坏历史证据可比性）：
  fb-1  前提：/ 是 overlayfs 且同时含 lowerdir=/lower 与 upperdir=/overlay/upper（否则一律 FAILED，不往下判）
  fb-2  /lower = subvol @root 且 ro
  fb-3  /overlay = subvol @overlay 且 rw 且 compress=zstd:1
  fb-4  /opt/docker = subvol @docker
  fb-5  /swap = subvol @swap
  fb-6  btrfs 上子卷**恰为** @root @overlay @docker @swap
  fb-7  p1 起始 2048 扇区、256 MiB、vfat
  fb-8  p128 为 4 MiB EF02，且 p128.start < p2.start（首启扩容的几何前提）
  fb-9  p2 的 end == 分区表 last usable sector（扩容已到盘尾）
  fb-10 /overlay 容量 >= 整盘 90%（btrfs resize 真的生效）
  fb-11 /etc/DEV-IMAGE 含 type=dev 与期望的 git_sha
  fb-12 firewall 含 dev-open-wan（src=wan / proto=all / target=ACCEPT）
  fb-13 /etc/dropbear/authorized_keys 存在、0600、含 ssh-ed25519 行
  fb-14 hostname 含 -dev
  fb-15 /boot 可见 vmlinuz 与 grub/
  fb-16 dmesg：无 ramoverlay 假阳性告警，且有 switching root upperdir=/overlay/upper
  fb-17 /boot/phase1-grow.log：10-grow-p2 有结论行（done / already-full）且无 FAIL:

退出码：0 = DEVICE-FIRSTBOOT OK；1 = DEVICE-FIRSTBOOT FAILED；2 = DEVICE-FIRSTBOOT PEND（未设 ROUTER / 连不上）
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--router) [ $# -ge 2 ] || { printf 'device-firstboot-verify: --router 缺值\n' >&2; exit 2; }; ROUTER=$2; shift 2 ;;
		--router=*) ROUTER=${1#*=}; shift ;;
		--collected) [ $# -ge 2 ] || { printf 'device-firstboot-verify: --collected 缺目录\n' >&2; exit 2; }; MODE='collected'; DIR=$2; shift 2 ;;
		--collected=*) MODE='collected'; DIR=${1#*=}; shift ;;
		--out) [ $# -ge 2 ] || { printf 'device-firstboot-verify: --out 缺目录\n' >&2; exit 2; }; OUT=$2; shift 2 ;;
		--out=*) OUT=${1#*=}; shift ;;
		--expect-sha) [ $# -ge 2 ] || { printf 'device-firstboot-verify: --expect-sha 缺值\n' >&2; exit 2; }; EXPECT_SHA=$2; shift 2 ;;
		--expect-sha=*) EXPECT_SHA=${1#*=}; shift ;;
		--keep) KEEP=1; shift ;;
		*) printf 'device-firstboot-verify: 未知参数 %s（见 --help）\n' "$1" >&2; exit 2 ;;
	esac
done

cleanup() {
	if [ -n "${SNAP}" ] && [ "${KEEP}" = 0 ] && [ -d "${SNAP}" ] && [ "${SNAP}" != "${OUT}" ]; then
		rm -rf "${SNAP}"
	fi
	return 0
}
trap cleanup EXIT

pend() {
	printf 'PEND: %s\n' "$*"
	printf 'DEVICE-FIRSTBOOT PEND\n'
	exit 2
}

# =========================================================================
# 抓取（只读；不改设备任何状态）
# =========================================================================
# 远端命令一律经此函数：ssh 到设备，或本机直接 sh -c
remote() {
	if [ "${ROUTER}" = 'local' ]; then
		sh -c "$1"
	else
		# shellcheck disable=SC2086
		ssh ${SSHOPT} "${ROUTER}" "$1"
	fi
}

# probe_stdin <文件名> <描述> <本地脚本>：把脚本经 stdin 交给设备的 sh（省掉层层引号转义）
probe_stdin() {
	_name=$1
	_descr=$2
	_script=$3
	info "抓取 ${_name}（${_descr}）"
	if [ "${ROUTER}" = 'local' ]; then
		sh -s <"${_script}" >"${SNAP}/${_name}" 2>&1
	else
		# shellcheck disable=SC2086
		ssh ${SSHOPT} "${ROUTER}" 'sh -s' <"${_script}" >"${SNAP}/${_name}" 2>&1
	fi
	return 0
}

# probe <文件名> <描述> <命令>
probe() {
	_name=$1
	_descr=$2
	_cmd=$3
	info "抓取 ${_name}（${_descr}）"
	if remote "${_cmd}" >"${SNAP}/${_name}" 2>&1; then
		return 0
	fi
	# 抓取失败不算 FAIL：判据会在断言阶段以"缺证据"报出来（fail-closed）
	info "抓取 ${_name} 退出码非 0（内容仍保留，断言阶段会判）"
	return 0
}

collect() {
	printf '== device-firstboot-verify：抓取设备状态（只读）==\n'
	if [ "${ROUTER}" != 'local' ]; then
		if ! remote 'echo ok' >/dev/null 2>&1; then
			# 显式给了设备却连不上，不是"本机没接设备"（那才是 PEND），而是设备不可达，必须红灯。
			bad "fb-0 连不上 ${ROUTER}（ssh 失败）：设备没起来 / 没网络 / 密钥未授权，都必须当失败处理"
			printf '\nDEVICE-FIRSTBOOT FAILED（设备不可达；共 %d 项检查）\n' "${NCHECK}"
			exit 1
		fi
	fi
	[ -d "${SNAP}" ] || mkdir -p "${SNAP}" || pend "建不出抓取目录 ${SNAP}"

	probe proc_mounts      '挂载表'        "cat ${PROC_MOUNTS}"
	probe hostname         'hostname'      "cat ${FB_HOSTNAME} 2>/dev/null || hostname 2>/dev/null"
	probe dev_image        '/etc/DEV-IMAGE' "cat ${FB_ROOT}/etc/DEV-IMAGE 2>/dev/null"
	probe firewall         'firewall 配置'  "{ uci show firewall 2>/dev/null || cat ${FB_ROOT}/etc/config/firewall 2>/dev/null; }"
	probe dropbear         'dropbear 权限与公钥' "{ ls -ld ${FB_ROOT}/etc/dropbear 2>/dev/null; ls -l ${FB_ROOT}/etc/dropbear/authorized_keys 2>/dev/null; { stat -c '%a %n' ${FB_ROOT}/etc/dropbear ${FB_ROOT}/etc/dropbear/authorized_keys 2>/dev/null || stat -f '%Lp %N' ${FB_ROOT}/etc/dropbear ${FB_ROOT}/etc/dropbear/authorized_keys 2>/dev/null; }; printf 'KEYS=%s\\n' \"\$(grep -c '^ssh-' ${FB_ROOT}/etc/dropbear/authorized_keys 2>/dev/null || echo 0)\"; printf 'KEY1=%s\\n' \"\$(awk 'NR==1{print \$1}' ${FB_ROOT}/etc/dropbear/authorized_keys 2>/dev/null)\"; }"
	probe subvols          'btrfs 子卷表'   "btrfs subvolume list /overlay 2>&1"
	probe df               '容量'          "df -k /overlay /lower /opt/docker /swap 2>&1"
	_disk_script="${SNAP}/.probe-gpt.sh"
	cat >"${_disk_script}" <<'EOS'
_dev=$(awk '$2 == "/overlay" { print $1; exit }' "${PROC_MOUNTS:-/proc/mounts}")
printf 'OVERLAY_DEV=%s\n' "${_dev:-<unknown>}"
if [ -z "${_dev:-}" ]; then
	printf 'DISK=<unknown>\n'
	exit 0
fi
_disk=$(printf '%s' "${_dev}" | sed 's/[0-9][0-9]*$//')
case "${_disk}" in *p) _disk=${_disk%p} ;; esac
printf 'DISK=%s\n' "${_disk}"
printf 'SECTORS=%s\n' "$(blockdev --getsz "${_disk}" 2>/dev/null || echo '<unknown>')"
sgdisk -p "${_disk}" 2>&1
EOS
	probe_stdin gpt        '分区表与整盘扇区' "${_disk_script}"
	probe boot_listing     '/boot 内容'     "{ ls ${FB_ROOT}/boot 2>/dev/null; echo '--- grub ---'; ls ${FB_ROOT}/boot/grub 2>/dev/null | head -5; }"
	probe dmesg_tail       'dmesg 片段'     "dmesg 2>/dev/null | tail -60"
	probe ip_addr          'IPv4 地址'      "ip -4 addr show 2>/dev/null || ifconfig 2>/dev/null"
	probe grow_log         '/boot/phase1-grow.log' "tail -30 ${FB_ROOT}/boot/phase1-grow.log 2>&1"
	probe boot_log         '/boot/phase1-boot.log' "tail -60 ${FB_ROOT}/boot/phase1-boot.log 2>&1"

	if [ -n "${OUT}" ]; then
		mkdir -p "${OUT}" 2>/dev/null || info "归档目录 ${OUT} 建不出来（判据不受影响）"
		if [ -d "${OUT}" ]; then
			cp "${SNAP}"/* "${OUT}"/ 2>/dev/null || info "归档复制部分失败"
			info "证据已归档到 ${OUT}"
		fi
	fi
	return 0
}

# =========================================================================
# 断言（live 与 --collected 共用同一份；缺证据一律 fail-closed）
# =========================================================================
have() { # <文件basename>：证据文件存在且非空
	if [ ! -f "${DIR}/$1" ]; then
		bad "缺证据文件 $1（fail-closed）"
		return 1
	fi
	return 0
}

line_of() { # <文件> <挂载点>：/proc/mounts 里 $2 == 挂载点 的那一行
	awk -v mp="$2" '$2 == mp { print; exit }' "$1" 2>/dev/null
}

assert_all() {
	printf '\n== 判据（证据目录 %s）==\n' "${DIR}"

	# ---- fb-1 前提：我方合成根 ----
	if have proc_mounts; then
		_root_line=$(line_of "${DIR}/proc_mounts" '/')
		_root_opts=$(printf '%s\n' "${_root_line}" | awk '{ print $4 }')
		_root_fs=$(printf '%s\n' "${_root_line}" | awk '{ print $3 }')
		_root_is_ours=0
		if [ -n "${_root_line}" ] && [ "${_root_fs}" = 'overlay' ]; then
			case "${_root_opts}" in *lowerdir=/lower*) case "${_root_opts}" in *upperdir=/overlay/upper*) _root_is_ours=1 ;; esac ;; esac
		fi
		# live 的 fstools extroot：lowerdir=/ 且含 upperdir=/overlay/upper
		_root_is_live=0
		case "${_root_opts}" in *lowerdir=/*) case "${_root_opts}" in *lowerdir=/lower*) : ;; *) _root_is_live=1 ;; esac ;; esac
		if [ "${_root_is_ours}" = 1 ]; then
			ok "fb-1 / 是我方合成根（overlay + lowerdir=/lower + upperdir=/overlay/upper）"
		elif [ "${_root_is_live}" = 1 ]; then
			bad "fb-1 / 是 live（fstools extroot，lowerdir=/）：本机没在合成根上，以下判据一律不下结论"
			printf '\nDEVICE-FIRSTBOOT FAILED（前提不成立：设备在 live，不在我方合成根；共 %d 项检查）\n' "${NCHECK}"
			exit 1
		else
			bad "fb-1 / 不是预期形态（fstype=${_root_fs:-<空>} opts=${_root_opts:-<空>}）：以下判据一律不下结论"
			printf '\nDEVICE-FIRSTBOOT FAILED（前提不成立；共 %d 项检查）\n' "${NCHECK}"
			exit 1
		fi
	fi

	# ---- fb-2 /lower ----
	if have proc_mounts; then
		_line=$(line_of "${DIR}/proc_mounts" '/lower')
		_opts=$(printf '%s\n' "${_line}" | awk '{ print $4 }')
		if [ -z "${_line}" ]; then
			bad "fb-2 /lower 没有挂载（overlay 的只读基座缺失）"
		else
			case "${_opts}" in
				*subvol=/@root*|*subvol=@root*) case "${_opts}" in
					*ro,*|*,ro) ok "fb-2 /lower = subvol @root 且 ro" ;;
					*) bad "fb-2 /lower 的 subvol 是 @root 但不是 ro（opts: ${_opts}）" ;;
				esac ;;
				*) bad "fb-2 /lower 的 subvol 不是 @root（opts: ${_opts}）" ;;
			esac
		fi
	fi

	# ---- fb-3 /overlay ----
	if have proc_mounts; then
		_line=$(line_of "${DIR}/proc_mounts" '/overlay')
		_opts=$(printf '%s\n' "${_line}" | awk '{ print $4 }')
		if [ -z "${_line}" ]; then
			bad "fb-3 /overlay 没有挂载（写层缺失 ⇒ 所有写入都会丢）"
		else
			_case_ok=1
			case "${_opts}" in *subvol=/@overlay*|*subvol=@overlay*) : ;; *) _case_ok=0; bad "fb-3 /overlay 的 subvol 不是 @overlay（opts: ${_opts}）" ;; esac
			if [ "${_case_ok}" = 1 ]; then
				case "${_opts}" in *rw,*) : ;; *) _case_ok=0; bad "fb-3 /overlay 不是 rw（opts: ${_opts}）" ;; esac
			fi
			if [ "${_case_ok}" = 1 ]; then
				case "${_opts}" in *compress=zstd*) ok "fb-3 /overlay = subvol @overlay、rw、compress=zstd" ;; *) bad "fb-3 /overlay 缺 compress=zstd（opts: ${_opts}）" ;; esac
			fi
		fi
	fi

	# ---- fb-4 /opt/docker ----
	if have proc_mounts; then
		_line=$(line_of "${DIR}/proc_mounts" '/opt/docker')
		_opts=$(printf '%s\n' "${_line}" | awk '{ print $4 }')
		if [ -z "${_line}" ]; then
			bad "fb-4 /opt/docker 没有挂载到 @docker"
		else
			case "${_opts}" in *subvol=/@docker*|*subvol=@docker*) ok "fb-4 /opt/docker = subvol @docker" ;; *) bad "fb-4 /opt/docker 的 subvol 不是 @docker（opts: ${_opts}）" ;; esac
		fi
	fi

	# ---- fb-5 /swap ----
	if have proc_mounts; then
		_line=$(line_of "${DIR}/proc_mounts" '/swap')
		_opts=$(printf '%s\n' "${_line}" | awk '{ print $4 }')
		if [ -z "${_line}" ]; then
			bad "fb-5 /swap 没有挂载到 @swap"
		else
			case "${_opts}" in *subvol=/@swap*|*subvol=@swap*) ok "fb-5 /swap = subvol @swap" ;; *) bad "fb-5 /swap 的 subvol 不是 @swap（opts: ${_opts}）" ;; esac
		fi
	fi

	# ---- fb-6 子卷恰为四个 ----
	if have subvols; then
		_got=$(awk '{ for (i = 1; i < NF; i++) if ($i == "path") { print $NF; break } }' "${DIR}/subvols" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ *$//')
		if [ "${_got}" = "${SUBVOLS_EXPECT}" ]; then
			ok "fb-6 子卷恰为 @root @overlay @docker @swap"
		else
			bad "fb-6 子卷集合不符：期望『${SUBVOLS_EXPECT}』实际『${_got:-<空>}』（多出来通常是旧镜像残留）"
		fi
	fi

	# ---- fb-7/8/9 分区几何 ----
	if have gpt; then
		_total=$(sed -n 's/.*SECTORS=\([0-9][0-9]*\).*/\1/p' "${DIR}/gpt" | head -1)
		_last=$(sed -n 's/.*last usable sector is \([0-9][0-9]*\).*/\1/p' "${DIR}/gpt" | head -1)
		_p1=$(awk '$1 == 1 { print $2, $3; exit }' "${DIR}/gpt")
		_p128=$(awk '$1 == 128 { print $2, $3; exit }' "${DIR}/gpt")
		_p2=$(awk '$1 == 2 { print $2, $3; exit }' "${DIR}/gpt")
		_p1_start=$(printf '%s\n' "${_p1}" | awk '{ print $1 }')
		_p1_end=$(printf '%s\n' "${_p1}" | awk '{ print $2 }')
		_p128_start=$(printf '%s\n' "${_p128}" | awk '{ print $1 }')
		_p128_end=$(printf '%s\n' "${_p128}" | awk '{ print $2 }')
		_p2_start=$(printf '%s\n' "${_p2}" | awk '{ print $1 }')
		_p2_end=$(printf '%s\n' "${_p2}" | awk '{ print $2 }')

		if [ -n "${_p1_end}" ] && [ -n "${_p1_start}" ] && [ "$((_p1_end - _p1_start + 1))" -eq "${EXP_P1_SECTORS}" ] && [ "${_p1_start}" = "${EXP_P1_START}" ]; then
			ok "fb-7 p1 起始 ${_p1_start}、$((EXP_P1_SECTORS / 2048)) MiB"
		else
			bad "fb-7 p1 几何不符：start=${_p1_start:-<空>} end=${_p1_end:-<空>}（期望 start=${EXP_P1_START}，${EXP_P1_SECTORS} 扇区）"
		fi

		if [ -n "${_p128_end}" ] && [ "$((_p128_end - _p128_start + 1))" -eq "${EXP_P128_SECTORS}" ] && [ -n "${_p2_start}" ] && [ "${_p128_start}" -lt "${_p2_start}" ]; then
			ok "fb-8 p128 = 4 MiB 且 p128.start(${_p128_start}) < p2.start(${_p2_start})"
		else
			bad "fb-8 p128 几何不符：start=${_p128_start:-<空>} end=${_p128_end:-<空>} p2.start=${_p2_start:-<空>}（扩容前提是 p2 物理最后一个）"
		fi

		if [ -n "${_last}" ] && [ -n "${_p2_end}" ] && [ "${_p2_end}" = "${_last}" ]; then
			ok "fb-9 p2 end=${_p2_end} == last usable sector（已扩到盘尾）"
		else
			bad "fb-9 p2 没扩到盘尾：p2.end=${_p2_end:-<空>} last usable=${_last:-<空>}（看 /boot/phase1-grow.log）"
		fi

		# ---- fb-10 /overlay 容量 ----
		if have df && [ -n "${_total}" ]; then
			_ovl_kb=$(awk '$NF == "/overlay" || $6 == "/overlay" { print $2; exit }' "${DIR}/df" 2>/dev/null)
			_disk_kb=$((_total / 2))
			if [ -n "${_ovl_kb}" ] && [ "${_disk_kb}" -gt 0 ] && [ $((_ovl_kb * 100)) -ge $((_disk_kb * 90)) ]; then
				ok "fb-10 /overlay ${_ovl_kb} KiB >= 整盘 90%（整盘 ${_disk_kb} KiB）"
			else
				bad "fb-10 /overlay 容量不足：${_ovl_kb:-<空>} KiB vs 整盘 ${_disk_kb:-<空>} KiB"
			fi
		fi
	fi

	# ---- fb-11 DEV-IMAGE ----
	if have dev_image; then
		if grep -q '^type=dev$' "${DIR}/dev_image" 2>/dev/null; then
			ok "fb-11 /etc/DEV-IMAGE type=dev"
		else
			bad "fb-11 /etc/DEV-IMAGE 不是 type=dev"
		fi
		_sha=$(sed -n 's/^git_sha=//p' "${DIR}/dev_image" 2>/dev/null | head -1)
		if [ -z "${_sha}" ]; then
			bad "fb-11 /etc/DEV-IMAGE 里没有 git_sha 行（无法证明跑的是哪次构建）"
		elif [ -z "${EXPECT_SHA}" ]; then
			ok "fb-11 git_sha=${_sha}（未指定 --expect-sha，只记录不比对）"
		elif [ "${_sha}" = "${EXPECT_SHA}" ]; then
			ok "fb-11 git_sha=${_sha} 与期望一致"
		else
			bad "fb-11 git_sha=${_sha} 与 --expect-sha=${EXPECT_SHA} 不符"
		fi
	fi

	# ---- fb-12 firewall dev-open-wan ----
	if have firewall; then
		if grep -q 'dev-open-wan' "${DIR}/firewall" 2>/dev/null \
			&& grep -q 'src=.wan.' "${DIR}/firewall" 2>/dev/null \
			&& grep -q 'proto=.all.' "${DIR}/firewall" 2>/dev/null \
			&& grep -q 'target=.ACCEPT.' "${DIR}/firewall" 2>/dev/null; then
			ok "fb-12 firewall 含 dev-open-wan（src=wan / proto=all / target=ACCEPT）"
		else
			bad "fb-12 firewall 缺 dev-open-wan 或其字段（dev 镜像的 WAN 放行没生效）"
		fi
	fi

	# ---- fb-13 dropbear 公钥 ----
	if have dropbear; then
		_mode=$(sed -n 's/^\([0-7][0-7][0-7]\) .*authorized_keys$/\1/p' "${DIR}/dropbear" | head -1)
		_nkeys=$(sed -n 's/^KEYS=\([0-9][0-9]*\)$/\1/p' "${DIR}/dropbear" | head -1)
		_key1=$(sed -n 's/^KEY1=\(.*\)$/\1/p' "${DIR}/dropbear" | head -1)
		if [ -n "${_mode}" ] && [ "${_mode}" = '600' ] && [ "${_nkeys:-0}" -ge 1 ] && [ "${_key1}" = 'ssh-ed25519' ]; then
			ok "fb-13 authorized_keys 存在、0600、含 ${_nkeys} 条 ssh-ed25519 公钥"
		else
			bad "fb-13 authorized_keys 不符：权限=${_mode:-<读不到>} 条数=${_nkeys:-0} 首行类型=${_key1:-<空>}（应为 600 / >=1 / ssh-ed25519）"
		fi
	fi

	# ---- fb-14 hostname ----
	if have hostname; then
		_hn=$(tr -d '\r\n' <"${DIR}/hostname" 2>/dev/null)
		case "${_hn}" in
			*-dev*) ok "fb-14 hostname=${_hn}（含 -dev）" ;;
			*) bad "fb-14 hostname=${_hn:-<空>} 不含 -dev（可能刷的是 prod 镜像，或 dev 注入没生效）" ;;
		esac
	fi

	# ---- fb-15 /boot ----
	if have boot_listing; then
		if grep -q '^vmlinuz' "${DIR}/boot_listing" 2>/dev/null && grep -q 'grub' "${DIR}/boot_listing" 2>/dev/null; then
			ok "fb-15 /boot 有 vmlinuz 与 grub/"
		else
			bad "fb-15 /boot 缺 vmlinuz 或 grub/（p1 内容不对 ⇒ 引导不可持续）"
		fi
	fi

	# ---- fb-16 引导链（证据源是 p1 上的 phase1-boot.log，不是 dmesg）----
	# 为什么不用 dmesg：那行是 /init echo 到 /dev/console 的，走 tty 驱动、不进 printk 环形缓冲，
	# 在 dmesg 里找它会让健康设备必然假 FAIL（2026-11-07 复核指出）。
	if have boot_log; then
		if grep -q 'switching root upperdir=/overlay/upper' "${DIR}/boot_log" 2>/dev/null; then
			ok "fb-16 phase1-boot.log 有 switching root upperdir=/overlay/upper（引导链走完了）"
		else
			bad "fb-16 phase1-boot.log 里没有 switching root 行（没走到切根，或日志被截断）"
		fi
		if grep -q 'FAIL stage=' "${DIR}/boot_log" 2>/dev/null; then
			bad "fb-16 phase1-boot.log 里有失败记录：$(grep -m1 'FAIL stage=' "${DIR}/boot_log" 2>/dev/null)"
		else
			ok "fb-16 phase1-boot.log 里没有 FAIL stage="
		fi
	fi
	if have dmesg_tail; then
		if grep -q 'no usable overlay filesystem found' "${DIR}/dmesg_tail" 2>/dev/null; then
			bad "fb-16 dmesg 出现 ramoverlay 告警（写层可能落在 tmpfs）"
		else
			ok "fb-16 dmesg 无 ramoverlay 告警"
		fi
	fi

	# ---- fb-17 grow 日志 ----
	if have grow_log; then
		if grep -q '10-grow-p2' "${DIR}/grow_log" 2>/dev/null; then
			if grep -q '10-grow-p2: FAIL:' "${DIR}/grow_log" 2>/dev/null; then
				bad "fb-17 /boot/phase1-grow.log 里有 FAIL 行（扩容失败，下次开机会重试）"
			elif grep -q '10-grow-p2: done' "${DIR}/grow_log" 2>/dev/null || grep -q 'already-full' "${DIR}/grow_log" 2>/dev/null; then
				ok "fb-17 grow 日志有结论行（done / already-full）"
			else
				bad "fb-17 grow 日志没有结论行（既无 done 也无 already-full）"
			fi
		else
			bad "fb-17 grow 日志里没有 10-grow-p2 的痕迹（首启扩容脚本可能没跑）"
		fi
	fi

	return 0
}

case "${MODE}" in
	collected)
		[ -d "${DIR}" ] || { printf 'device-firstboot-verify: 证据目录不存在：%s\n' "${DIR}" >&2; exit 2; }
		printf '== device-firstboot-verify --collected %s（证据复核，不连设备）==\n' "${DIR}"
		assert_all
		;;
	*)
		if [ -z "${ROUTER}" ]; then
			pend '未设置 ROUTER=<user@host>（或 --router，或 --collected <证据目录>）'
		fi
		if [ -z "${OUT}" ]; then
			OUT='.workflow/assets/wrt-ab-artifacts/phase1-device-firstboot'
		fi
		SNAP=$(mktemp -d "${TMPDIR:-/tmp}/phase1-firstboot.XXXXXX") || pend '建不出临时抓取目录'
		collect
		DIR=${SNAP}
		assert_all
		;;
esac

if [ "${FAIL}" = 0 ]; then
	printf '\nDEVICE-FIRSTBOOT OK（%d 项检查）\n' "${NCHECK}"
	exit 0
fi
printf '\nDEVICE-FIRSTBOOT FAILED（%d 项检查，见上面的 FAIL）\n' "${NCHECK}"
exit 1
