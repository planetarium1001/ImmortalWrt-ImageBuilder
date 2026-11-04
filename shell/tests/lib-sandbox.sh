#!/bin/sh
# 离线沙盒（被各用例 `.` 进来；不单独执行）。
#
# 为什么需要它：被测脚本里的路径全是固件绝对路径（/etc/config、/etc/init.d/network、
# /lib/functions/netports.sh、/usr/sbin/netprofile）。要在开发机上跑**真机路径**而不碰
# 宿主系统，就把这些前缀整体重定向到临时根（同一手法旧用例已用于 ipv6mode），
# 再用真 uci fake（lib-uci-stub.sh）+ 真机段形 fixture（fixtures/）驱动。
#
# 提供：
#   sb_new <名字>                建临时根、装 uci shim、把 PATH 前置
#   sb_fixture <net-anon|net-named|net-nodevice>
#   sb_script <仓库内脚本> <沙盒相对路径>   → 输出沙盒内的绝对路径
#   sb_netports                  装真实 netports.sh（内容不改，只换位置）
#   sb_initd                     记录型 /etc/init.d/{network,dnsmasq,odhcpd,firewall,minieap}
#   sb_sysfs <eth1:0000:02:00.0> …
#   sb_uci_get/sb_uci_show       便捷读取（走同一个 fake）
#   sb_reloads                   打印 init.d 调用记录
#
# 变量：SB_ROOT（沙盒根）、SB_RELOADS（init.d 调用记录）、UCI_STUB_DIR（配置目录）

TS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TS_DIR/../.." && pwd)

sb_new() { # <名字>
	# 一个用例里多次建沙盒时，先丢掉上一个（同一时刻只用最新的那一个）
	[ -n "${SB_ROOT:-}" ] && [ -d "$SB_ROOT" ] && rm -rf "$SB_ROOT"
	SB_ROOT=$(mktemp -d "/tmp/sb-$1.XXXXXX" 2>/dev/null) || {
		echo "无法创建沙盒目录" >&2
		exit 1
	}
	mkdir -p "$SB_ROOT/bin" "$SB_ROOT/uci" "$SB_ROOT/etc/config" \
		"$SB_ROOT/etc/init.d" "$SB_ROOT/etc/campus/nft" \
		"$SB_ROOT/lib/functions" "$SB_ROOT/usr/sbin" "$SB_ROOT/var"
	printf '#!/bin/sh\nexec sh "%s/lib-uci-stub.sh" "$@"\n' "$TS_DIR" >"$SB_ROOT/bin/uci"
	chmod +x "$SB_ROOT/bin/uci"
	UCI_STUB_DIR=$SB_ROOT/uci
	export UCI_STUB_DIR
	PATH=$SB_ROOT/bin:$PATH
	export PATH
	SB_RELOADS=$SB_ROOT/reloads.log
	export SB_RELOADS
	SB_MINIEAP_EN=$SB_ROOT/minieap.enabled
	export SB_MINIEAP_EN
	: >"$SB_RELOADS"
}

sb_fixture() { # <case>
	cp "$TS_DIR"/fixtures/common/* "$UCI_STUB_DIR"/
	cp "$TS_DIR/fixtures/$1/network" "$UCI_STUB_DIR/network"
}

# 把脚本里的固件绝对路径重定向到沙盒（只改副本，仓库文件不动）
sb_script() { # <源> <沙盒相对路径>
	_src=$1
	_dst=$SB_ROOT/$2
	mkdir -p "$(dirname "$_dst")"
	sed -e "s#/etc/#$SB_ROOT/etc/#g" \
		-e "s#/usr/sbin/#$SB_ROOT/usr/sbin/#g" \
		-e "s#/lib/functions/#$SB_ROOT/lib/functions/#g" \
		"$_src" >"$_dst"
	chmod +x "$_dst"
	printf '%s\n' "$_dst"
}

sb_netports() {
	cp "$REPO/files/lib/functions/netports.sh" "$SB_ROOT/lib/functions/netports.sh"
}

sb_initd() {
	for _s in network dnsmasq odhcpd firewall; do
		cat >"$SB_ROOT/etc/init.d/$_s" <<'EOS'
#!/bin/sh
echo "$(basename "$0") $*" >>"$SB_RELOADS"
exit 0
EOS
		chmod +x "$SB_ROOT/etc/init.d/$_s"
	done
	cat >"$SB_ROOT/etc/init.d/minieap" <<'EOS'
#!/bin/sh
case "${1:-}" in
enabled) [ -f "$SB_MINIEAP_EN" ]; exit $? ;;
enable) : >"$SB_MINIEAP_EN"; exit 0 ;;
disable) rm -f "$SB_MINIEAP_EN"; exit 0 ;;
start|stop) echo "minieap $1" >>"$SB_RELOADS"; exit 0 ;;
*) exit 0 ;;
esac
EOS
	chmod +x "$SB_ROOT/etc/init.d/minieap"
}

# 造 sysfs：参数形如 eth1:0000:02:00.0（无 PCI 信息的虚拟口用 sb_sysfs_nopci 补）
sb_sysfs() {
	SB_SYSFS=$SB_ROOT/sys
	mkdir -p "$SB_SYSFS/class/net"
	for _spec in "$@"; do
		_n=${_spec%%:*}
		_slot=${_spec#*:}
		mkdir -p "$SB_SYSFS/class/net/$_n/device"
		printf 'PCI_SLOT_NAME=%s\n' "$_slot" >"$SB_SYSFS/class/net/$_n/device/uevent"
	done
	# 真实 sysfs 里 lo / br-lan 没有 device 链接，必须被 netports_phys 过滤掉
	mkdir -p "$SB_SYSFS/class/net/lo" "$SB_SYSFS/class/net/br-lan"
	printf '%s\n' "$SB_SYSFS"
}

sb_uci_get() { uci -q get "$1" 2>/dev/null; }
sb_reloads() { cat "$SB_RELOADS" 2>/dev/null; }
sb_snapshot() { # <沙盒内相对路径>：内容指纹（cksum 是 POSIX 的），断言"配置未变"
	cksum "$SB_ROOT/$1" 2>/dev/null
}

# 装 campus nft 片段 + netprofile + ipv6mode 薄壳，并先跑 98-campus-nft.sh 建 include 段
# （真实链路：首启先建段，再由 netprofile 渲染片段 + 置 enabled）。
sb_profile_world() {
	sb_netports
	sb_initd
	mkdir -p "$SB_ROOT/etc/campus/nft"
	cp "$REPO"/files/etc/campus/nft/* "$SB_ROOT/etc/campus/nft/"
	CAMPUS_NFT_DIR=$SB_ROOT/etc/campus/nft
	export CAMPUS_NFT_DIR
	SB_PROFILE=$(sb_script "$REPO/files/usr/sbin/netprofile" usr/sbin/netprofile)
	SB_IPV6MODE=$(sb_script "$REPO/files/usr/sbin/ipv6mode" usr/sbin/ipv6mode)
	SB_CAMPUS_NFT=$(sb_script "$REPO/files/etc/uci-defaults/98-campus-nft.sh" etc/uci-defaults/98-campus-nft.sh)
	CAMPUS_LOG=/dev/null sh "$SB_CAMPUS_NFT" >/dev/null 2>&1 || true
}

# 记录型 init.d 的调用条数（断言"没有多余 reload"用）
sb_reload_count() { grep -c . "$SB_RELOADS" 2>/dev/null || true; }

# 全部 uci 包的内容指纹（比只看 network 更强：断言"整份配置未变"）
sb_uci_cksum() { cksum "$UCI_STUB_DIR"/* 2>/dev/null | awk '{printf "%s ", $1}'; }
