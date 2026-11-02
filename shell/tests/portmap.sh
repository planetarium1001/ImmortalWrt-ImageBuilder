#!/bin/sh
# ac-3：端口角色按 MAC/PCI 映射，与内核枚举顺序无关
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

make_sysfs() {
	dir=$1
	for spec in "$@"; do :; done
}

# 构造一个假 sysfs：三个网口，MAC 与槽位固定，但目录创建顺序故意打乱
build_fixture() {
	base=$1
	rm -rf "$base"; mkdir -p "$base/class/net"
	# eth0 是"第三个"被创建，模拟内核枚举与物理顺序不一致
	mk() {
		name=$1; mac=$2; slot=$3
		d="$base/class/net/$name"
		mkdir -p "$d/device"
		echo "$mac" >"$d/address"
		printf 'DRIVER=igc\nPCI_SLOT_NAME=%s\n' "$slot" >"$d/device/uevent"
	}
	mk eth2 "aa:bb:cc:00:00:03" "0000:03:00.0"
	mk eth0 "aa:bb:cc:00:00:01" "0000:01:00.0"
	mk eth1 "aa:bb:cc:00:00:02" "0000:02:00.0"
	mk eth3 "aa:bb:cc:00:00:04" "0000:04:00.0"
}

build_fixture /tmp/pm-sysfs

# uci 桩
mkdir -p /tmp/pm-bin
cp "$ROOT/shell/tests/run-uci" /tmp/pm-bin/uci
cp "$ROOT/shell/tests/lib-uci-stub.sh" /tmp/pm-bin/lib-uci-stub.sh
chmod +x /tmp/pm-bin/uci
export UCI_STUB_DB=/tmp/pm.db
: >"$UCI_STUB_DB"
cat >>"$UCI_STUB_DB" <<DB
portmap.wan=port
portmap.wan.role=wan
portmap.wan.macaddr=aa:bb:cc:00:00:01
portmap.lan1=port
portmap.lan1.role=lan
portmap.lan1.macaddr=aa:bb:cc:00:00:02
portmap.lan2=port
portmap.lan2.role=lan
portmap.lan2.macaddr=aa:bb:cc:00:00:03
portmap.lan3=port
portmap.lan3.role=lan
portmap.lan3.macaddr=aa:bb:cc:00:00:04
portmap.globals.fallback=eth9
DB

out=$(PATH=/tmp/pm-bin:$PATH sh "$ROOT/files/usr/sbin/portmap" resolve --sysfs /tmp/pm-sysfs 2>/dev/null)
echo "resolve(mac): $out"
case "$out" in
	*"wan=eth0"*) ;;
	*) echo "FAIL: wan 应为 eth0"; FAIL=1 ;;
esac
case "$out" in
	*eth1*eth2*) ;;
	*) echo "FAIL: lan 应包含 eth1 eth2"; FAIL=1 ;;
esac

# 只按 PCI 槽位匹配（MAC 留空）
: >"$UCI_STUB_DB"
cat >>"$UCI_STUB_DB" <<DB
portmap.wan=port
portmap.wan.role=wan
portmap.wan.pci_slot=0000:01:00.0
portmap.lan1=port
portmap.lan1.role=lan
portmap.lan1.pci_slot=0000:02:00.0
portmap.globals.fallback=eth9
DB
out2=$(PATH=/tmp/pm-bin:$PATH sh "$ROOT/files/usr/sbin/portmap" resolve --sysfs /tmp/pm-sysfs 2>/dev/null)
echo "resolve(pci): $out2"
case "$out2" in
	*"wan=eth0"*) ;;
	*) echo "FAIL: PCI 槽位匹配应得 wan=eth0"; FAIL=1 ;;
esac

[ "$FAIL" = "0" ] && echo "PORTMAP OK" || echo "PORTMAP FAILED"
exit $FAIL
