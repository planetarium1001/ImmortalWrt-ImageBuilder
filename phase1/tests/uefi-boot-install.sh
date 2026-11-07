#!/bin/sh
# ac-1：镜像必须**双模引导**（UEFI + legacy）。
#
# 为什么有这个用例（2026-11-07 真机事故）：镜像只装了 i386-pc，N5105 是纯 UEFI 固件（AMI v2.70，无 CSM），
# 枚举不到可引导项就直接落到内置 "UEFI Interactive Shell v2.2"。当时 CI 全绿，因为它只做静态自检、
# 从不真的启动镜像。本用例把"UEFI 引导器必须被安装并被校验"钉成机械判据。
set -u
TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)
. "$REPO/shell/tests/lib-assert.sh"

AI=$REPO/phase1/assemble-image.sh
SB_ROOT=$(mktemp -d /tmp/phase1-uefi.XXXXXX 2>/dev/null) || {
	echo "无法创建沙盒目录" >&2
	exit 1
}

echo "== 1. --dry-run 计划里同时有两种引导器 =="
OUT=$SB_ROOT/plan.txt
sh "$AI" --dry-run --rootfs phase1-rootfs.tar.gz --kernel vmlinuz \
	--initrd initrd.cpio.gz --disk /dev/nvme9n1 >"$OUT" 2>&1
eq "dry-run 退出 0" 0 $?
PLAN=$(cat "$OUT")
contains "计划含 legacy i386-pc" 'grub-install --target=i386-pc' "$PLAN"
contains "计划含 UEFI x86_64-efi" 'grub-install --target=x86_64-efi' "$PLAN"
contains "UEFI 计划指定 --efi-directory" '--efi-directory=' "$PLAN"
contains "UEFI 用可移动介质回退路径 --removable" '--removable' "$PLAN"
contains "UEFI 不写 NVRAM（--no-nvram）" '--no-nvram' "$PLAN"
contains "点名 EFI 回退文件 BOOTX64.EFI" 'BOOTX64.EFI' "$PLAN"

echo "== 2. 静态：UEFI 安装是**真的执行**，不只是打印 =="
grep -q 'grub-install --target=x86_64-efi' "$AI" &&
	ok "源码里存在 x86_64-efi 的实际调用" || bad "源码里没有 x86_64-efi 的实际调用"
# 真调用必须带 --efi-directory 与 --removable（否则产物落不到 \EFI\BOOT\）
# 关键：把 `say ...` 日志行剔掉再断言。否则"打印里出现过 --removable"就能让断言变绿，
# 而真实的 grub-install 调用被删掉了也看不出来（2026-11-07 复核实测：M1/M2/M3 变异全部仍绿）。
_efi_block=$(sed -n '/^install_grub_efi()/,/^}/p' "$AI" | grep -v '^[[:space:]]*say ')
_case_ok=1
grep -qE '^[[:space:]]*grub-install --target=x86_64-efi' "$AI" &&
	ok "真实（非 say 打印）的 x86_64-efi 调用存在" || { bad "源码里只有 say 打印，没有真正的 x86_64-efi 调用"; _case_ok=0; }
case "$_efi_block" in
*'--efi-directory='*) [ "$_case_ok" = 1 ] && ok "install_grub_efi 带 --efi-directory" ;;
*) bad "install_grub_efi 缺 --efi-directory" ;;
esac
case "$_efi_block" in
*'--removable'*) ok "install_grub_efi 带 --removable（UEFI 回退路径）" ;;
*) bad "install_grub_efi 缺 --removable" ;;
esac
case "$_efi_block" in
*'--no-nvram'*) ok "install_grub_efi 带 --no-nvram（整盘 dd 无法写 NVRAM）" ;;
*) bad "install_grub_efi 缺 --no-nvram" ;;
esac

echo "== 3. 静态：装完必须自证（存在性 + PE 头），失败即 die =="
case "$_efi_block" in
*'EFI/BOOT/BOOTX64.EFI'*) ok "安装后断言 BOOTX64.EFI 存在" ;;
*) bad "安装后没有断言 BOOTX64.EFI 存在" ;;
esac
case "$_efi_block" in
*4d5a*) ok "校验 PE magic（4d5a = MZ）" ;;
*) bad "没有校验 PE magic" ;;
esac
case "$_efi_block" in
*'fail '*) ok "失败走 fail（非静默）" ;;
*) bad "失败没有 fail 出口" ;;
esac
case "$_efi_block" in
*'grub-efi-amd64-bin'*) ok "失败提示点了 grub-efi-amd64-bin" ;;
*) bad "失败提示没点 grub-efi-amd64-bin" ;;
esac

echo "== 4. 静态：install_grub 内确实调用了 install_grub_efi（两条路径都会装上）=="
_grub_block=$(sed -n '/^install_grub()/,/^}/p' "$AI")
case "$_grub_block" in
*'install_grub_efi'*) ok "install_grub 调用 install_grub_efi（镜像模式与真装机共用）" ;;
*) bad "install_grub 没有调用 install_grub_efi" ;;
esac

echo "== 5. dry-run 没有写任何文件 =="
eq "沙盒里没有产出镜像" 0 "$(ls -1 "$SB_ROOT"/*.img 2>/dev/null | wc -l | tr -d ' ')"

finish phase1-uefi-boot-install
