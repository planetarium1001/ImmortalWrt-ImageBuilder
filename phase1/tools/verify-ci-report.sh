#!/bin/sh
# phase1/tools/verify-ci-report.sh —— 复核 CI 里那份镜像自检报告（ac-2 / ac-3 / ac-4 的 dev-vs-prod）
#
# 为什么要有这个脚本：镜像的布局/内容判据只能在 Linux + root 上用 loop 挂载来验，
# 本机（macOS）跑不了。把"CI 里 phase1/tools/image-selfcheck.sh 的 PASS 报告"当**证据文件**，
# 再用本脚本在本地机械复核这份报告（缺项、FAIL、SELFCHECK 不是 OK 都直接非 0），
# 这样验收不依赖"人眼看一下 CI 绿了"。
#
# 用法：
#   sh phase1/tools/verify-ci-report.sh <report.txt> --mode dev|prod [--stage layout|content|devprod|boot]
#
# 默认 --stage all（= layout + content + devprod + "SELFCHECK OK 且无 FAIL"）。
# 引导冒烟是**另一份报告**（boot-smoke-<mode>-<fw>.txt，由 phase1/tools/qemu-boot-check.sh 产出），
# 所以 `--stage boot` 要单独跑一次，不并进 all（all 的输入是 selfcheck 报告，里面没有冒烟行）。
# 报告来源：CI 的 `Self-check image` 步骤日志，去掉时间戳前缀后形如
#   PASS  p1 = 256 MiB（524288 扇区）
#   ...
#   SELFCHECK OK（mode=prod）
set -u

PROG=phase1/tools/verify-ci-report.sh
REPORT=''
MODE=''
STAGE=all
FAILED=0

die() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case $1 in
	--mode)
		[ "$#" -ge 2 ] || die "--mode 需要值"
		MODE=$2
		shift 2
		;;
	--stage)
		[ "$#" -ge 2 ] || die "--stage 需要值"
		STAGE=$2
		shift 2
		;;
	-h | --help)
		sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		die "未知选项: $1"
		;;
	*)
		[ -z "$REPORT" ] || die "多余参数: $1"
		REPORT=$1
		shift
		;;
	esac
done

[ -n "$REPORT" ] || die "缺少报告文件（看 --help）"
[ -f "$REPORT" ] || die "报告不存在: ${REPORT}"
case $MODE in
dev | prod) ;;
'') die "必须给 --mode dev|prod" ;;
*) die "--mode 只接受 dev|prod" ;;
esac
case $STAGE in
layout | content | devprod | boot | all) ;;
*) die "--stage 只接受 layout|content|devprod|boot|all" ;;
esac

pass() { printf '  ok   %s\n' "$*"; }
bad() {
	printf '  FAIL %s\n' "$*"
	FAILED=1
}

# need <人类可读描述> <报告里必须出现的 PASS 行片段>
need() {
	if grep -q -- "$2" "$REPORT"; then
		pass "$1"
	else
		bad "$1（报告里没有: $2）"
	fi
}

# not_need <描述> <报告里不许出现的片段>
not_need() {
	if grep -q -- "$2" "$REPORT"; then
		bad "$1（报告里出现了: $2）"
	else
		pass "$1"
	fi
}

printf 'report: %s（mode=%s, stage=%s）\n' "$REPORT" "$MODE" "$STAGE"
printf '行数: %s\n' "$(grep -c '' "$REPORT" 2>/dev/null || echo 0)"

if [ "$STAGE" = layout ] || [ "$STAGE" = all ]; then
	printf '\n== 布局（ac-2）==\n'
	need "p1 = 256 MiB" "PASS  p1 = 256 MiB"
	need "p128 = 4 MiB / EF02" "PASS  p128 = 4 MiB / EF02"
	need "p2 占到盘尾" "PASS  p2 占到盘尾"
	need "物理顺序 p1 < p128 < p2（首启扩容的几何前提）" "PASS  物理顺序 p1 < p128 < p2"
	need "p1 = vfat" "PASS  p1 文件系统 = vfat"
	need "p2 = btrfs" "PASS  p2 文件系统 = btrfs"
	need "子卷恰为 @root @overlay @docker @swap" "PASS  子卷恰为 @root @overlay @docker @swap"
fi

if [ "$STAGE" = content ] || [ "$STAGE" = all ]; then
	printf '\n== 内容（ac-3）==\n'
	need "@/root/etc/openwrt_release 存在" "PASS  @root/etc/openwrt_release 存在"
	need "manifest 条目 >= 1000" "PASS  @root/.ab-base-manifest 行数"
	need "80_mount_root 与仓库 HEAD 逐字节一致" "PASS  @root/lib/preinit/80_mount_root 与仓库 HEAD 逐字节一致"
	need "grub.cfg 无 rootwait" "PASS  grub.cfg 无 rootwait"
	need "grub.cfg 含 fstools_ignore_partname=1" "PASS  grub.cfg 含 fstools_ignore_partname=1"
	need "grub.cfg 含 panic=10" "PASS  grub.cfg 含 panic=10"
	need "grub.cfg 不含 try-phase1" "PASS  grub.cfg 不含 try-phase1"
	need "grub.cfg 只有 1 个 menuentry" "PASS  grub.cfg 只有 1 个 menuentry"
	need "grub-script-check 通过" "PASS  grub-script-check 通过"
	need "core.img 非空" "PASS  p1 有 boot/grub/i386-pc/core.img"
	need "grub 模块 serial.mod" "PASS  p1 有 grub 模块 serial.mod"
	need "grub 模块 terminal.mod" "PASS  p1 有 grub 模块 terminal.mod"
	need "initrd 内 /init 的 sha256 与 INIT_SHA 一致（ac-3 第二句）" \
		"PASS  initrd 内 /init 的 sha256 与构建打印的 INIT_SHA 一致"
	need "initrd 内 /init 无残留占位符" "PASS  initrd 内 /init 无残留占位符"
	# manifest 行数必须真的 >= 1000（不是只有一行 PASS 字样）
	_n=$(grep -o 'manifest 行数 [0-9]*' "$REPORT" | head -1 | awk '{print $NF}')
	case ${_n:-x} in
	'' | *[!0-9]*) bad "读不出 manifest 行数（报告里: ${_n:-无}）" ;;
	*)
		if [ "$_n" -ge 1000 ]; then
			pass "manifest 行数 ${_n} >= 1000"
		else
			bad "manifest 行数 ${_n} < 1000"
		fi
		;;
	esac
fi

if [ "$STAGE" = devprod ] || [ "$STAGE" = all ]; then
	printf '\n== dev / prod 判据（ac-4）==\n'
	need "首启扩容脚本两种类型都在" "PASS  ${MODE}: /etc/uci-defaults/10-grow-p2.sh 存在"
	if [ "$MODE" = dev ]; then
		need "dev: /etc/DEV-IMAGE 存在" "PASS  dev: /etc/DEV-IMAGE 存在"
		need "dev: DEV-IMAGE 里 type=dev" "PASS  dev: DEV-IMAGE 里 type=dev"
		need "dev: 90-dev-image 存在" "PASS  dev: /etc/uci-defaults/90-dev-image 存在"
		need "dev: 规则名 dev-open-wan" "PASS  dev: 90-dev-image 含 dev-open-wan"
		need "dev: src=wan" "PASS  dev: 90-dev-image 含 src=wan"
		need "dev: proto=all" "PASS  dev: 90-dev-image 含 proto=all"
		need "dev: target=ACCEPT" "PASS  dev: 90-dev-image 含 target=ACCEPT"
	else
		need "prod: 无 /etc/DEV-IMAGE" "PASS  prod: /etc/DEV-IMAGE 不存在"
		need "prod: 无 90-dev-image" "PASS  prod: /etc/uci-defaults/90-dev-image 不存在"
		need "prod: /etc 下无 dev-open-wan" "PASS  prod: /etc 下没有 dev-open-wan"
		not_need "prod: 报告里没有 dev-open-wan 的 PASS（自相矛盾）" "PASS  dev: 90-dev-image 含 dev-open-wan"
	fi
fi

if [ "$STAGE" = boot ]; then
	printf '\n== 引导冒烟（ac-2 / ac-4）==\n'
	# 冒烟报告来自 CI 里 phase1/tools/qemu-boot-check.sh 的输出（UEFI 与 legacy 各一次）。
	# 进门禁的理由：2026-11-07 的事故是"静态自检全绿、机器根本起不来"。
	if grep -q 'BOOT-SMOKE OK' "$REPORT"; then
		pass "报告结论是 BOOT-SMOKE OK"
	else
		bad "报告里没有 BOOT-SMOKE OK（镜像没在 qemu 里起来，或该次 CI 没跑冒烟）"
	fi
	# 判据用**稳定 id**（bs-1/bs-2/bs-3）而不是整句中文文案，避免冒烟脚本改一句措辞就静默失配。
	for _id in bs-1 bs-2 bs-3; do
		if grep -q "ok   ${_id} " "$REPORT"; then
			pass "${_id} 通过"
		else
			bad "${_id} 未通过（报告里没有 'ok   ${_id}'）"
		fi
	done
	# bs-1 必须来自 p1 引导日志（串口里永远没有那行），报告里应能看到证据源
	if grep -q 'p1 日志本次启动段有 switching root' "$REPORT"; then
		pass "bs-1 的证据源是 p1 引导日志（不是串口）"
	else
		bad "bs-1 的证据源看起来不对（应在 p1 引导日志本次启动段里找 switching root）"
	fi
	not_need "报告里没有 FAIL 行" "  FAIL "
	not_need "报告里没有 BOOT-SMOKE FAILED" "BOOT-SMOKE FAILED"
fi

if [ "$STAGE" = all ]; then
	printf '\n== 总体结论 ==\n'
	need "报告结论是 SELFCHECK OK" "SELFCHECK OK"
	not_need "报告里没有 FAIL 行" "FAIL  "
fi

printf '\n---\n'
if [ "$FAILED" = 0 ]; then
	printf 'CI-REPORT OK（%s / %s）\n' "$MODE" "$STAGE"
	exit 0
fi
printf 'CI-REPORT FAILED（%s / %s）\n' "$MODE" "$STAGE"
exit 1
