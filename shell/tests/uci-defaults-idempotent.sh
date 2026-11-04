#!/bin/sh
# 首启 99-custom.sh 的分支参数化用例（audit T3）：4 口 / 1 口 / 0 口三条分支
# 都必须真的执行过，并且断言"脚本产出的配置"，而不是"自己往库里种的键"。
# 旧用例在无 /sys 的宿主上只走了 count=0 的 else 分支，还自种自验（恒真）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

NETLOG=''

run_ud() { # <tag> [sysfs 规格...]
	_tag=$1
	shift
	sb_new "ud-$_tag"
	sb_fixture net-anon
	sb_netports
	sb_initd
	SB_SYS=$(sb_sysfs "$@")
	export NETPORTS_SYSFS=$SB_SYS
	SB_C=$(sb_script "$REPO/files/etc/uci-defaults/99-custom.sh" etc/uci-defaults/99-custom.sh)
	SB_NET=$UCI_STUB_DIR/network
	SB_LOG=$SB_ROOT/etc/config/uci-defaults-log.txt
	NETLOG=$SB_ROOT/netports.log
}

run_ud four eth0:0000:01:00.0 eth1:0000:02:00.0 eth2:0000:03:00.0 eth3:0000:04:00.0
echo "== 4 口：多口分支 =="
rc=0
NETPORTS_LOG=$NETLOG sh "$SB_C" >/dev/null 2>&1 || rc=$?
eq "4 口退出 0" '0' "$rc"
eq "4 口桥成员" 'eth1 eth2 eth3' "$(uci -q get network.@device[0].ports)"
contains "4 口日志是多口分支" 'multi-port' "$(cat "$SB_LOG" 2>/dev/null)"
not_contains "4 口不应报单口告警" 'WARN: single-port' "$(cat "$SB_LOG" 2>/dev/null)"
# 幂等：连跑两次逐字节一致
before=$(cksum <"$SB_NET")
rc=0
NETPORTS_LOG=$NETLOG sh "$SB_C" >/dev/null 2>&1 || rc=$?
eq "重复执行退出 0" '0' "$rc"
eq "重复执行配置逐字节未变" "$before" "$(cksum <"$SB_NET")"

run_ud one eth0:0000:01:00.0
echo "== 1 口：单口分支必须保持 LAN 静态（backlog C3）=="
rc=0
NETPORTS_LOG=$NETLOG sh "$SB_C" >/dev/null 2>&1 || rc=$?
eq "1 口退出 0" '0' "$rc"
eq "单口不把 LAN 切成 DHCP 客户端" 'static' "$(uci -q get network.lan.proto)"
contains "单口有明确告警" 'WARN: single-port' "$(cat "$SB_LOG" 2>/dev/null)"
eq "单口管理地址仍写入" '192.168.100.1' "$(uci -q get network.lan.ipaddr)"
eq "单口不改动出厂桥成员" 'eth0' "$(uci -q get network.@device[0].ports)"
eq "单口设置 dhcp.lan.ignore 属可选路径（此处应未设置）" '' "$(uci -q get dhcp.lan.ignore)"

run_ud zero
echo "== 0 口：无物理口分支 =="
rc=0
NETPORTS_LOG=$NETLOG sh "$SB_C" >/dev/null 2>&1 || rc=$?
eq "0 口退出 0" '0' "$rc"
contains "0 口有明确告警" '未发现物理网口' "$(cat "$SB_LOG" 2>/dev/null)"
eq "0 口不写管理地址（沿用出厂）" '192.168.1.1' "$(uci -q get network.lan.ipaddr)"
eq "0 口不改动桥成员" 'eth0' "$(uci -q get network.@device[0].ports)"
eq "0 口主机名仍写入" 'ImmortalWrt' "$(uci -q get system.@system[0].hostname)"

finish UCI-DEFAULTS
