#!/bin/sh
# phase1/tools/qemu-boot-check.sh —— 冷启动冒烟：证明"**整盘镜像真的能引导**到 switch_root"。
#
# 为什么需要它（2026-11-07 两次真机事故）：
#   ① 镜像只装了 i386-pc，纯 UEFI 固件直接落到 "UEFI Interactive Shell v2.2"；
#   ② @root 缺 /proc /sys /dev /tmp，起来后 netifd 枚举不到网口。
#   这两类缺陷的共同点是"**装配全对、静态自检全绿、但机器起不来/没网**"——只有真的启动一次才发现。
#   所以本脚本把"启动一次并检查关键行"做成门禁，CI 与本地共用。
#
# 两种模式
#   1) 真跑：--image FILE [--firmware uefi|bios] [--timeout N]
#      qemu 用 NVMe 控制器（贴合真实盘名 /dev/nvme0n1p2，避免"桩环境能起、真机起不来"）
#   2) 只判：--replay <serial.log> --boot-log <file>（离线复核，用例与排障用）
#
# 判据（缺任一条即 FAILED）
#   bs-1 p1 的 /boot/phase1-boot.log（**本次启动段**）出现 `switching root upperdir=/overlay/upper`
#   bs-2 串口日志出现内核 printk（`Linux version`）——证明内核真的接管了，不是卡在 GRUB
#   bs-3 该日志本次启动段没有 `FAIL stage=`（initramfs 没在某个阶段死掉）
#
# 退出码：0 = BOOT-SMOKE OK；1 = BOOT-SMOKE FAILED；2 = PEND（缺 qemu/ovmf/loop 能力）
set -u

IMAGE=''
FIRMWARE='uefi'
TIMEOUT=${BOOT_TIMEOUT:-180}
SERIAL_LOG=''
BOOT_LOG=''
GROW_LOG=''
QEMU=${QEMU:-qemu-system-x86_64}
REPLAY=0
KEEP=${KEEP:-0}
LOG_OUT=''
WORK=''

ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAIL=1; }
info() { printf '  ..   %s\n' "$*"; }
FAIL=0
NCHECK=0
okc() { NCHECK=$((NCHECK + 1)); ok "$@"; }
badc() { NCHECK=$((NCHECK + 1)); bad "$@"; }

usage() {
	cat <<'USAGE'
phase1/tools/qemu-boot-check.sh —— 整盘镜像冷启动冒烟；末行三态：BOOT-SMOKE OK / BOOT-SMOKE FAILED / BOOT-SMOKE PEND

用法：
  sh phase1/tools/qemu-boot-check.sh --image <phase1.img> [--firmware uefi|bios] [--timeout 180]
  sh phase1/tools/qemu-boot-check.sh --replay <serial.log> --boot-log <phase1-boot.log>   # 只判，不启动

判据：
  bs-1 p1 /boot/phase1-boot.log（本次启动段）含 switching root upperdir=/overlay/upper
  bs-2 串口日志含内核 printk（Linux version）
  bs-3 该日志本次启动段无 FAIL stage=

退出码：0 = OK；1 = FAILED；2 = PEND（缺 qemu-system-x86 / OVMF / losetup 权限）
其它：--log-out DIR 把 serial.log / qemu.out / p1 日志拷到该目录（CI 进 artifact，失败可排障）
环境：QEMU=<qemu 可执行文件>、OVMF=<OVMF 固件>、BOOT_TIMEOUT=<秒>
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	--image) [ $# -ge 2 ] || { printf 'qemu-boot-check: --image 缺值\n' >&2; exit 2; }; IMAGE=$2; shift 2 ;;
	--image=*) IMAGE=${1#*=}; shift ;;
	--firmware) [ $# -ge 2 ] || exit 2; FIRMWARE=$2; shift 2 ;;
	--firmware=*) FIRMWARE=${1#*=}; shift ;;
	--timeout) [ $# -ge 2 ] || exit 2; TIMEOUT=$2; shift 2 ;;
	--timeout=*) TIMEOUT=${1#*=}; shift ;;
	--replay) [ $# -ge 2 ] || exit 2; SERIAL_LOG=$2; REPLAY=1; shift 2 ;;
	--replay=*) SERIAL_LOG=${1#*=}; REPLAY=1; shift ;;
	--boot-log) [ $# -ge 2 ] || exit 2; BOOT_LOG=$2; shift 2 ;;
	--boot-log=*) BOOT_LOG=${1#*=}; shift ;;
	--log-out) [ $# -ge 2 ] || exit 2; LOG_OUT=$2; shift 2 ;;
	--log-out=*) LOG_OUT=${1#*=}; shift ;;
	--log-out) [ $# -ge 2 ] || exit 2; LOG_OUT=$2; shift 2 ;;
	--log-out=*) LOG_OUT=${1#*=}; shift ;;
	*) printf 'qemu-boot-check: 未知参数 %s（见 --help）\n' "$1" >&2; exit 2 ;;
	esac
done

cleanup() {
	# 先把现场拷到 --log-out（CI 的 artifact 目录），再清临时目录：
	# 失败时 serial.log / qemu.out 是唯一能定位"卡在 GRUB 还是内核还是 init"的东西，不能随 mktemp 一起消失。
	if [ -n "${LOG_OUT}" ] && [ -d "${WORK}" ]; then
		mkdir -p "${LOG_OUT}" 2>/dev/null || true
		[ -f "${WORK}/serial.log" ] && cp "${WORK}/serial.log" "${LOG_OUT}/serial-${FIRMWARE}.log" 2>/dev/null || true
		[ -f "${WORK}/qemu.out" ] && cp "${WORK}/qemu.out" "${LOG_OUT}/qemu-${FIRMWARE}.out" 2>/dev/null || true
		[ -f "${WORK}/phase1-boot.log" ] && cp "${WORK}/phase1-boot.log" "${LOG_OUT}/phase1-boot-${FIRMWARE}.log" 2>/dev/null || true
		[ -f "${WORK}/qemu-debug.log" ] && cp "${WORK}/qemu-debug.log" "${LOG_OUT}/qemu-debug-${FIRMWARE}.log" 2>/dev/null || true
	fi
	if [ -n "${WORK}" ] && [ -d "${WORK}" ] && [ "$KEEP" = 0 ]; then rm -rf "${WORK}"; fi
	return 0
}
trap cleanup EXIT

pend() { printf 'PEND: %s\n' "$*"; printf 'BOOT-SMOKE PEND\n'; exit 2; }

# ---------------------------------------------------------------- 判定（两种模式共用）
# 只看"本次启动"的段落：p1 上的日志是**仅追加**的（每次启动多一行 `=== phase1-init: start`），
# 而 CI 会对同一张镜像连跑两种固件 —— 不截断就会用上一轮的日志把这一轮判绿（假阳性）。
last_boot_section() { # <boot log>
	awk '/=== phase1-init: start/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$1" 2>/dev/null
}

judge() {
	printf '== 判据 ==\n'
	# bs-1 的证据源是 **p1 的 phase1-boot.log**，不是串口日志：
	#   `switching root upperdir=/overlay/upper` 这行是 /init 用 echo 写到 /dev/console 的（用户态），
	#   /dev/console 由 cmdline 上**最后一个** console= 决定（我们是 console=ttyS0… console=tty1），
	#   所以它只会进 tty1，永远不进 -serial file:。早期版本在串口里找它 ⇒ 健康镜像也必然 FAILED，
	#   而 Upload artifacts 是 if: success() ⇒ 连镜像产物都拿不到。这一版改读 p1 日志。
	if [ ! -f "$BOOT_LOG" ]; then
		badc "bs-1 缺 p1 引导日志：${BOOT_LOG}（/init 连 p1 都没挂上？）"
	else
		_section=$(last_boot_section "$BOOT_LOG")
		_starts=$(grep -c '=== phase1-init: start' "$BOOT_LOG" 2>/dev/null || true)
		info "p1 日志里共有 ${_starts:-0} 次启动记录（判据只看最后一次）"
		if printf '%s' "${_section}" | grep -q 'switching root upperdir=/overlay/upper'; then
			okc "bs-1 p1 日志本次启动段有 switching root upperdir=/overlay/upper"
		else
			badc "bs-1 p1 日志本次启动段没有 switching root（引导没走到切根）"
		fi
		if printf '%s' "${_section}" | grep -q 'FAIL stage='; then
			badc "bs-3 p1 日志本次启动段有失败记录：$(printf '%s' "${_section}" | grep -m1 'FAIL stage=')"
		else
			okc "bs-3 p1 日志本次启动段无 FAIL stage="
		fi
	fi

	# bs-2 串口侧只证明"内核真的起来过"：这行是 kernel printk（GRUB 之后、init 之前）。
	# **不再**用串口证明用户态行为（那是不可能的，见 bs-1 注释）。
	if [ ! -f "$SERIAL_LOG" ]; then
		badc "bs-2 缺串口日志：${SERIAL_LOG}"
	elif grep -qE 'Linux version [0-9]' "$SERIAL_LOG" 2>/dev/null; then
		okc "bs-2 串口日志有内核 printk（Linux version），内核已接管"
	else
		badc "bs-2 串口日志里没有 Linux version（qemu 根本没跑到内核？）"
	fi

	# bs-4 结果侧证据（不判 FAIL）：grow 日志是**用户态** uci-defaults 写的，
	# 它存在说明 procd/uci 真的跑起来了 —— 这是"用户态可用"最便宜的物证。
	if [ -n "${GROW_LOG}" ] && [ -f "$GROW_LOG" ]; then
		info "bs-4 见到 <p1>/boot/phase1-grow.log（用户态 uci-defaults 已跑过）"
	else
		info "bs-4 未见 phase1-grow.log（首启 uci-defaults 可能还没跑到；不作为失败）"
	fi

	printf '\n'
	if [ "$FAIL" = 0 ]; then
		printf 'BOOT-SMOKE OK（%d 项检查）\n' "$NCHECK"
		return 0
	fi
	printf 'BOOT-SMOKE FAILED（%d 项检查）\n' "$NCHECK"
	# 红了必须能排障：默认 cleanup 会删临时目录，这里先把现场尾巴打出来
	if [ -f "$SERIAL_LOG" ]; then
		_n=$(wc -l <"$SERIAL_LOG" 2>/dev/null | tr -d ' ')
		printf '\n-- 串口日志（%s 行）--\n' "${_n:-0}"
		if [ "${_n:-0}" -le 60 ] 2>/dev/null; then cat "$SERIAL_LOG" 2>/dev/null; else tail -40 "$SERIAL_LOG" 2>/dev/null; fi
	fi
	if [ -f "$BOOT_LOG" ]; then printf '\n-- p1 引导日志尾部 --\n'; tail -30 "$BOOT_LOG" 2>/dev/null; fi
	if [ -n "${WORK}" ] && [ -f "${WORK}/qemu.out" ]; then printf '\n-- qemu 输出尾部 --\n'; tail -20 "${WORK}/qemu.out" 2>/dev/null; fi
	if [ -n "${WORK}" ] && [ -f "${WORK}/qemu-debug.log" ]; then printf '\n-- qemu 内部日志尾部（-d guest_errors,int）--\n'; tail -25 "${WORK}/qemu-debug.log" 2>/dev/null; fi
	return 1
}

# ---------------------------------------------------------------- 只判模式
if [ "$REPLAY" = 1 ]; then
	printf '== qemu-boot-check --replay（只判，不启动）==\n'
	judge
	exit $?
fi

# ---------------------------------------------------------------- 真跑模式
[ -n "$IMAGE" ] || { printf 'qemu-boot-check: 需要 --image（或 --replay）\n' >&2; usage >&2; exit 2; }
[ -f "$IMAGE" ] || { printf 'qemu-boot-check: 镜像不存在：%s\n' "$IMAGE" >&2; exit 2; }
command -v "$QEMU" >/dev/null 2>&1 || pend "没有 ${QEMU}（Debian/Ubuntu: apt install qemu-system-x86）"
[ "$(uname -s)" = 'Linux' ] || pend "本脚本的真跑模式只在 Linux 上用（macOS 无 losetup/mount 能力）"
command -v losetup >/dev/null 2>&1 || pend "没有 losetup（需要 root 或 CAP_SYS_ADMIN）"

case "$FIRMWARE" in
	uefi)
		OVMF=${OVMF:-}
		if [ -z "$OVMF" ]; then
			for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
				[ -f "$c" ] && { OVMF=$c; break; }
			done
		fi
		[ -n "$OVMF" ] || pend "没找到 OVMF 固件（Debian/Ubuntu: apt install ovmf），无法测 UEFI 启动"
		;;
	bios) : ;;
	*) printf 'qemu-boot-check: --firmware 只支持 uefi|bios（收到 %s）\n' "$FIRMWARE" >&2; exit 2 ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/boot-smoke.XXXXXX") || pend "建不出临时目录"
SERIAL_LOG=$WORK/serial.log
BOOT_LOG=$WORK/phase1-boot.log
GROW_LOG=$WORK/phase1-grow.log
: >"$SERIAL_LOG"

# 用 NVMe 控制器起盘：initrd 里烘焙的默认设备是 /dev/nvme0n1p2，换 virtio 会让"设备名不匹配"的
# 缺陷在冒烟里被掩盖（真机是 NVMe）。
# -boot order=c：显式指定从硬盘起（不同固件默认值不一样，别靠默认）。
# bootindex=0：把这块盘放进固件启动候选（NVMe 上尤其重要）。
# -d guest_errors,int + -D：三重复位/非法指令这类"根本没跑到引导器"的情况只有 QEMU 自己看得到。
set -- -m 2048 -display none -serial "file:$SERIAL_LOG" -no-reboot \
	-boot order=c,menu=off \
	-d guest_errors,int -D "$WORK/qemu-debug.log" \
	-drive "file=$IMAGE,format=raw,if=none,id=d0,bootindex=0" \
	-device "nvme,serial=phase1smoke,drive=d0,bootindex=0"
if [ "$FIRMWARE" = 'uefi' ]; then
	set -- "$@" -bios "$OVMF"
fi
info "启动 qemu（${FIRMWARE}，最长 ${TIMEOUT}s）：$QEMU $*"
"$QEMU" "$@" >"$WORK/qemu.out" 2>&1 &
QPID=$!
_waited=0
while [ "$_waited" -lt "$TIMEOUT" ]; do
	if ! kill -0 "$QPID" 2>/dev/null; then break; fi
	if grep -qE 'Linux version [0-9]' "$SERIAL_LOG" 2>/dev/null; then
		# 再多等 15s 让 procd/uci-defaults 跑一段，然后收工
		sleep 15
		break
	fi
	sleep 2
	_waited=$((_waited + 2))
done
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

# 从镜像里取出 p1（几何固定：p1 = 扇区 2048 起、524288 扇区）读 /boot/phase1-boot.log
info "从镜像取 p1 的引导日志"
dd if="$IMAGE" of="$WORK/p1.img" bs=512 skip=2048 count=524288 2>/dev/null ||
	pend "从镜像抽 p1 失败（dd）"
LOOP=$(losetup --find --show --partscan "$WORK/p1.img" 2>/dev/null) ||
	pend "losetup 失败（需要 root/CAP_SYS_ADMIN？）"
mkdir -p "$WORK/mnt"
if mount -o ro "$LOOP" "$WORK/mnt" 2>/dev/null; then
	if [ -f "$WORK/mnt/boot/phase1-boot.log" ]; then
		cp "$WORK/mnt/boot/phase1-boot.log" "$BOOT_LOG"
		[ -f "$WORK/mnt/boot/phase1-grow.log" ] && cp "$WORK/mnt/boot/phase1-grow.log" "$GROW_LOG"
	else
		info "p1 上没有 boot/phase1-boot.log（/init 可能没跑到挂 p1）"
	fi
	umount "$WORK/mnt" 2>/dev/null || true
else
	info "挂 p1 失败（vfat 模块/权限？）"
fi
losetup -d "$LOOP" 2>/dev/null || true

printf '== qemu-boot-check（firmware=%s）==\n' "$FIRMWARE"
judge
