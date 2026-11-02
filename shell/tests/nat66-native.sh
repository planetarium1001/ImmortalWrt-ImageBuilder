#!/bin/sh
# ac-11：NAT66/ULA/防火墙区域都是原生 UCI 配置
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FW="$ROOT/files/etc/config/firewall"
NW="$ROOT/files/etc/config/network"
DHCP="$ROOT/files/etc/config/dhcp"
FAIL=0

chk() { # file pattern description
	if grep -qE "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (缺 $2)"; FAIL=1; fi
}

chk "$FW" "option masq6 '1'" "WAN 区域启用 masq6（NAT66）"
chk "$FW" "option masq '1'" "WAN 区域保留 IPv4 masq"
chk "$NW" "ula_prefix 'fd" "ULA 前缀已配置"
chk "$NW" "ip6assign '60'" "LAN 分配 IPv6 前缀长度"
chk "$DHCP" "option ra 'server'" "RA 服务器开启"
chk "$DHCP" "option dhcpv6 'server'" "DHCPv6 服务器开启"
chk "$DHCP" "ndp 'disabled'" "NDP 关闭（避免终端地址暴露）"

# 不应出现 relay 模式
if grep -q "relay" "$DHCP"; then echo "FAIL: 出现了 relay 配置（应停用）"; FAIL=1; else echo "ok: 未使用 IPv6 relay"; fi

# firewall include 指向 /etc/firewall.user，保证 campus-guard 生效路径
chk "$FW" "option path '/etc/firewall.user'" "firewall include 指向 /etc/firewall.user"

[ "$FAIL" = "0" ] && echo "NAT66 OK" || echo "NAT66 FAILED"
exit $FAIL
