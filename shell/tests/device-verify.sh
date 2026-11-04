#!/bin/sh
# 真机验收（ac-9/ac-10/ac-12）：SSH 到已刷机的机器上跑**行为**断言。
#   ROUTER=root@192.168.100.1 sh shell/tests/device-verify.sh [cold-boot|dual-stack|nikki-whitelist|all]
#
# 无 ROUTER、或设备不可达 → 输出 PEND 并退出 2（all.sh 记为 PEND，不算失败）。
# 期望值已按 25.12 修正（audit T6）：不再引用 `network.br_lan.ports`（该段不存在）
# 与 `network.wan.auto`（config_generate 不设这个键）。
set -u
. "$(dirname "$0")/lib-assert.sh"

ROUTER="${ROUTER:-}"
FAIL=0
SSHOPT="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"

pend() {
	printf 'PEND: %s\n' "$*"
	printf 'DEVICE PENDING\n'
	exit 2
}

[ -n "$ROUTER" ] || pend "未设置 ROUTER=<user@host>；真机验收需要一台已刷机的设备"
# shellcheck disable=SC2086
ssh $SSHOPT "$ROUTER" true >/dev/null 2>&1 || pend "连不上 $ROUTER（或密钥未授权）"

rsh() { # 远程执行，返回远端退出码
	# shellcheck disable=SC2086
	ssh $SSHOPT "$ROUTER" "$1" 2>&1
}

chk() { # <描述> <远程命令：退出 0 视为通过>
	_out=$(rsh "$2")
	if [ $? -eq 0 ]; then
		ok "$1"
	else
		bad "$1"
		printf '       %s\n' "$(printf '%s' "$_out" | head -3 | tr '\n' '|')"
	fi
}

stage_cold_boot() {
	echo "== ac-9 冷启动进后台 =="
	chk "dnsmasq 在跑" '/etc/init.d/dnsmasq status >/dev/null 2>&1'
	chk "LAN 有管理地址 192.168.100.1" 'ip -4 addr show br-lan | grep -q 192.168.100.1'
	chk "nicsync --check 判定已对齐（退出 0）" '/usr/sbin/nicsync --check >/dev/null 2>&1'
	chk "桥成员至少 1 个" '[ "$(uci -q get network.@device[0].ports | wc -w)" -ge 1 ]'
	chk "wan.device 不在桥成员里（端口不重叠）" \
		'wan=$(uci -q get network.wan.device); case " $(uci -q get network.@device[0].ports) " in *" $wan "*) exit 1;; esac'
	chk "不存在凭空建出的 network.br_lan 段" '! uci -q get network.br_lan >/dev/null 2>&1'
	chk "hostname 为 ImmortalWrt" '[ "$(uci -q get system.@system[0].hostname)" = ImmortalWrt ]'
}

stage_dual_stack() {
	echo "== ac-10 双栈分发 =="
	chk "LAN 有 ULA 地址" 'ip -6 addr show br-lan | grep -q "fd7a:6e64:6c35"'
	chk "wan6 处于 up（V1：auto=1 才可能有地址）" '[ "$(ifstatus wan6 | jsonfilter -e "@.up")" = true ]'
	chk "wan6 拿到了上游 IPv6 地址（masq6 有源可 NAT）" \
		'ifstatus wan6 | grep -q "\"address\""'
	chk "odhcpd 在跑（RA/DHCPv6）" 'pgrep -f odhcpd >/dev/null 2>&1'
	chk "NAT66 规则存在" 'nft list ruleset | grep -q masquerade'
	chk "campus 防检测规则已生效" 'nft list ruleset | grep -q "!campus"'
	chk "profile 处于 campus" '[ "$(cat /etc/netprofile 2>/dev/null)" = campus ]'
}

stage_nikki() {
	echo "== ac-12 白名单代理（可选功能）=="
	if ! rsh 'command -v nikki >/dev/null 2>&1 || pgrep -f mihomo >/dev/null 2>&1'; then
		ok "未安装 nikki/mihomo，跳过本组（可选功能）"
		return 0
	fi
	chk "nikki 进程在跑" 'pgrep -f mihomo >/dev/null 2>&1'
	chk "mixin 已合并 nikki 规则" 'grep -q "nikki-rules" /etc/nikki/run/config.yaml'
	chk "白名单内走代理（google 200）" \
		'[ "$(curl -s -o /dev/null -w "%{http_code}" -m 8 https://www.google.com)" = 200 ]'
	chk "名单外直连（baidu 200）" \
		'[ "$(curl -s -o /dev/null -w "%{http_code}" -m 8 https://www.baidu.com)" = 200 ]'
}

case "${1:-all}" in
cold-boot) stage_cold_boot ;;
dual-stack) stage_dual_stack ;;
nikki-whitelist) stage_nikki ;;
all)
	stage_cold_boot
	stage_dual_stack
	stage_nikki
	;;
*)
	echo "usage: ROUTER=root@<ip> $0 [cold-boot|dual-stack|nikki-whitelist|all]" >&2
	exit 2
	;;
esac

if [ "$FAIL" = 0 ]; then
	echo "DEVICE VERIFY OK"
	exit 0
fi
echo "DEVICE VERIFY FAILED"
exit 1
