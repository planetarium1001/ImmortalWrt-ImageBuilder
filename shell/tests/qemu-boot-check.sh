#!/bin/sh
# ac-2：qemu-boot-check.sh 的**离线**用例（不需要 qemu）。
#
# 判据语义（2026-11-07 复核后修正）：
#   bs-1 = p1 的 phase1-boot.log（**本次启动段**）里有 switching root upperdir=/overlay/upper
#   bs-2 = 串口日志里有内核 printk（`Linux version …`）——证明内核真的接管了
#   bs-3 = p1 日志本次启动段没有 `FAIL stage=`
# 早期版本把 bs-1 判在串口日志上，而 /init 那行是写到 /dev/console（= cmdline 最后一个 console=tty1）的，
# 串口永远抓不到 ⇒ 健康镜像也必然 FAILED。本用例的第 3b 节专门钉"只看本次启动段"，防止旧日志冒充成功。
set -u
. "$(dirname "$0")/lib-assert.sh"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/phase1/tools/qemu-boot-check.sh"
SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bsmoke.XXXXXX")

# ---- 夹具 ----
printf '[    0.000000] Linux version 6.12.103 (openwrt@build) #1 SMP\n' >"$SB_ROOT/serial.ok"
printf 'GNU GRUB version 2.06\nBooting a command list\n' >"$SB_ROOT/serial.nokernel"
cat >"$SB_ROOT/boot.ok" <<'EOF'
=== phase1-init: start build=phase1-v7 dev=/dev/nvme0n1p2 ===
2026-11-07 15:30:40 phase1-init: ok stage=devnode /dev/nvme0n1p2 + /dev/nvme0n1p1 就绪
2026-11-07 15:30:43 phase1-init: info 新根挂载点已就绪: proc sys dev tmp
2026-11-07 15:30:43 initramfs: switching root upperdir=/overlay/upper
EOF
grep -v 'switching root' "$SB_ROOT/boot.ok" >"$SB_ROOT/boot.noswitch"
cat "$SB_ROOT/boot.ok" >"$SB_ROOT/boot.second-fail"
{
	printf '=== phase1-init: start build=phase1-v7 dev=/dev/nvme0n1p2 ===\n'
	printf '2026-11-07 16:40:02 phase1-init: ok stage=devnode\n'
	printf '2026-11-07 16:40:03 phase1-init: FAIL stage=compress /overlay 缺 compress\n'
} >>"$SB_ROOT/boot.second-fail"
{ cat "$SB_ROOT/boot.ok"; printf '2026-11-07 15:30:44 phase1-init: FAIL stage=lower-release 子卷选错\n'; } >"$SB_ROOT/boot.fail"

echo "== 0. 形态与帮助 =="
[ -x "$S" ] && ok "脚本可执行" || bad "脚本不可执行"
H=$(sh "$S" --help 2>&1)
contains "--help 有 OK 终态" 'BOOT-SMOKE OK' "$H"
contains "--help 有 FAILED 终态" 'BOOT-SMOKE FAILED' "$H"
contains "--help 有 PEND 终态" 'BOOT-SMOKE PEND' "$H"
contains "--help 列出 bs-1" 'bs-1' "$H"
contains "--help 列出 bs-3" 'bs-3' "$H"
contains "--help 说明 bs-1 的证据源是 p1 日志" 'phase1-boot.log' "$H"
sh "$S" --nonsense >/dev/null 2>&1
eq "未知参数退出 2" 2 "$?"

echo "== 1. 正向：p1 日志有切根行 + 串口有内核 printk ⇒ OK =="
OUT=$(sh "$S" --replay "$SB_ROOT/serial.ok" --boot-log "$SB_ROOT/boot.ok" 2>&1)
RC=$?
eq "正向退出 0" 0 "$RC"
contains "末态 BOOT-SMOKE OK" 'BOOT-SMOKE OK' "$OUT"
contains "bs-1 通过" 'ok   bs-1' "$OUT"
contains "bs-2 通过" 'ok   bs-2' "$OUT"
contains "bs-3 通过" 'ok   bs-3' "$OUT"

echo "== 2. 反向：串口没有内核 printk ⇒ FAILED（bs-2）=="
OUT=$(sh "$S" --replay "$SB_ROOT/serial.nokernel" --boot-log "$SB_ROOT/boot.ok" 2>&1)
RC=$?
eq "缺内核 printk 退出 1" 1 "$RC"
contains "判 FAILED" 'BOOT-SMOKE FAILED' "$OUT"
contains "点名 bs-2" 'FAIL bs-2' "$OUT"

echo "== 3. 反向：p1 日志本次段没有 switching root ⇒ FAILED（bs-1）=="
OUT=$(sh "$S" --replay "$SB_ROOT/serial.ok" --boot-log "$SB_ROOT/boot.noswitch" 2>&1)
RC=$?
eq "缺切根行退出 1" 1 "$RC"
contains "点名 bs-1" 'FAIL bs-1' "$OUT"

echo "== 3b. 关键：第一次启动成功、最后一次没走到 ⇒ 仍必须红（只看本次启动段）=="
OUT=$(sh "$S" --replay "$SB_ROOT/serial.ok" --boot-log "$SB_ROOT/boot.second-fail" 2>&1)
RC=$?
eq "旧日志不能冒充本次成功" 1 "$RC"
contains "点名 bs-1（本次段缺切根）" 'FAIL bs-1' "$OUT"
contains "点名 bs-3（本次段有 FAIL stage=）" 'FAIL bs-3' "$OUT"

echo "== 4. 反向：p1 日志有 FAIL stage= ⇒ FAILED（bs-3）=="
OUT=$(sh "$S" --replay "$SB_ROOT/serial.ok" --boot-log "$SB_ROOT/boot.fail" 2>&1)
RC=$?
eq "有 FAIL stage= 退出 1" 1 "$RC"
contains "点名 bs-3" 'FAIL bs-3' "$OUT"

echo "== 5. 反向：p1 日志缺失 ⇒ FAILED（fail-closed，不许「没证据算通过」）=="
OUT=$(sh "$S" --replay "$SB_ROOT/serial.ok" --boot-log "$SB_ROOT/nonexistent.log" 2>&1)
RC=$?
eq "缺日志退出 1" 1 "$RC"
contains "点名 bs-1 缺文件" 'FAIL bs-1' "$OUT"

echo "== 6. 失败时必须把现场打到 stdout（否则红了排不了障）=="
OUT=$(sh "$S" --replay "$SB_ROOT/serial.nokernel" --boot-log "$SB_ROOT/boot.ok" 2>&1)
case "$OUT" in
*'串口日志（'*|*串口日志尾部*) ok "打印了串口日志（红了能排障）" ;;
*) bad "失败时没打印串口日志" ;;
esac
# --replay 模式没有 qemu 进程，自然没有 qemu 内部日志；这条只能静态断言"真跑路径会开 -d"
grep -q -- '-d guest_errors,int' "$S" && ok "真跑路径开了 qemu 内部日志（-d guest_errors,int）" ||
	bad "真跑路径没开 qemu 内部日志（失败时看不出三重复位这类问题）"
case "$OUT" in
*p1\ 引导日志尾部*|*p1引导日志尾部*) ok "打印了 p1 引导日志尾部" ;;
*) bad "失败时没打印 p1 引导日志尾部" ;;
esac

echo "== 7. 真跑模式的参数校验（不真的启动）=="
sh "$S" >/dev/null 2>&1
eq "既无 --image 也无 --replay ⇒ 退出 2" 2 "$?"
sh "$S" --image "$SB_ROOT/nope.img" >/dev/null 2>&1
eq "镜像不存在 ⇒ 退出 2" 2 "$?"

finish shell-qemu-boot-check
