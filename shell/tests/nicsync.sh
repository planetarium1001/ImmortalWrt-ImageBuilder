#!/bin/sh
# nicsync 行为用例（ac-4/N1/N2）：25.12 真机段形（**匿名** config device）下
# ① --dry-run/--check 只读、② --fix 写真实设备段并 reload、③ 永不猜 network.br_lan。
# 旧用例往桩里种 network.br_lan.ports=… —— 那是 25.12 永不出现的段形（audit T2）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new nicsync
sb_fixture net-anon
sb_netports
sb_initd
S=$(sb_sysfs eth0:0000:01:00.0 eth1:0000:02:00.0 eth2:0000:03:00.0 eth3:0000:04:00.0)
N=$(sb_script "$REPO/files/usr/sbin/nicsync" usr/sbin/nicsync)
NET=$UCI_STUB_DIR/network
reloads() { grep -c '^network reload' "$SB_RELOADS" 2>/dev/null || true; }

echo "== 出厂状态：桥里只有 eth0，而 wan.device 也是 eth0（端口重叠）=="
eq "出厂桥成员" 'eth0' "$(uci -q get network.@device[0].ports)"
eq "出厂 wan.device" 'eth0' "$(uci -q get network.wan.device)"

echo "== --dry-run：只判定不落盘 =="
before=$(cksum <"$NET")
out=$(sh "$N" --dry-run --sysfs "$S" 2>&1); rc=$?
eq "--dry-run 退出 0" '0' "$rc"
contains "--dry-run 提示将要修" 'would fix' "$out"
eq "--dry-run 未落盘" "$before" "$(cksum <"$NET")"
eq "--dry-run 不 reload" '0' "$(reloads)"

echo "== --check：不齐返回 2，且绝不写配置 =="
out=$(sh "$N" --check --sysfs "$S" 2>&1); rc=$?
eq "--check 不齐退出 2" '2' "$rc"
contains "--check 报不齐" '不齐' "$out"
eq "--check 未落盘" "$before" "$(cksum <"$NET")"
eq "--check 不 reload" '0' "$(reloads)"

echo "== --fix：写进匿名设备段，而不是猜出来的 network.br_lan =="
out=$(sh "$N" --fix --sysfs "$S" 2>&1); rc=$?
eq "--fix 退出 0" '0' "$rc"
eq "--fix 后 @device[0].ports" 'eth1 eth2 eth3' "$(uci -q get network.@device[0].ports)"
eq "--fix 后 wan.device" 'eth0' "$(uci -q get network.wan.device)"
eq "--fix 后 wan6.device" 'eth0' "$(uci -q get network.wan6.device)"
eq "--fix 触发一次 network reload" '1' "$(reloads)"
uci -q get network.br_lan >/dev/null 2>&1; rc=$?
ne "未凭空建出 network.br_lan 段" '0' "$rc"
case " $(uci -q get network.@device[0].ports) " in
*' eth0 '*) bad "wan.device 不得留在桥成员里" ;;
*) ok "wan.device 不在桥成员里" ;;
esac

echo "== --check：对齐后返回 0 且不再 reload =="
out=$(sh "$N" --check --sysfs "$S" 2>&1); rc=$?
eq "--check 对齐退出 0" '0' "$rc"
contains "--check 输出已对齐" '配置已对齐' "$out"
eq "--check 对齐后未新增 reload" '1' "$(reloads)"

echo "== --sysfs 空目录：安全退出 =="
mkdir -p "$SB_ROOT/empty-sys/class/net"
out=$(sh "$N" --check --sysfs "$SB_ROOT/empty-sys" 2>&1); rc=$?
eq "无物理口退出 0" '0' "$rc"
contains "无物理口有明确提示" 'no physical port' "$out"

finish NICSYNC
