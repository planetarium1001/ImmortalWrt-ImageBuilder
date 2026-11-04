#!/bin/sh
# 99-custom.sh 行为用例（ac-3/N1/C1/T4）：真机段形下首启把**端口/管理地址/主机名**
# 写进真实段。旧用例只是 grep 源码里的 `uci add_list "network.$sec.ports` —— 那正好
# 把错误实现钉进测试（audit T4）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new udnic
sb_fixture net-anon
sb_netports
sb_initd
S=$(sb_sysfs eth0:0000:01:00.0 eth1:0000:02:00.0 eth2:0000:03:00.0 eth3:0000:04:00.0)
export NETPORTS_SYSFS=$S
C=$(sb_script "$REPO/files/etc/uci-defaults/99-custom.sh" etc/uci-defaults/99-custom.sh)
NET=$UCI_STUB_DIR/network
LOG=$SB_ROOT/etc/config/uci-defaults-log.txt

echo "== 四口机：多口分支 =="
rc=0
NETPORTS_LOG=$SB_ROOT/netports.log sh "$C" >"$SB_ROOT/out1" 2>&1 || rc=$?
eq "退出 0" '0' "$rc"
eq "端口写进 @device[0].ports" 'eth1 eth2 eth3' "$(uci -q get network.@device[0].ports)"
eq "wan.device 指向首口" 'eth0' "$(uci -q get network.wan.device)"
eq "lan.ipaddr" '192.168.100.1' "$(uci -q get network.lan.ipaddr)"
eq "lan.netmask" '255.255.255.0' "$(uci -q get network.lan.netmask)"
eq "hostname" 'ImmortalWrt' "$(uci -q get system.@system[0].hostname)"
contains "日志记多口分配" 'multi-port: wan=eth0' "$(cat "$LOG" 2>/dev/null)"
contains "日志记定位到的真实段" 'device=@device[0]' "$(cat "$LOG" 2>/dev/null)"
eq "成功路径不产生 netports 错误日志" '' "$(cat "$SB_ROOT/netports.log" 2>/dev/null)"
uci -q get network.br_lan >/dev/null 2>&1; rc=$?
ne "未凭空建出 network.br_lan 段" '0' "$rc"

echo "== 上游配置未被整份覆盖（只增不改）=="
eq "loopback 段保留" '127.0.0.1' "$(uci -q get network.loopback.ipaddr)"
eq "wan.proto 保留上游值" 'dhcp' "$(uci -q get network.wan.proto)"
eq "dhcp.wan.ignore 保留" '1' "$(uci -q get dhcp.wan.ignore)"

echo "== 管理面：ssh/ttyd 不绑接口 =="
uci -q get dropbear.@dropbear[0].Interface >/dev/null 2>&1; rc=$?
ne "dropbear Interface 已清空" '0' "$rc"
uci -q get ttyd.@ttyd[0].interface >/dev/null 2>&1; rc=$?
ne "ttyd interface 已清空" '0' "$rc"

echo "== 自定义管理地址文件 =="
echo '192.168.50.1' >"$SB_ROOT/etc/config/custom_router_ip.txt"
rc=0
NETPORTS_LOG=$SB_ROOT/netports.log sh "$C" >/dev/null 2>&1 || rc=$?
eq "自定义地址生效" '192.168.50.1' "$(uci -q get network.lan.ipaddr)"

echo "== 幂等：再跑一次逐字节不变 =="
before=$(cksum <"$NET")
rc=0
NETPORTS_LOG=$SB_ROOT/netports.log sh "$C" >/dev/null 2>&1 || rc=$?
eq "重复执行退出 0" '0' "$rc"
eq "重复执行配置未变" "$before" "$(cksum <"$NET")"
eq "重复执行桥成员未变" 'eth1 eth2 eth3' "$(uci -q get network.@device[0].ports)"

finish UCI-NIC
