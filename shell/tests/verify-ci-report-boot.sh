#!/bin/sh
# ac-4：CI 冒烟判据必须"接得上、且双向可验"。
#
# 为什么验收落在这里而不是"CI 报告真绿"：CI 是 workflow_dispatch，只能在 **push 之后**跑，
# 而工作流的机械门禁要求"证据先于提交"，两者物理上不可同时满足（2026-11-07 用户裁定）。
# 于是本用例验**判据本身**：合格报告必须过，缺 bs-1 / 出现 BOOT-SMOKE FAILED / 没有 BOOT-SMOKE OK 必须红；
# "CI 真的绿了"由后续任务（20261107-n5105-flash-dev-firstboot-evidence）对真实
# boot-smoke-dev-{uefi,bios}.txt 逐行复核，不通过就回来继续修。
set -u
. "$(dirname "$0")/lib-assert.sh"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VCR="$ROOT/phase1/tools/verify-ci-report.sh"
SMOKE="$ROOT/phase1/tools/qemu-boot-check.sh"
SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vcrboot.XXXXXX")

# ---- 用冒烟脚本自己的 --replay 生成"合格报告"（不是手写判据字符串，避免两边漂移）----
printf '[    0.000000] Linux version 6.12.103 (openwrt@build) #1 SMP\n' >"$SB_ROOT/serial.ok"
cat >"$SB_ROOT/boot.ok" <<'EOF'
=== phase1-init: start build=phase1-v7 dev=/dev/nvme0n1p2 ===
2026-11-07 15:30:40 phase1-init: ok stage=devnode /dev/nvme0n1p2 + /dev/nvme0n1p1 就绪
2026-11-07 15:30:43 phase1-init: info 新根挂载点已就绪: proc sys dev tmp
2026-11-07 15:30:43 initramfs: switching root upperdir=/overlay/upper
EOF
sh "$SMOKE" --replay "$SB_ROOT/serial.ok" --boot-log "$SB_ROOT/boot.ok" >"$SB_ROOT/report.ok" 2>&1
eq "冒烟脚本对合格输入给出 BOOT-SMOKE OK" 0 "$?"

echo "== 1. 合格报告 ⇒ CI-REPORT OK（dev / boot）=="
sh "$VCR" "$SB_ROOT/report.ok" --mode dev --stage boot >"$SB_ROOT/vcr.ok" 2>&1
RC=$?
eq "verify-ci-report --stage boot 退出 0" 0 "$RC"
contains "末态 CI-REPORT OK" 'CI-REPORT OK（dev / boot）' "$(cat "$SB_ROOT/vcr.ok")"

echo "== 2. 反向：报告里没有 BOOT-SMOKE OK ⇒ 红 =="
grep -v 'BOOT-SMOKE OK' "$SB_ROOT/report.ok" >"$SB_ROOT/report.nosmoke"
sh "$VCR" "$SB_ROOT/report.nosmoke" --mode dev --stage boot >"$SB_ROOT/vcr.nosmoke" 2>&1
eq "缺 BOOT-SMOKE OK 退出非 0" 1 "$?"
contains "点名缺 BOOT-SMOKE OK" '没有 BOOT-SMOKE OK' "$(cat "$SB_ROOT/vcr.nosmoke")"

echo "== 3. 反向：报告里 bs-1 是 FAIL ⇒ 红（判据绑定稳定 id，不靠整句文案）=="
sed 's/  ok   bs-1 /  FAIL bs-1 /' "$SB_ROOT/report.ok" >"$SB_ROOT/report.bs1fail"
sh "$VCR" "$SB_ROOT/report.bs1fail" --mode dev --stage boot >"$SB_ROOT/vcr.bs1fail" 2>&1
eq "bs-1 FAIL 时退出非 0" 1 "$?"
contains "点名 bs-1 未通过" 'bs-1 未通过' "$(cat "$SB_ROOT/vcr.bs1fail")"

echo "== 4. 反向：出现 BOOT-SMOKE FAILED ⇒ 红 =="
{ cat "$SB_ROOT/report.ok"; printf 'BOOT-SMOKE FAILED（2 项检查）\n'; } >"$SB_ROOT/report.failed"
sh "$VCR" "$SB_ROOT/report.failed" --mode dev --stage boot >"$SB_ROOT/vcr.failed" 2>&1
eq "含 BOOT-SMOKE FAILED 时退出非 0" 1 "$?"

echo "== 5. --stage all 不吃冒烟报告（all 的输入是 selfcheck 报告）=="
cat >"$SB_ROOT/selfcheck.sample" <<'EOF'
PASS  p1 = 256 MiB（524288 扇区）
PASS  p128 = 4 MiB / EF02
PASS  p2 占到盘尾（end=16777182 / total=16777216）
PASS  物理顺序 p1 < p128 < p2（p2 最后，首启扩容只重建 p2）
PASS  p1 文件系统 = vfat
PASS  p2 文件系统 = btrfs
PASS  子卷恰为 @root @overlay @docker @swap
PASS  @root/etc/openwrt_release 存在（）
PASS  @root/.ab-base-manifest 行数 2585（>= 1000）
PASS  dev: /etc/uci-defaults/10-grow-p2.sh 存在
PASS  dev: /etc/DEV-IMAGE 存在
PASS  dev: DEV-IMAGE 里 type=dev
PASS  dev: /etc/uci-defaults/90-dev-image 存在
PASS  dev: 90-dev-image 含 dev-open-wan
PASS  dev: 90-dev-image 含 src=wan
PASS  dev: 90-dev-image 含 proto=all
PASS  dev: 90-dev-image 含 target=ACCEPT
SELFCHECK OK（mode=dev）
EOF
# 这里不关心 selfcheck 判据本身过不过（样本是截断的），只断言 all **不会**去查冒烟段：
# 否则"用 selfcheck 报告跑 --stage all"会永久红（复核 2026-11-07 指出的问题）。
sh "$VCR" "$SB_ROOT/selfcheck.sample" --mode dev --stage all >"$SB_ROOT/vcr.all" 2>&1 || true
if grep -q '引导冒烟' "$SB_ROOT/vcr.all"; then
	bad "--stage all 仍会去查冒烟段（selfcheck 报告永远没有那些行 ⇒ 永久红）"
else
	ok "--stage all 不查冒烟段（boot 需单独 --stage boot）"
fi

echo "== 6. CI 里确实有双模冒烟步骤与产物归档 =="
WF="$ROOT/.github/workflows/Build-phase1-btrfs.yml"
grep -q 'qemu-boot-check.sh' "$WF" && ok "CI 调用 qemu-boot-check.sh" || bad "CI 没有调用冒烟脚本"
grep -q 'for fw in uefi bios' "$WF" && ok "CI 跑 UEFI 与 legacy 两档" || bad "CI 没有跑两档固件"
grep -q 'boot-smoke-' "$WF" && ok "CI 归档 boot-smoke-*.txt" || bad "CI 没有归档冒烟报告"
grep -q 'grub-efi-amd64-bin' "$WF" && ok "CI 装了 grub-efi-amd64-bin（UEFI 模块树）" || bad "CI 没装 grub-efi-amd64-bin"

finish shell-verify-ci-report-boot
