#!/bin/sh
# ac-2：模拟 sysfs 下 nicsync 把真实名字写进 UCI，且幂等
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/usr/sbin/nicsync"
FAIL=0

mkdir -p /tmp/ns-bin
cp "$ROOT/shell/tests/run-uci" /tmp/ns-bin/uci
cp "$ROOT/shell/tests/lib-uci-stub.sh" /tmp/ns-bin/lib-uci-stub.sh
chmod +x /tmp/ns-bin/uci
export UCI_STUB_DB=/tmp/ns.db

# 造 sysfs：四个口，名字故意不是 eth0-3（复现真机情形）
B=/tmp/ns-sysfs; rm -rf $B; mkdir -p $B/class/net
mk() { mkdir -p "$B/class/net/$1/device"; printf 'PCI_SLOT_NAME=%s\n' "$3" >"$B/class/net/$1/device/uevent"; }
mk eth1 0 0000:02:00.0
mk eth3 0 0000:03:00.0
mk eth5 0 0000:04:00.0
mk eth7 0 0000:05:00.0

: >"$UCI_STUB_DB"
cat >>"$UCI_STUB_DB" <<DB
network.wan.device=eth0
network.br_lan.ports=eth1 eth2 eth3
DB

out=$(PATH=/tmp/ns-bin:$PATH sh "$S" --sysfs "$B" 2>&1)
echo "$out"
case "$out" in
	*"wan=eth1"*) echo "ok: 选中第一个口为 WAN" ;;
	*) echo "FAIL: WAN 选择错误"; FAIL=1 ;;
esac
[ "$(sed -n 's/^network\.wan\.device=//p' "$UCI_STUB_DB" | tail -1)" = "eth1" ] && echo "ok: UCI wan.device 已写入" || { echo "FAIL: UCI 未更新"; FAIL=1; }
lan=$(sed -n 's/^network\.br_lan\.ports=//p' "$UCI_STUB_DB" | tail -1)
case "$lan" in
	*eth3*eth5*eth7*) echo "ok: br-lan 收到剩余三个口: $lan" ;;
	*) echo "FAIL: br-lan 端口不对: $lan"; FAIL=1 ;;
esac

# 幂等：再跑一次不应再改（输出应提示已对齐）
out2=$(PATH=/tmp/ns-bin:$PATH sh "$S" --sysfs "$B" 2>&1)
case "$out2" in
	*"wan=eth1"*) echo "ok: 二次执行幂等" ;;
	*) echo "FAIL: 幂等性破坏"; FAIL=1 ;;
esac

[ "$FAIL" = "0" ] && echo "NICSYNC OK" || echo "NICSYNC FAILED"
exit $FAIL
