#!/bin/sh
# ac-2/T4：不整份覆盖 network/dhcp/firewall。
# 旧断言 `grep 'uci add_list "network.$sec.ports'` 把 25.12 不存在的段形钉进了测试，
# 这里改成：① 仓库里不许有整份覆盖文件；② 跑完首启 + netprofile 后**上游内容仍在**。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

echo "== 仓库形态：无整份覆盖文件 =="
for f in network dhcp firewall; do
	if [ -e "$REPO/files/etc/config/$f" ]; then
		bad "仍覆盖 $f"
	else
		ok "未覆盖 $f"
	fi
done
hits=$(grep -rn "cp .*/etc/config/\(network\|dhcp\|firewall\)" "$REPO/files" 2>/dev/null)
eq "代码里没有整份 cp 覆盖" '' "$hits"

echo "== 行为：跑完首启 + netprofile campus 后上游内容仍在 =="
sb_new nooverride
sb_fixture net-anon
sb_netports
sb_initd
mkdir -p "$SB_ROOT/etc/campus/nft"
cp "$REPO"/files/etc/campus/nft/* "$SB_ROOT/etc/campus/nft/"
export CAMPUS_NFT_DIR="$SB_ROOT/etc/campus/nft"
S=$(sb_sysfs eth0:0000:01:00.0 eth1:0000:02:00.0 eth2:0000:03:00.0 eth3:0000:04:00.0)
export NETPORTS_SYSFS=$S
C=$(sb_script "$REPO/files/etc/uci-defaults/99-custom.sh" etc/uci-defaults/99-custom.sh)
D98=$(sb_script "$REPO/files/etc/uci-defaults/98-campus-nft.sh" etc/uci-defaults/98-campus-nft.sh)
P=$(sb_script "$REPO/files/usr/sbin/netprofile" usr/sbin/netprofile)

secs_before=$(uci show network | grep -c '^network\.[^.=]*=[a-z]*$' || true)
fw_rules_before=$(uci show firewall | grep -c '=rule$' || true)
dhcp_before=$(uci show dhcp | grep -c '=[a-z]*$' || true)

rc=0; CAMPUS_LOG=/dev/null sh "$D98" >/dev/null 2>&1 || rc=$?
eq "98-campus-nft 退出 0" '0' "$rc"
rc=0; NETPORTS_LOG=$SB_ROOT/np.log sh "$C" >/dev/null 2>&1 || rc=$?
eq "99-custom 退出 0" '0' "$rc"
rc=0; CAMPUS_NFT_DIR=$CAMPUS_NFT_DIR sh "$P" campus >/dev/null 2>&1 || rc=$?
eq "netprofile campus 退出 0" '0' "$rc"

eq "network 段数不变（没有整份替换）" "$secs_before" "$(uci show network | grep -c '^network\.[^.=]*=[a-z]*$' || true)"
eq "dhcp 段数不变" "$dhcp_before" "$(uci show dhcp | grep -c '=[a-z]*$' || true)"
eq "firewall rule 段数不变" "$fw_rules_before" "$(uci show firewall | grep -c '=rule$' || true)"
eq "lan zone 名未变" 'lan' "$(uci -q get firewall.@zone[0].name)"
eq "wan zone 名未变" 'wan' "$(uci -q get firewall.@zone[1].name)"
eq "defaults.forward 未变" 'REJECT' "$(uci -q get firewall.@defaults[0].forward)"
eq "allow rule 名未变" 'Allow-DHCP-Renew' "$(uci -q get firewall.@rule[0].name)"
eq "dnsmasq domain 未变" 'lan' "$(uci -q get dhcp.@dnsmasq[0].domain)"
eq "dhcp wan 仍 ignore" '1' "$(uci -q get dhcp.wan.ignore)"
eq "odhcpd leasefile 未变" '/tmp/hosts/odhcpd' "$(uci -q get dhcp.odhcpd.leasefile)"
eq "loopback 未变" '127.0.0.1' "$(uci -q get network.loopback.ipaddr)"
eq "桥成员是脚本写的值" 'eth1 eth2 eth3' "$(uci -q get network.@device[0].ports)"

echo "== 只增不改：新增的 include 段数是 5 =="
eq "新增 include 段" '5' "$(uci show firewall | grep -c '^firewall\.campus_[a-z]*=include$' || true)"


echo "== /etc/config 下只新增受控文件，且不覆盖 network/dhcp/firewall =="
# fstab 是有意新增的：extroot（target=/overlay）必须预烘在 squashfs 里，
# 否则 sysupgrade 重写 p2 后首启认不出 extroot（见任务 20261105-btrfs-overlay-rootfs design §3）。
extra=$(ls "$REPO/files/etc/config" 2>/dev/null | grep -vxE 'commands|nikki|swap|fstab' | tr '\n' ' ')
eq "files/etc/config 只含 commands/nikki/swap/fstab" '' "$extra"

CMD=$REPO/files/etc/config/commands
if [ -s "$CMD" ]; then
	n=$(grep -c '^config command' "$CMD")
	eq "commands 有 3 个按钮" '3' "$n"
	eq "每个按钮都有 name" '3' "$(grep -c "^[[:space:]]*option name " "$CMD")"
	eq "每个按钮都有 command" '3' "$(grep -c "^[[:space:]]*option command " "$CMD")"
	eq "全部指向 /usr/sbin/netprofile" '3' "$(grep -c "^[[:space:]]*option command '/usr/sbin/netprofile" "$CMD")"
else
	bad "files/etc/config/commands 缺失或为空"
fi

finish NO-OVERRIDE
