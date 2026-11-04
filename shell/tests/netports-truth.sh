#!/bin/sh
# ac-4：端口分配单一真源。25.12 真机段形（**匿名** config device + option name 'br-lan'）
# 下必须写进 @device[N].ports，且 wan.device 不得同时是桥成员（灯亮无地址的根因）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

LIB=$REPO/files/lib/functions/netports.sh

# ---- 例 1：匿名 config device（config_generate 的真实段形）----
sb_new truth-anon
sb_fixture net-anon
sb_netports
S=$(sb_sysfs eth0:0000:01:00.0 eth1:0000:02:00.0 eth2:0000:03:00.0 eth3:0000:04:00.0)
export NETPORTS_SYSFS=$S

echo "== 匿名设备段 =="
eq "物理口枚举" 'eth0 eth1 eth2 eth3' "$(sh -c ". $LIB; netports_phys" | tr '\n' ' ' | sed 's/ *$//')"
eq "定位到匿名设备段" '@device[0]' "$(sh -c ". $LIB; netports_dev_section")"
rc=0
sh -c ". $LIB; netports_apply eth0 eth1 eth2 eth3" >/dev/null 2>&1 || rc=$?
eq "netports_apply 成功" '0' "$rc"
eq "写进 @device[0].ports" 'eth1 eth2 eth3' "$(uci -q get network.@device[0].ports)"
eq "wan.device 指向首口" 'eth0' "$(uci -q get network.wan.device)"
eq "wan6.device 与 wan 一致" 'eth0' "$(uci -q get network.wan6.device)"
case " $(uci -q get network.@device[0].ports) " in
*' eth0 '*) bad "wan.device 不得出现在桥成员里" ;;
*) ok "wan.device 不在桥成员里" ;;
esac
uci -q get network.br_lan >/dev/null 2>&1; rc=$?
ne "没有凭空建出 network.br_lan 段" '0' "$rc"

# ---- 例 2：命名 device 段（老式手写配置 / 用户自建段）----
echo "== 命名设备段 =="
sb_new truth-named
sb_fixture net-named
sb_netports
S=$(sb_sysfs eth0:0000:01:00.0 eth1:0000:02:00.0 eth2:0000:03:00.0)
export NETPORTS_SYSFS=$S
eq "定位到命名段" 'br_lan' "$(sh -c ". $LIB; netports_dev_section")"
rc=0
sh -c ". $LIB; netports_apply eth0 eth1 eth2" >/dev/null 2>&1 || rc=$?
eq "命名段写端口成功" '0' "$rc"
eq "命名段 ports 正确" 'eth1 eth2' "$(uci -q get network.br_lan.ports)"
eq "命名段下 wan.device 正确" 'eth0' "$(uci -q get network.wan.device)"

# ---- 例 3：端口序按 bus:dev.fn 数值，而非字典序（audit N6）----
echo "== 端口序：数值而非字典序 =="
sb_new truth-order
sb_fixture net-anon
sb_netports
S=$(sb_sysfs eth0:0000:9:00.0 eth1:0000:10:00.0 eth2:0000:2:00.0)
export NETPORTS_SYSFS=$S
eq "0000:9 < 0000:10（字典序会反过来）" 'eth2 eth0 eth1' "$(sh -c ". $LIB; netports_phys" | tr '\n' ' ' | sed 's/ *$//')"

finish NETPORTS-TRUTH
