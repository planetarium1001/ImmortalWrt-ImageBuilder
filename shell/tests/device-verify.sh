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

stage_overlay() {
	echo "== ac-11 btrfs 子卷写层 =="
	chk "btrfs 模块已加载（/proc/filesystems 有 btrfs）" 'grep -qw btrfs /proc/filesystems'
	chk "/overlay 的 fstype 是 btrfs" '[ "$(awk \'\''$2=="/overlay"{print $3}'\'' /proc/mounts)" = btrfs ]'
	chk "/overlay 挂的是子卷 @overlay" 'grep -q "subvol=@overlay\|subvolid=" /proc/mounts && btrfs subvolume show /overlay 2>/dev/null | grep -q "Name:.*@overlay\|@overlay"'
	# 注意：/ 是 overlayfs，df / 与 df /overlay 是同一个 btrfs 池，两者相等恒真（审计点名）。
	# 改与**整盘**容量比：p3 应占满除 p1(32MiB)+p2(512MiB) 之外的盘尾。
	chk "/overlay 至少用到整盘的 90%（p3 已扩满）" \
		'ov=$(df -Pm /overlay | awk "NR==2{print \$2}"); dev=$(awk "\$2==\"/overlay\"{print \$1}" /proc/mounts); d=$(basename "$dev" | sed "s/p\{0,1\}[0-9]*$//"); sz=$(cat /sys/class/block/"$d"/size 2>/dev/null); [ -n "$sz" ] && [ "$ov" -ge $(( sz / 2048 * 90 / 100 )) ]'
	chk "btrfs 上有 @overlay/@docker/@swap 三个子卷" \
		'btrfs subvolume list /overlay 2>/dev/null | grep -q @overlay && btrfs subvolume list /overlay 2>/dev/null | grep -q @docker && btrfs subvolume list /overlay 2>/dev/null | grep -q @swap'
	chk "@docker 挂在 /opt/docker" 'awk "\$2==\"/opt/docker\"{f=1} END{exit !f}" /proc/mounts'
	chk "@swap 挂在 /swap" 'awk "\$2==\"/swap\"{f=1} END{exit !f}" /proc/mounts'
	chk "@data 挂在 /data" 'awk "\$2==\"/data\"{f=1} END{exit !f}" /proc/mounts'
	chk "/opt/docker 与 /swap 根目录带 NOCOW（C）标志" \
		'lsattr -d /opt/docker 2>/dev/null | grep -q C && lsattr -d /swap 2>/dev/null | grep -q C'
	chk "swapfile 在 /swap/swapfile 且已启用" 'swapon 2>/dev/null | grep -q "/swap/swapfile"'
	# 出厂值是 "/opt/docker/"（带尾斜杠），等值比较会假红
	chk "docker data_root 指向 /opt/docker" \
		'! command -v dockerd >/dev/null 2>&1 || [ "$(uci -q get dockerd.globals.data_root | sed "s:/*$::")" = /opt/docker ]'
	chk "首启日志无 extroot 失败（近 500 行）" '! logread 2>/dev/null | tail -500 | grep -q "extroot:.*cannot find device"'
}

case "${1:-all}" in
cold-boot) stage_cold_boot ;;
dual-stack) stage_dual_stack ;;
nikki-whitelist) stage_nikki ;;
overlay) stage_overlay ;;
all)
	stage_cold_boot
	stage_dual_stack
	stage_nikki
	stage_overlay
	;;
*)
	echo "usage: ROUTER=root@<ip> $0 [cold-boot|dual-stack|nikki-whitelist|overlay|all]" >&2
	exit 2
	;;
esac

if [ "$FAIL" = 0 ]; then
	echo "DEVICE VERIFY OK"
	exit 0
fi
echo "DEVICE VERIFY FAILED"
exit 1
