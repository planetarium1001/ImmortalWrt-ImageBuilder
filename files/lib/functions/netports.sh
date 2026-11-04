#!/bin/sh
# 端口分配单一真源（仓库：files/lib/functions/netports.sh，装机后在 /lib/functions/）。
#
# 为什么必须有这一层：
#   25.12 出厂的 LAN 桥是**匿名** config device 段 —— 只有 `option name 'br-lan'`，
#   不存在 network.br_lan。真 uci 对缺段的 add_list/set 直接返回 UCI_ERR_INVAL
#   （"Invalid argument"，uci list.c:603-605），**不会建段**。所以"猜段名再写"必然
#   静默失败：LAN 端口一个都没写进去，而 wan.device 已被设为首口，出厂的
#   `list ports 'eth0'` 原样保留 → 同一 netdev 既是 br-lan 成员又是 WAN → 灯亮、
#   拿不到上游地址、进不去后台。
#   因此端口写入必须先**定位**真实设备段；定位不到就放弃（fail-closed），
#   不允许任何兜底段名。
#
# 对外接口（POSIX sh，source 后直接调用）：
#   netports_phys                物理口列表，每行一个，按 PCI bus:dev.fn **数值**升序
#   netports_dev_section         LAN 桥设备段名（`@device[N]` 或命名段名）；失败返回 1
#   netports_find_device NAME    按 option name 找 type=device 段（诊断/复用）
#   netports_ports_of SEC        读某设备段的桥成员（uci get，空格分隔）
#   netports_apply [WAN] [LAN..] 写 wan.device / wan6.device / SEC.ports；
#                                失败回滚并返回 1；成功设置 NETPORTS_SEC/WAN/LAN
#
# 环境变量：
#   NETPORTS_SYSFS   sysfs 根，默认 /sys（测试注入）
#   NETPORTS_LOG     额外日志文件，可选
#
# 边界约定：
#   * netports_apply **不**做 uci commit —— 提交边界由调用方（99-custom / nicsync）决定。
#   * netports_apply **不** reload 网络 —— 同上。
#   * 无参数时按上游式分配：物理序首口为 WAN，其余全部入桥。

# 统一日志：优先走调用方定义的 log()（99-custom 写 uci-defaults-log.txt、
# nicsync 写自己的 log），同时落 stderr，避免失败被静默。
netports_log() {
	if [ -n "${NETPORTS_LOG:-}" ]; then
		printf '%s netports: %s\n' "$(date '+%F %T' 2>/dev/null)" "$*" >>"$NETPORTS_LOG" 2>/dev/null
	fi
	# 只调用调用方定义的 log() 函数（机上是 shell 函数；别误触 /usr/bin/log 之类的同名二进制）
	if [ "$(command -v log 2>/dev/null)" = "log" ]; then log "netports: $*"; fi
	printf 'netports: %s\n' "$*" >&2
}

# 物理口列表：按 PCI 槽位 bus:dev.fn 的**数值**升序。
# 字典序会把 0000:9:00.0 排在 0000:10:00.0 之后（N6），也会让 eth10 < eth2（C4）。
# 无 PCI 信息的口（虚拟网卡）排在最后，同组内按名字里的数字序。
netports_phys() {
	_np_sysfs=${NETPORTS_SYSFS:-/sys}
	for _np_dir in "$_np_sysfs"/class/net/*; do
		[ -e "$_np_dir/device" ] || continue
		_np_name=$(basename "$_np_dir")
		case "$_np_name" in eth*|en*) ;; *) continue ;; esac
		_np_slot=$(sed -n 's/^PCI_SLOT_NAME=//p' "$_np_dir/device/uevent" 2>/dev/null | head -n1)
		printf '%s %s\n' "${_np_slot:-none}" "$_np_name"
	done | awk '
		function h2d(s,   i, c, v, d) {
			v = 0
			s = tolower(s)
			for (i = 1; i <= length(s); i++) {
				c = substr(s, i, 1)
				d = index("0123456789abcdef", c) - 1
				if (d < 0) return -1
				v = v * 16 + d
			}
			return v
		}
		{
			name = $2
			slot = $1
			key = ""
			if (split(slot, p, /[:.]/) == 4 &&
			    h2d(p[2]) >= 0 && h2d(p[3]) >= 0 && h2d(p[4]) >= 0)
				key = sprintf("%05d%05d%03d", h2d(p[2]), h2d(p[3]), h2d(p[4]))
			if (key == "")
				key = sprintf("%05d%05d%03d", 99999, 99999, 999)
			suffix = name
			gsub(/^[^0-9]*/, "", suffix)
			if (suffix == "") suffix = "0"
			printf "%s %05d %s\n", key, suffix + 0, name
		}' | sort | awk '{ print $3 }'
}

# 按 option name 在 network 里找 type=device 的段；输出段名（@device[N] / 命名段）。
# 用 `uci show network` 一次拿全包，匿名段打印为 network.@device[N]=device，
# 命名段打印为 network.<sec>=device —— 两种段形都能命中。
netports_find_device() {
	_np_fd_want=${1:-}
	[ -n "$_np_fd_want" ] || return 0
	uci -q show network 2>/dev/null | awk -v want="$_np_fd_want" '
		function unq(s) { gsub(/\047/, "", s); return s }
		{
			eq = index($0, "=")
			if (eq == 0) next
			left = substr($0, 1, eq - 1)
			right = substr($0, eq + 1)
			if (left !~ /^network\./) next
			rest = substr(left, 9)
			if (rest !~ /\./) {
				# 段头行：network.<sec>=<type>
				if (unq(right) == "device") dev[rest] = 1
				next
			}
			if (rest ~ /\.name$/) {
				sec = rest
				sub(/\.name$/, "", sec)
				nm[sec] = unq(right)
			}
		}
		END {
			for (s in nm)
				if ((s in dev) && nm[s] == want) {
					print s
					exit 0
				}
		}'
}

# LAN 桥设备段：先取 network.lan.device，再找 name 等于它的设备段；
# 找不到再退 name=='br-lan'；仍找不到返回 1（调用方必须 fail-closed）。
netports_dev_section() {
	_np_ds_want=$(uci -q get network.lan.device 2>/dev/null)
	_np_ds_sec=""
	if [ -n "$_np_ds_want" ]; then
		_np_ds_sec=$(netports_find_device "$_np_ds_want")
	fi
	if [ -z "$_np_ds_sec" ]; then
		_np_ds_sec=$(netports_find_device br-lan)
	fi
	[ -n "$_np_ds_sec" ] || return 1
	printf '%s\n' "$_np_ds_sec"
	return 0
}

# 读桥成员（未设置时返回空串，不报错）。
netports_ports_of() {
	[ -n "${1:-}" ] || return 1
	uci -q get "network.$1.ports" 2>/dev/null
}

# 内部：一次性写 wan/wan6/桥成员；任一失败返回 1 交给回滚。
# wan/wan6 段不存在时才创建，创建时补默认 proto（否则会留下"没有 proto"的接口，
# netifd 起不来）；已存在的段一律不改 proto（不覆盖用户选的 pppoe 等）。
_netports_write_set() {
	_np_new_wan=0
	_np_new_wan6=0
	[ -z "$(uci -q get network.wan 2>/dev/null)" ] && _np_new_wan=1
	[ -z "$(uci -q get network.wan6 2>/dev/null)" ] && _np_new_wan6=1
	uci set network.wan=interface || return 1
	uci set network.wan.device="$_np_wan" || return 1
	[ "$_np_new_wan" = "1" ] && { uci set network.wan.proto='dhcp' || return 1; }
	uci set network.wan6=interface || return 1
	uci set network.wan6.device="$_np_wan" || return 1
	[ "$_np_new_wan6" = "1" ] && { uci set network.wan6.proto='dhcpv6' || return 1; }
	if [ -n "$(netports_ports_of "$_np_sec")" ]; then
		uci -q delete "network.$_np_sec.ports" || return 1
	fi
	for _np_p in $_np_lan; do
		uci add_list "network.$_np_sec.ports=$_np_p" || return 1
	done
	return 0
}

# 内部：把刚写的三个键恢复成原样（写失败不留下半套配置）。
_netports_rollback() {
	# 本次新建的段整段删掉，避免留下一个空壳 interface
	if [ "${_np_new_wan:-0}" = "1" ]; then
		uci -q delete network.wan 2>/dev/null
	elif [ -n "${_np_o_wan:-}" ]; then
		uci set network.wan.device="${_np_o_wan}" 2>/dev/null
	else
		uci -q delete network.wan.device 2>/dev/null
	fi
	if [ "${_np_new_wan6:-0}" = "1" ]; then
		uci -q delete network.wan6 2>/dev/null
	elif [ -n "${_np_o_wan6:-}" ]; then
		uci set network.wan6.device="${_np_o_wan6}" 2>/dev/null
	else
		uci -q delete network.wan6.device 2>/dev/null
	fi
	if [ -n "${_np_sec:-}" ]; then
		uci -q delete "network.$_np_sec.ports" 2>/dev/null
		for _np_p in ${_np_o_ports:-}; do
			uci add_list "network.$_np_sec.ports=$_np_p" 2>/dev/null
		done
	fi
	# 复核：回滚本身也失败时要显式说出来（此时必须人工恢复 network 配置）
	_np_back_wan=$(uci -q get network.wan.device 2>/dev/null)
	_np_back_ports=$(netports_ports_of "${_np_sec:-}")
	if [ "$_np_back_wan" != "${_np_o_wan:-}" ] ||
		[ "$(printf '%s' "$_np_back_ports" | tr -s ' ' ' ')" != "$(printf '%s' "${_np_o_ports:-}" | tr -s ' ' ' ')" ]; then
		netports_log "ERROR: 回滚未完全成功, 期望 wan=[${_np_o_wan:-}] lan=[${_np_o_ports:-}], 实际 wan=[$_np_back_wan] lan=[$_np_back_ports]; 请人工恢复 network 配置"
	fi
	netports_log "已回滚: wan=[${_np_o_wan:-}] lan=[${_np_o_ports:-}]"
	return 0
}

# 写端口。
#   netports_apply                       → wan=物理序首口, lan=其余
#   netports_apply <wan> <lan> [lan...]  → 显式指定（调用方仍应来自 netports_phys）
# 返回：0 成功；1 失败（未写或已回滚）。
netports_apply() {
	_np_phys=$(netports_phys)
	if [ -z "$_np_phys" ]; then
		netports_log "ERROR: 未发现物理网口，拒绝写端口"
		return 1
	fi

	if [ "$#" -eq 0 ]; then
		_np_wan=$(printf '%s\n' "$_np_phys" | head -n1)
		_np_lan=$(printf '%s\n' "$_np_phys" | tail -n +2 | tr '\n' ' ')
	else
		_np_wan=$1
		shift
		_np_lan=$*
	fi
	_np_lan=$(printf '%s' "$_np_lan" | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')

	if [ -z "$_np_wan" ] || [ -z "$_np_lan" ]; then
		netports_log "ERROR: 端口集合为空（wan=[$_np_wan] lan=[$_np_lan]），拒绝写端口"
		return 1
	fi

	# 只允许写真实现存的物理口，避免把不存在的名字写进桥
	for _np_p in $_np_wan $_np_lan; do
		if ! printf '%s\n' "$_np_phys" | grep -qx "$_np_p"; then
			netports_log "ERROR: $_np_p 不是当前存在的物理网口，拒绝写端口"
			return 1
		fi
	done

	# 写前断言：wan 不得同时是桥成员（端口重叠＝灯亮无地址）
	case " $_np_lan " in
		*" $_np_wan "*)
			netports_log "ERROR: wan=$_np_wan 同时出现在 LAN 集合 [$_np_lan] 里，拒绝写端口"
			return 1
			;;
	esac

	# 先定位段再动配置：定位失败时配置保持原样，不留半套
	_np_sec=$(netports_dev_section) || {
		netports_log "ERROR: 定位不到 LAN 设备段（network.lan.device 与 br-lan 均未命中），配置保持原样"
		return 1
	}

	_np_o_wan=$(uci -q get network.wan.device 2>/dev/null)
	_np_o_wan6=$(uci -q get network.wan6.device 2>/dev/null)
	_np_o_ports=$(netports_ports_of "$_np_sec")

	if ! _netports_write_set; then
		netports_log "ERROR: 写 uci 失败, 段=[$_np_sec], 回滚"
		_netports_rollback
		return 1
	fi

	# 写后复核同一不变量：wan 不能是桥成员
	_np_after=$(netports_ports_of "$_np_sec")
	case " $_np_after " in
		*" $_np_wan "*)
			netports_log "ERROR: 复核失败：wan=$_np_wan 仍在桥成员 [$_np_after] 里，回滚"
			_netports_rollback
			return 1
			;;
	esac

	NETPORTS_SEC=$_np_sec
	NETPORTS_WAN=$_np_wan
	NETPORTS_LAN=$_np_lan
	return 0
}
