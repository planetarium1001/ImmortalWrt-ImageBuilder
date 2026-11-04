#!/bin/sh
# ac-6：连跑两次 --check，第二次输出「已对齐」且**不调用** /etc/init.d/network reload。
# 用记录型 init.d stub 断言调用次数（audit N2：旧实现每次都写配置 + reload + 假日志）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new nicsync-idem
sb_fixture net-anon
sb_netports
sb_initd
S=$(sb_sysfs eth0:0000:01:00.0 eth1:0000:02:00.0 eth2:0000:03:00.0 eth3:0000:04:00.0)
N=$(sb_script "$REPO/files/usr/sbin/nicsync" usr/sbin/nicsync)
NET=$UCI_STUB_DIR/network
reloads() { grep -c '^network reload' "$SB_RELOADS" 2>/dev/null || true; }

echo "== 先用 --fix 把配置对齐（这是唯一允许 reload 的一次）=="
rc=0
sh "$N" --fix --sysfs "$S" >/dev/null 2>&1 || rc=$?
eq "--fix 成功" '0' "$rc"
eq "--fix 后 reload 次数" '1' "$(reloads)"
aligned=$(cksum <"$NET")

echo "== 第一次 --check =="
out1=$(sh "$N" --check --sysfs "$S" 2>&1); rc1=$?
eq "第一次 --check 退出 0" '0' "$rc1"
contains "第一次 --check 输出已对齐" '配置已对齐' "$out1"

echo "== 第二次 --check =="
out2=$(sh "$N" --check --sysfs "$S" 2>&1); rc2=$?
eq "第二次 --check 退出 0" '0' "$rc2"
contains "第二次 --check 输出已对齐" '配置已对齐' "$out2"
eq "两次 --check 都没有触发 network reload" '1' "$(reloads)"
eq "两次 --check 配置逐字节未变" "$aligned" "$(cksum <"$NET")"
eq "两次输出一致（幂等）" "$out1" "$out2"

finish NICSYNC-IDEMPOTENT
