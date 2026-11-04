#!/bin/sh
# ac-5：定位不到设备段时必须 fail-closed —— 报错、退出非 0、**一个字节都不改**。
# 对照 audit C1/N1：旧实现猜段名 network.br_lan，真机必然静默失败并留下半套配置。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

LIB=$REPO/files/lib/functions/netports.sh
sb_new failclosed
sb_fixture net-nodevice
sb_netports
sb_initd
S=$(sb_sysfs eth0:0000:01:00.0 eth1:0000:02:00.0 eth2:0000:03:00.0 eth3:0000:04:00.0)
export NETPORTS_SYSFS=$S
before=$(sb_uci_cksum)
LOG=$SB_ROOT/netports.log

echo "== netports_apply：无设备段 =="
# 故意传 wan=eth3：若脚本"半成功"，wan.device 会变成 eth3
out=$(NETPORTS_LOG=$LOG sh -c ". $LIB; netports_apply eth3 eth0 eth1 eth2" 2>&1); rc=$?
ne "退出码非 0" '0' "$rc"
contains "日志写明定位失败" '定位不到 LAN 设备段' "$out"
eq "配置逐字节未变" "$before" "$(sb_uci_cksum)"
eq "wan.device 仍是出厂值" 'eth0' "$(uci -q get network.wan.device)"
eq "wan6.device 未被改" 'eth0' "$(uci -q get network.wan6.device)"
uci -q get network.br_lan >/dev/null 2>&1; rc=$?
ne "未凭猜段名建出 network.br_lan" '0' "$rc"

echo "== nicsync：同一 fixture 上也不许改配置 =="
N=$(sb_script "$REPO/files/usr/sbin/nicsync" usr/sbin/nicsync)
out=$(sh "$N" --fix --sysfs "$S" 2>&1); rc=$?
ne "nicsync --fix 退出码非 0" '0' "$rc"
contains "nicsync 说明未改配置" '定位不到 LAN 设备段' "$out"
eq "nicsync 未改配置" "$before" "$(sb_uci_cksum)"
eq "nicsync 未 reload 网络" '' "$(grep '^network' "$SB_RELOADS" 2>/dev/null)"

echo "== 99-custom：首启也不许留半套 =="
C=$(sb_script "$REPO/files/etc/uci-defaults/99-custom.sh" etc/uci-defaults/99-custom.sh)
rc=0
NETPORTS_LOG=$SB_ROOT/ud-netports.log sh "$C" >/dev/null 2>&1 || rc=$?
ne "99-custom 退出码非 0（下次开机会重试）" '0' "$rc"
eq "99-custom 未改配置" "$before" "$(sb_uci_cksum)"
eq "99-custom 未把 wan 改到别的口" 'eth0' "$(uci -q get network.wan.device)"
contains "99-custom 日志记 ERROR" 'ERROR' "$(cat "$SB_ROOT/etc/config/uci-defaults-log.txt" 2>/dev/null)"

finish NETPORTS-FAIL-CLOSED
