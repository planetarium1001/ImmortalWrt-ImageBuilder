#!/bin/sh
# phase1/tools/device-verify.sh —— Phase 1 真机判据的机械化复核（ac-8 / ac-9 / ac-10 / ac-11 / ac-12 / ac-13 / ac-14）
#
# 两种模式
#   1) 默认（连设备）：假设**设备此刻正处于我方试跑根**（`/init` 合成并以 switch_root 切进去的那个根），
#      读完 /proc/mounts、/boot、/overlay/upper、dmesg、/boot/phase1-boot.log 后逐条断言。
#   2) --collected <DIR>（不连设备）：断言 DIR 下**已归档的证据文件**里含关键判据串。
#      每条都打印"哪个文件 + 哪个 grep"，用于"设备已回 live、证据已归档"时的复核。
#
# ⚠️ **不要在 live 系统上直接跑默认模式**：live 的 `/` 行是 `lowerdir=/,upperdir=/overlay/upper`（fstools extroot），
#    不含 `lowerdir=/lower`，因此 ac-8 会 FAIL —— **那是预期，不是缺陷**。脚本第一条 premise 检查就是为了
#    先把"你其实在 live 上"这件事点出来（本脚本绝不把 live 判成通过，见 .workflow/assets/…-bwc 的 §O.1 教训）。
#
# 用法
#   ROUTER=root@<device-ip> sh phase1/tools/device-verify.sh
#   sh phase1/tools/device-verify.sh --router root@<device-ip> --probe /root/.probe
#   sh phase1/tools/device-verify.sh --collected <证据目录>
#   ROUTER=local sh phase1/tools/device-verify.sh        # 直接在设备上跑（不 ssh）
#
# 退出码（与 shell/tests/all.sh 的约定一致）
#   0  全部通过 → 末行 DEVICE-VERIFY OK
#   1  有 FAIL   → 末行 DEVICE-VERIFY FAILED
#   2  未给 ROUTER（或连不上） → 打印 PEND，末行 DEVICE-VERIFY PEND（all.sh 记为 PEND，不算失败）
#
# 参数（都有默认值；试跑根的子卷名可在装机几何变化时覆盖）
#   --router USER@HOST   = 环境变量 ROUTER；`local` 表示就在本机（设备自检）跑，不走 ssh
#   --collected DIR      证据复核模式（不连设备）；默认按 r2 证据表断言，--collect-set r3 切到第三轮
#   --scan               配合 --collected：指定文件缺失时退化为"在整个目录里找"，并报告命中的文件
#   --lower-subvol NAME  /rom 上应出现 `subvol=NAME`          （默认 @phase1-root）
#   --overlay-subvol NAME /overlay 上应出现 `subvol=NAME`     （默认 @phase1-overlay）
#   --probe PATH         写层探针的**系统内路径**（默认 /root/.phase1-ac9-probe）
#   --keep               保留抓取到的快照目录（排障用）
#   -h | --help
#
# 判据为什么这么写（都是真机踩出来的）
#   * `/` 行必须**同时**含 `lowerdir=/lower` 与 `upperdir=/overlay/upper`：live extroot 也有 upperdir=/overlay/upper，
#     只判 upperdir 会把 live 误判成通过（判据与 live 区分，见 brief 补充约定 4）。
#   * `/rom` 必须是基座子卷且 **ro**：overlay lower 只读是语义地基。
#   * `/boot` 必须能看到 `vmlinuz` 与 `grub`：真机 p1 根下是 `boot/`、`efi/`，live 的 /boot 是 `p1:/boot`
#     （79_move_config 先挂 p1 根再 bind 子目录）；若 /init 把 p1 根当 /boot，这里会看到 `boot`/`efi` 而不是
#     `vmlinuz`/`grub` —— 这正是第一轮 F-1 的可观测面。
#   * 探针与 nano 必须在 `/overlay/upper` 里且**跨重启仍在**：这是"写入落独立写层、没被 tmpfs 顶掉"的唯一判据。
#   * dmesg 里不能出现内核的 `no usable overlay filesystem found, using tmpfs overlay`（ramoverlay 假阳性），
#     且必须有本仓库补丁的 `80_mount_root: skip fstools mount_root`（否则写层会被 fstools 再叠一层 tmpfs）。
#   * `/boot/phase1-boot.log` 里要有 `switching root upperdir=/overlay/upper`（切根成功）与
#     `recovery: removed …try-phase1`（试跑标记被**真正删掉**；ac-12/ac-14 的核心，
#     若写成 `no marker` 就说明标记路径又错位了 —— 第一轮 F-1 就是这么暴露的）。
set -u

ROUTER="${ROUTER:-}"
MODE='device'
DIR=''
CSET='r2'
REQ_COMPRESS=0
SCAN=0
KEEP=0
LOWER_SUBVOL='@phase1-root'
OVERLAY_SUBVOL='@phase1-overlay'
PROBE='/root/.phase1-ac9-probe'
# 远端命令一律走这条（不读用户 ssh_config；BatchMode 防止在无人值守时卡在密码提示）
SSHOPT='-o ControlPath=none -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes'

FAIL=0
NCHECK=0
PREMISE=0
SNAP=''

ok()  { NCHECK=$((NCHECK + 1)); printf '  ok   %s\n' "$*"; }
bad() { NCHECK=$((NCHECK + 1)); FAIL=1; printf '  FAIL %s\n' "$*"; }
info() { printf '  ..   %s\n' "$*"; }
skip() { # <id> <描述>：前提不成立时不做结论（不计数，但整体已经因 premise 判 FAIL）
	printf '  skip %s %s（前提不成立：本机不是我方试跑根，这条不构成证据）\n' "$1" "$2"
}

usage() {
	cat <<'USAGE'
phase1/tools/device-verify.sh —— Phase 1 真机判据的机械化复核（ac-8/9/10/11/12/13/14）

用法：
  ROUTER=root@<ip> sh phase1/tools/device-verify.sh [选项]     # 设备此刻在**我方试跑根**里
  sh phase1/tools/device-verify.sh --collected <证据目录>      # 不连设备，复核已归档证据
  ROUTER=local     sh phase1/tools/device-verify.sh            # 在设备本机跑（不 ssh）

⚠️ 不要在 live 系统上直接跑默认模式：live 的 / 行是 lowerdir=/,upperdir=/overlay/upper（fstools extroot），
   不含 lowerdir=/lower ⇒ ac-8 会 FAIL。那是**预期结果**，不是缺陷；第一行 premise 检查会直接点明你在 live 上。

选项：
  --router USER@HOST    同环境变量 ROUTER；`local` = 本机自检
  --collected DIR       证据复核模式（不连设备，逐条列出"文件 + grep"）
  --scan                --collected 时允许在整目录里找（指定文件缺失时）
  --collect-set r2|r3   --collected 的证据集合：r2 = 第二轮（/init a9be00db…），r3 = 第三轮（b65c8625…）
  --require-compress    额外要求 rw 子卷（/overlay、/opt/docker、/swap）的行里有 compress=zstd:1（M4 面）
  --lower-subvol NAME   /rom 行的 subvol（默认 @phase1-root）
  --overlay-subvol NAME /overlay 行的 subvol（默认 @phase1-overlay）
  --probe PATH          写层探针系统内路径（默认 /root/.phase1-ac9-probe）
  --keep                保留快照目录
  -h, --help

退出码：0 = DEVICE-VERIFY OK；1 = DEVICE-VERIFY FAILED；2 = PEND（未设 ROUTER / 连不上）
USAGE
}

# ---- 参数 ----------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--router) [ $# -ge 2 ] || { printf 'device-verify: --router 缺值\n' >&2; exit 2; }; ROUTER=$2; shift 2 ;;
		--router=*) ROUTER=${1#*=}; shift ;;
		--collected) [ $# -ge 2 ] || { printf 'device-verify: --collected 缺目录\n' >&2; exit 2; }; MODE='collected'; DIR=$2; shift 2 ;;
		--collected=*) MODE='collected'; DIR=${1#*=}; shift ;;
		--scan) SCAN=1; shift ;;
		--collect-set) [ $# -ge 2 ] || { printf 'device-verify: --collect-set 缺值（r2|r3）\n' >&2; exit 2; }; CSET=$2; shift 2 ;;
		--collect-set=*) CSET=${1#*=}; shift ;;
		--require-compress) REQ_COMPRESS=1; shift ;;
		--lower-subvol) [ $# -ge 2 ] || exit 2; LOWER_SUBVOL=$2; shift 2 ;;
		--lower-subvol=*) LOWER_SUBVOL=${1#*=}; shift ;;
		--overlay-subvol) [ $# -ge 2 ] || exit 2; OVERLAY_SUBVOL=$2; shift 2 ;;
		--overlay-subvol=*) OVERLAY_SUBVOL=${1#*=}; shift ;;
		--probe) [ $# -ge 2 ] || exit 2; PROBE=$2; shift 2 ;;
		--probe=*) PROBE=${1#*=}; shift ;;
		--keep) KEEP=1; shift ;;
		*) printf 'device-verify: 未知参数 %s（见 --help）\n' "$1" >&2; exit 2 ;;
	esac
done

cleanup() {
	if [ -n "$SNAP" ] && [ "$KEEP" = 0 ] && [ -d "$SNAP" ]; then
		rm -rf "$SNAP"
	fi
	return 0
}
trap 'cleanup; exit 1' INT TERM
trap cleanup EXIT

# =========================================================================
# 模式 2：--collected（证据复核，不连设备）
# =========================================================================
cf() { # <id> <描述> <文件basename> <固定串>：文件里必须出现该固定串
	_f="$DIR/$3"
	if [ ! -f "$_f" ]; then
		if [ "$SCAN" = 1 ]; then
			_hit=''
			for _g in "$DIR"/*; do
				[ -f "$_g" ] || continue
				if grep -qF -- "$4" "$_g" 2>/dev/null; then _hit=${_g##*/}; break; fi
			done
			if [ -n "$_hit" ]; then
				ok "$1 $2  [扫描命中 ${_hit}: $4]"
			else
				bad "$1 $2  [整个 $DIR 都没有: $4]"
			fi
			return 0
		fi
		bad "$1 $2  [缺证据文件 $3]"
		return 0
	fi
	if grep -qF -- "$4" "$_f" 2>/dev/null; then
		ok "$1 $2  [$3: $4]"
	else
		bad "$1 $2  [$3 不含: $4]"
	fi
	return 0
}

cfn() { # <id> <描述> <文件basename> <固定串>：文件里**不许**出现该固定串
	_f="$DIR/$3"
	if [ ! -f "$_f" ]; then
		bad "$1 $2  [缺证据文件 $3]"
		return 0
	fi
	if grep -qF -- "$4" "$_f" 2>/dev/null; then
		bad "$1 $2  [$3 出现了不该有的: $4]"
	else
		ok "$1 $2  [$3 无 '$4']"
	fi
	return 0
}

run_collected() {
	[ -d "$DIR" ] || { printf 'device-verify: 目录不存在：%s\n' "$DIR" >&2; exit 2; }
	printf '== device-verify --collected %s （证据复核，不连设备）==\n' "$DIR"

	# 证据文件（本工作区 evidence/ 下的归档件；第一轮 0x-*.txt，第二轮 2x-r2-*.txt）
	F_PREM='20-r2-ac14-trial1.txt'      # 第二轮：按文档路径放标记的试跑启动快照
	F_AC9='21-r2-ac9-before-reboot.txt'  # 第二轮：写探针后的证据
	F_R2='22-r2-ac10-ac11-regress.txt'   # 第二轮：重启后（ac-10/ac-11/ac-13 复验）
	F_AC12='23-r2-ac12-autorecover.txt'  # 第二轮：故意失败 → 自动回 live
	F_AC13='04-ac13-install.txt'         # 第一轮：装包即刻（nano 不在基座）
	F_AC14='20-r2-ac14-trial1.txt'       # 同 F_PREM

	cf 'ac-8p' '本条前提取用（本机确实是我方合成根，不是 live）' "$F_PREM" 'rdinit=/init phase1_dev=/dev/nvme0n1p3'
	cf 'ac-8a' '/ 行是 overlay 且同时含 lowerdir=/lower 与 upperdir=/overlay/upper' "$F_PREM" 'lowerdir=/lower,upperdir=/overlay/upper'
	cf 'ac-8b' '/rom 上是基座子卷且以 ro 挂载' "$F_PREM" '/rom btrfs ro,noatime'
	cf 'ac-8c' '/rom 的子卷名是 @phase1-root' "$F_PREM" 'subvol=/@phase1-root'
	cf 'ac-8d' '/overlay 是独立写层子卷 @phase1-overlay（rw）' "$F_PREM" 'subvol=/@phase1-overlay'
	cf 'ac-8e' '/boot 已挂载（p1 vfat）' "$F_PREM" '/dev/nvme0n1p1 /boot vfat rw'
	cf 'ac-8f' '/boot 视图是 p1:/boot（看得到 vmlinuz，而不是 p1 根的 boot//efi/）' "$F_PREM" 'vmlinuz'
	cf 'ac-9'  '写探针出现在 /overlay/upper（写层生效）' "$F_AC9" '/overlay/upper/root/.r2-probe'
	cf 'ac-10' '探针跨重启存活且内容不变（sha256 一致）' "$F_R2" '60ec5ec635066a05d843e8ec718763b6a7f511fdffde16f8ac3e461a4391ce94  /root/.r2-probe'
	cf 'ac-10b' 'uci 改动跨重启存活（/etc/config/system sha256 不变）' "$F_R2" '8866e10149638de20fc10c9789bd909d88e9acfd0838a6929dc31b6b4d142d50  /etc/config/system'
	cfn 'ac-11a' 'dmesg 无 ramoverlay 特征日志（no usable overlay … using tmpfs overlay）' "$F_R2" 'using tmpfs overlay'
	cfn 'ac-11a2' '第一轮证据里同样没有 using tmpfs overlay 那一行' "$F_PREM" 'using tmpfs overlay'
	cf 'ac-11b' 'dmesg 有 80_mount_root 的 skip fstools mount_root 记录' "$F_R2" '80_mount_root: skip fstools mount_root'
	cf 'ac-13a' '装包后 /overlay/upper/usr/bin/nano 存在（写层而非基座）' "$F_AC13" '/overlay/upper/usr/bin/nano'
	cf 'ac-13b' 'nano 可运行' "$F_AC13" 'GNU nano, version 9.3'
	cf 'ac-13c' '基座 /rom 上没有 nano（证明来自写层）' "$F_AC13" 'ls: /rom/usr/bin/nano: No such file or directory'
	cf 'ac-13d' 'nano 跨重启仍在且 sha256 不变' "$F_R2" '5e02e58b40734204750f74abd89ba05d868faba7ecb3af448e1804ccb80225f9  /overlay/upper/usr/bin/nano'
	cf 'ac-14a' 'boot log 有切根成功行 switching root upperdir=/overlay/upper' "$F_AC14" 'switching root upperdir=/overlay/upper'
	cf 'ac-14b' '按文档路径放的标记被 /init 读到（info marker present）' "$F_AC14" 'phase1-init: info marker present'
	cf 'ac-14c' '切根前标记被真正删除（removed /p1/boot/try-phase1）' "$F_AC14" 'recovery: removed /p1/boot/try-phase1'
	cf 'ac-14d' '启动后标记确实不存在（/boot/try-phase1）' "$F_AC14" 'ls: /boot/try-phase1: No such file or directory'
	cfn 'ac-14e' 'ac-14 的日志里没有 recovery: no marker（有它说明标记路径又错位）' "$F_AC14" 'recovery: no marker'
	cf 'ac-12a' '故意失败时日志是 FAIL stage=lower-mount' "$F_AC12" 'phase1-init: FAIL stage=lower-mount'
	cf 'ac-12b' '故意失败时标记仍被真正删除（不是 no marker）' "$F_AC12" 'recovery: removed /p1/boot/try-phase1'
	cfn 'ac-12c' '故意失败的日志里**没有** no marker 这种漏删痕迹' "$F_AC12" 'recovery: no marker'
	cf 'ac-12d' '失败后设备自动回 live（/ 行 = fstools extroot）' "$F_AC12" 'overlayfs:/overlay / overlay rw,noatime,lowerdir=/'

	finish
}

# 第三轮（最终 initrd /init b65c8625…）的证据表；文件名与第二轮不同，判据完全一致。
run_collected_r3() {
	[ -d "$DIR" ] || { printf 'device-verify: 目录不存在：%s\n' "$DIR" >&2; exit 2; }
	printf '== device-verify --collected %s （证据复核 · 第三轮/最终版）==\n' "$DIR"

	F_A='30-r3-A-load.txt'        # A 轮：装载与压缩（启动快照）
	F_AV='37-r3-A-device-verify.txt'
	F_B='39-r3-B-after-reboot.txt' # B 轮：重启后复验
	F_C='40-r3-C-autorecover.txt'  # C 轮：故意失败 → 自动回 live
	F_N='04-ac13-install.txt'      # 基座无 nano（第一轮试跑根证据；基座内容未变）

	cf 'ac-8p' '本条前提取用（本机确实是我方合成根，不是 live）' "$F_A" 'rdinit=/init phase1_dev=/dev/nvme0n1p3'
	cf 'ac-8a' '/ 行是 overlay 且同时含 lowerdir=/lower 与 upperdir=/overlay/upper' "$F_A" 'lowerdir=/lower,upperdir=/overlay/upper'
	cf 'ac-8b' '/rom 上是基座子卷且以 ro 挂载' "$F_A" '/rom btrfs ro,noatime'
	cf 'ac-8c' '/rom 的子卷名是 @phase1-root' "$F_A" 'subvol=/@phase1-root'
	cf 'ac-8d' '/overlay 是独立写层子卷 @phase1-overlay' "$F_A" 'subvol=/@phase1-overlay'
	cf 'ac-8e' '/boot 已挂载（p1 vfat）' "$F_B" '/dev/nvme0n1p1 /newroot/boot vfat rw'
	cf 'ac-8f' '/boot 视图是 p1:/boot（看得到 vmlinuz）' "$F_A" 'vmlinuz'
	cf 'ac-9'  '写探针出现在 /overlay/upper' "$F_A" '/overlay/upper/root/.phase1-ac9-probe'
	cf 'ac-10' '探针跨重启存活且 sha256 不变' "$F_B" 'd01b55cc4074c18e394a2a12d26baa5a7e23cdcc3b1df0d86c77bac7caa139b9  /root/.r3-probe'
	cf 'ac-10b' 'uci 改动跨重启存活（sha256 不变）' "$F_B" 'b5424602caef3bee038ec78d770984924f966fe29503377b305fe0e936f972fd  /etc/config/system'
	cfn 'ac-11a' 'dmesg 无 ramoverlay 特征（using tmpfs overlay）' "$F_B" 'using tmpfs overlay'
	cf 'ac-11b' 'dmesg 有 80_mount_root 的 skip fstools mount_root' "$F_A" '80_mount_root: skip fstools mount_root'
	cf 'ac-13a' '写层里有 /overlay/upper/usr/bin/nano' "$F_B" '/overlay/upper/usr/bin/nano'
	cf 'ac-13b' 'nano 可运行' "$F_B" 'GNU nano, version 9.3'
	cf 'ac-13c' '基座 /rom 上没有 nano（证明来自写层）' "$F_N" 'ls: /rom/usr/bin/nano: No such file or directory'
	cf 'ac-13d' 'nano 跨重启仍在且 sha256 不变' "$F_B" '5e02e58b40734204750f74abd89ba05d868faba7ecb3af448e1804ccb80225f9  /overlay/upper/usr/bin/nano'
	cf 'ac-14a' 'boot log 有 switching root upperdir=/overlay/upper' "$F_A" 'switching root upperdir=/overlay/upper'
	cf 'ac-14b' '按文档路径放的标记被 /init 读到（info marker present）' "$F_A" 'phase1-init: info marker present'
	cf 'ac-14c' '切根前标记被真正删除（removed /p1/boot/try-phase1）' "$F_A" 'recovery: removed /p1/boot/try-phase1'
	cf 'ac-14d' '启动后标记确实不存在' "$F_B" 'ls: /boot/try-phase1: No such file or directory'
	cfn 'ac-14e' '日志里没有 recovery: no marker' "$F_A" 'recovery: no marker'
	cf 'ac-12a' '故意失败时日志是 FAIL stage=lower-mount' "$F_C" 'phase1-init: FAIL stage=lower-mount'
	cf 'ac-12b' '故意失败时标记仍被真正删除（不是 no marker）' "$F_C" 'recovery: removed /p1/boot/try-phase1'
	cfn 'ac-12c' '故意失败的日志里没有 recovery: no marker' "$F_C" 'recovery: no marker'
	cf 'ac-12d' '失败后设备自动回 live（/ 行 = fstools extroot）' "$F_C" 'overlayfs:/overlay / overlay rw,noatime,lowerdir=/'

	finish
}

# =========================================================================
# 模式 1（默认）：连设备抓快照，再本地逐条断言
# =========================================================================
rsh() { # <远端命令>  → stdout
	if [ "$ROUTER" = 'local' ]; then
		sh -c "$1" 2>&1
	else
		# shellcheck disable=SC2086
		ssh $SSHOPT "$ROUTER" "$1" 2>&1
	fi
	return $?
}

grab() { # <远端命令> <本地文件>：把远端输出落盘（不改 rc，内容为空也照样写文件）
	rsh "$1" >"$2" 2>&1
	return 0
}

run_device() {
	[ -n "$ROUTER" ] || pend '未设置 ROUTER=<user@host>（或 --router）'
	rsh 'true' >/dev/null 2>&1 || pend "连不上 ${ROUTER}（或密钥未授权）"

	SNAP=$(mktemp -d "${TMPDIR:-/tmp}/device-verify.XXXXXX") || { printf 'device-verify: mktemp 失败\n' >&2; exit 1; }
	printf '== device-verify（目标 %s，假设本机处于我方试跑根）==\n' "$ROUTER"

	grab 'cat /proc/cmdline'                        "$SNAP/cmdline"
	grab 'cat /proc/mounts'                          "$SNAP/mounts"
	grab 'ls /boot'                                  "$SNAP/boot-ls"
	grab 'find /overlay/upper -type f'               "$SNAP/upper"
	grab 'cat /boot/phase1-boot.log'                 "$SNAP/bootlog"
	grab 'dmesg'                                     "$SNAP/dmesg"
	grab 'if [ -e /boot/try-phase1 ]; then echo present; else echo absent; fi' "$SNAP/marker"
	grab 'if [ -e /rom/usr/bin/nano ]; then echo present; else echo absent; fi' "$SNAP/rom-nano"
	grab 'nano --version 2>/dev/null | head -1'      "$SNAP/nano-version"

	# --- premise：先确认"你确实在我方合成根里"，避免把 live 判成通过 ---
	if grep -qF 'rdinit=/init' "$SNAP/cmdline" && grep -qF 'phase1_dev=' "$SNAP/cmdline"; then
		PREMISE=1
		ok 'premise 本机是我方试跑根（cmdline 有 rdinit=/init 与 phase1_dev=）'
	else
		bad 'premise 本机**不是**我方试跑根（cmdline 无 rdinit=/init + phase1_dev=）'
		info "cmdline: $(head -1 "$SNAP/cmdline")"
		info '若设备在 live 上：这是预期结果（见 --help 的警告），请先用 /boot/try-phase1 标记进试跑根'
	fi

	# --- ac-8a：/ 行 overlay + lowerdir=/lower + upperdir=/overlay/upper ---
	if awk '
		$2 == "/" && $3 == "overlay" {
			ld = 0; ud = 0
			n = split($4, a, ",")
			for (i = 1; i <= n; i++) {
				if (a[i] ~ /^lowerdir=/) {
					v = substr(a[i], 10)
					if (v == "/lower" || substr(v, 1, 7) == "/lower:") ld = 1
				}
				if (a[i] ~ /^upperdir=/) { if (substr(a[i], 10) == "/overlay/upper") ud = 1 }
			}
			if (ld && ud) found = 1
		}
		END { exit !found }
	' "$SNAP/mounts"; then
		ok "ac-8a / 行是 overlay 且同时含 lowerdir=/lower 与 upperdir=/overlay/upper"
	else
		bad 'ac-8a / 行不满足（overlay + lowerdir=/lower + upperdir=/overlay/upper 三者同时）'
		info "实际: $(awk '$2=="/"{print}' "$SNAP/mounts")"
	fi

	# --- ac-8b/c：/rom 是基座子卷且 ro ---
	if awk -v want="$LOWER_SUBVOL" '
		$2 == "/rom" && $3 == "btrfs" {
			ro = 0; sv = 0
			n = split($4, a, ",")
			for (i = 1; i <= n; i++) {
				if (a[i] == "ro") ro = 1
				if (a[i] ~ /^subvol=/) {
					v = substr(a[i], 8)
					sub(/^\//, "", v)
					if (v == want) sv = 1
				}
			}
			if (ro && sv) found = 1
		}
		END { exit !found }
	' "$SNAP/mounts"; then
		ok "ac-8b /rom 是 btrfs 子卷 ${LOWER_SUBVOL} 且以 ro 挂载"
	else
		bad "ac-8b /rom 不是 btrfs 子卷 ${LOWER_SUBVOL} 的 ro 挂载"
		info "实际: $(awk '$2=="/rom"{print}' "$SNAP/mounts")"
	fi

	# --- ac-8c：/overlay 是独立写层子卷且 rw ---
	if awk -v want="$OVERLAY_SUBVOL" '
		$2 == "/overlay" && $3 == "btrfs" {
			rw = 0; sv = 0
			n = split($4, a, ",")
			for (i = 1; i <= n; i++) {
				if (a[i] == "rw") rw = 1
				if (a[i] ~ /^subvol=/) {
					v = substr(a[i], 8)
					sub(/^\//, "", v)
					if (v == want) sv = 1
				}
			}
			if (rw && sv) found = 1
		}
		END { exit !found }
	' "$SNAP/mounts"; then
		ok "ac-8c /overlay 是独立写层子卷 ${OVERLAY_SUBVOL}（rw）"
	else
		bad "ac-8c /overlay 不是 btrfs 子卷 ${OVERLAY_SUBVOL} 的 rw 挂载"
		info "实际: $(awk '$2=="/overlay"{print}' "$SNAP/mounts")"
	fi

	# --- M4（可选，--require-compress）：rw 子卷的挂载选项里必须有 compress=zstd:1 ---
	# 为什么要单独一个开关：btrfs 的挂载参数是 **superblock 级**的，只有"第一次挂载该 fs"时带上的才生效；
	# /init 第一次挂的是 /lower（ro,noatime，无 compress）⇒ 后续 @overlay 的 compress=zstd:1 会被静默忽略
	# （rc=0、无 dmesg、/proc/mounts 不出现）。真机 2026-11-07 实测：/proc/mounts 无该项，且写 100MiB 零
	# 物理占用 +105,054,208B（compress=zstd:1 remount 后同样数据只占 3,571,712B）。这条就是验它的。
	if [ "$REQ_COMPRESS" = 1 ]; then
		for _mp in /overlay /opt/docker /swap; do
			if awk -v mp="$_mp" '
				$2 == mp && $3 == "btrfs" {
					n = split($4, a, ",")
					for (i = 1; i <= n; i++) if (a[i] == "compress=zstd:1") found = 1
				}
				END { exit !found }
			' "$SNAP/mounts"; then
				ok "m4 ${_mp} 行带 compress=zstd:1"
			else
				bad "m4 ${_mp} 行没有 compress=zstd:1（写层不压缩）"
				info "实际: $(awk -v mp="$_mp" '$2==mp{print}' "$SNAP/mounts")"
			fi
		done
	fi

	# --- ac-14-5：/boot 是 p1:/boot 视图（看得到 vmlinuz+grub，看不到 boot//efi/）---
	if grep -qxF 'vmlinuz' "$SNAP/boot-ls" && grep -qxF 'grub' "$SNAP/boot-ls"; then
		if grep -qxF 'efi' "$SNAP/boot-ls"; then
			bad 'ac-14-5 /boot 视图是 p1 根（看得到 efi/），不是 p1:/boot（F-1 回归了？）'
			info "ls /boot: $(tr '\n' ' ' <"$SNAP/boot-ls")"
		else
			ok 'ac-14-5 /boot 视图 = p1:/boot（vmlinuz、grub 可见，无 efi/）'
		fi
	else
		bad 'ac-14-5 /boot 不是 p1:/boot 视图（缺 vmlinuz 或 grub）'
		info "ls /boot: $(tr '\n' ' ' <"$SNAP/boot-ls")"
	fi

	# 以下检查只有在"本机确实是我们的合成根"时才构成证据（否则 live 上也会"看起来对"）
	if [ "$PREMISE" != 1 ]; then
		skip 'ac-9/ac-13' '写层探针与 nano'
		skip 'ac-11' 'dmesg 的 ramoverlay / 80_mount_root'
		skip 'ac-14' 'boot log 的切根与标记删除'
		finish
	fi

	# --- ac-9 / ac-13：写层里必须有探针与 nano，且 nano 不来自基座 ---
	_rel=$PROBE
	case "$_rel" in /*) ;; *) _rel="/$_rel" ;; esac
	if grep -qxF "/overlay/upper${_rel}" "$SNAP/upper"; then
		ok "ac-9 写层探针在 /overlay/upper${_rel}（写入落独立写层）"
	else
		bad "ac-9 写层里没有探针 /overlay/upper${_rel}"
		info '（用 --probe 指定实际探针路径；试跑根里先 echo x > 该路径再复跑本项）'
	fi
	if grep -qxF '/overlay/upper/usr/bin/nano' "$SNAP/upper"; then
		ok 'ac-13a 写层里有 /overlay/upper/usr/bin/nano（包在写层，不在基座）'
		if grep -q 'absent' "$SNAP/rom-nano"; then
			ok 'ac-13b 基座 /rom 上没有 nano（确认来自写层）'
		else
			bad 'ac-13b 基座 /rom 上也有 nano ⇒ 无法证明包落在写层'
		fi
		if grep -qi 'nano' "$SNAP/nano-version"; then
			ok "ac-13c nano 可运行（$(head -1 "$SNAP/nano-version"))"
		else
			bad 'ac-13c nano --version 没有输出'
		fi
	else
		bad 'ac-13a 写层里没有 /overlay/upper/usr/bin/nano（先在试跑根里 apk add nano）'
	fi

	# --- ac-11：dmesg 无 ramoverlay 特征，且有 80_mount_root 的 skip 记录 ---
	if grep -qiF 'using tmpfs overlay' "$SNAP/dmesg"; then
		bad 'ac-11a dmesg 出现 no usable overlay … using tmpfs overlay（ramoverlay 把写层顶成 tmpfs）'
		info "dmesg: $(grep -i 'tmpfs overlay' "$SNAP/dmesg" | head -1)"
	else
		ok 'ac-11a dmesg 无 ramoverlay 特征（no usable overlay … using tmpfs overlay）'
	fi
	if grep -qF '80_mount_root: skip fstools mount_root' "$SNAP/dmesg"; then
		ok 'ac-11b dmesg 有 80_mount_root: skip fstools mount_root（补丁生效）'
	else
		bad 'ac-11b dmesg 没有 80_mount_root 的 skip 记录'
		info '（基座里的 80_mount_root 必须是仓库补丁，见 phase1/README.md §6.1）'
	fi

	# --- ac-14 / ac-12：日志里的切根成功 + 标记被真正删除 ---
	if grep -qF 'switching root upperdir=/overlay/upper' "$SNAP/bootlog"; then
		ok 'ac-14a boot log 有 switching root upperdir=/overlay/upper'
	else
		bad 'ac-14a boot log 里没有 switching root upperdir=/overlay/upper'
		info "日志尾部: $(tail -2 "$SNAP/bootlog" | tr '\n' '|')"
	fi
	if awk '/recovery: removed/ && /try-phase1/ { found = 1 } END { exit !found }' "$SNAP/bootlog"; then
		ok 'ac-14b/ac-12 boot log 里有 recovery: removed …try-phase1（标记被真正删掉）'
	else
		bad 'ac-14b/ac-12 boot log 里没有 recovery: removed …try-phase1'
		info "实际: $(grep -F 'recovery:' "$SNAP/bootlog" | tail -1)"
	fi
	if grep -qF 'recovery: no marker' "$SNAP/bootlog"; then
		bad 'ac-14c boot log 出现 recovery: no marker（标记路径又错位了，会失去"失败只消耗一次"的保证）'
	else
		ok 'ac-14c boot log 里没有 recovery: no marker（标记路径正确）'
	fi
	if grep -q 'present' "$SNAP/marker"; then
		bad 'ac-14d 试跑标记仍然存在（/boot/try-phase1）⇒ 下次启动还会进试跑项'
		info '（出现这行说明标记没被消耗；在 live 上 rm /boot/try-phase1 即可回默认槽）'
	else
		ok 'ac-14d 试跑标记已被消耗（/boot/try-phase1 不存在）'
	fi

	finish
}

# ---- 收尾 ----------------------------------------------------------------
finish() {
	cleanup
	if [ "$FAIL" = 0 ]; then
		printf 'DEVICE-VERIFY OK（%d 项检查）\n' "$NCHECK"
		exit 0
	fi
	printf 'DEVICE-VERIFY FAILED（%d 项检查，见上面的 FAIL）\n' "$NCHECK"
	exit 1
}

pend() {
	printf 'PEND: %s\n' "$*"
	printf 'DEVICE-VERIFY PEND\n'
	exit 2
}

case "$MODE" in
	collected)
		case "$CSET" in
			r2) run_collected ;;
			r3) run_collected_r3 ;;
			*) printf 'device-verify: --collect-set 只支持 r2|r3（收到 %s）\n' "$CSET" >&2; exit 2 ;;
		esac
		;;
	*)         run_device ;;
esac
