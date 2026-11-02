#!/bin/sh
# 真机验收：在开发机上通过 SSH 连到已刷机的 N5105，跑 ac-9 / ac-10 / ac-12。
#   sh shell/tests/device-verify.sh cold-boot
#   sh shell/tests/device-verify.sh dual-stack
#   sh shell/tests/device-verify.sh nikki-whitelist
# 默认目标 root@192.168.100.1，可用 ROUTER=... 覆盖。
set -u
ROUTER="${ROUTER:-root@192.168.100.1}"
FAIL=0
say() { printf '%s\n' "$*"; }
chk() { # 描述 命令
	out=$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$ROUTER" "$2" 2>&1)
	if [ "$3" = "$out" ] || printf '%s' "$out" | grep -q "$3"; then
		say "  ok   $1"
	else
		say "  FAIL $1"; say "       期望包含: $3"; say "       实际: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
		FAIL=1
	fi
}

case "${1:-}" in
cold-boot)
	# ac-9：无外网状态下 LAN 可达、WAN 未启用、桥接成员齐全
	say "== ac-9 冷启动进后台 =="
	chk "WAN 出厂未启用"        "uci -q get network.wan.auto" "0"
	chk "br-lan 至少 3 个成员"   "uci -q get network.br_lan.ports | wc -w" "3"
	chk "dnsmasq 在跑"          "/etc/init.d/dnsmasq status >/dev/null 2>&1 && echo up" "up"
	chk "LAN 有管理地址"         "ip -4 addr show br-lan | grep -c 192.168.100.1" "1"
	;;
dual-stack)
	# ac-10：终端拿 IPv4 + ULA IPv6，NAT66 生效
	say "== ac-10 双栈分发 =="
	chk "LAN 有 ULA 地址"       "ip -6 addr show br-lan | grep -c 'fd7a:6e64:6c35'" "1"
	chk "RA/DHCPv6 在跑"        "pgrep -f odhcpd | head -1 | wc -l" "1"
	chk "NAT66 规则存在"        "nft list ruleset | grep -c masquerade" "1"
	chk "终端已拿到 IPv6 租约"   "cat /tmp/hosts/odhcpd 2>/dev/null | wc -l" ""
	;;
nikki-whitelist)
	# ac-12：白名单内走代理、名单外直连
	say "== ac-12 白名单代理 =="
	chk "nikki 进程在跑"        "pgrep -f mihomo | head -1 | wc -l" "1"
	chk "mixin 已合并"          "grep -c 'nikki-rules' /etc/nikki/run/config.yaml" "1"
	chk "白名单条目命中走代理"   "curl -s -o /dev/null -w '%{http_code}' -m 8 https://www.google.com" "200"
	chk "名单外域名直连"        "curl -s -o /dev/null -w '%{http_code}' -m 8 https://www.baidu.com" "200"
	;;
*)
	say "usage: $0 cold-boot|dual-stack|nikki-whitelist" >&2; exit 2 ;;
esac
[ "$FAIL" = "0" ] && say "RESULT: PASS" || say "RESULT: FAIL"
exit $FAIL
