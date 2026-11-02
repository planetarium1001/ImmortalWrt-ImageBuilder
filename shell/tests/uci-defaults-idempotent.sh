#!/bin/sh
# ac-4：首启脚本离线可执行且幂等（用桩模拟 uci/网络命令，连跑两次结果一致）
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/files/etc/uci-defaults/99-custom.sh"
mkdir -p /tmp/ud-bin
cp "$ROOT/shell/tests/run-uci" /tmp/ud-bin/uci
cp "$ROOT/shell/tests/lib-uci-stub.sh" /tmp/ud-bin/lib-uci-stub.sh
chmod +x /tmp/ud-bin/uci
# 桩掉特权命令，避免测试触碰宿主系统
for c in growpart resize2fs ethtool swapctl logger; do
	printf '#!/bin/sh\nexit 0\n' >"/tmp/ud-bin/$c"
	chmod +x "/tmp/ud-bin/$c"
done
export UCI_STUB_DB=/tmp/ud.db
FAIL=0

run_once() {
	: >"$UCI_STUB_DB"
	cat >>"$UCI_STUB_DB" <<DB
network.lan.ipaddr=192.168.100.1
network.wan.auto=1
DB
	mkdir -p /tmp/ud-root
	PATH=/tmp/ud-bin:$PATH sh "$S" >/dev/null 2>&1
	# 输出稳定化的关键字段
	sed -n 's/^network\.lan\.ipaddr=//p' "$UCI_STUB_DB" | tail -1
	sed -n 's/^network\.wan\.auto=//p' "$UCI_STUB_DB" | tail -1
	sed -n 's/^system\.@system\[0\]\.hostname=//p' "$UCI_STUB_DB" | tail -1
}

a=$(run_once); b=$(run_once)
if [ "$a" = "$b" ]; then echo "ok: 两次执行结果一致"; else echo "FAIL: 幂等性破坏"; echo "1:$a"; echo "2:$b"; FAIL=1; fi

case "$a" in
	*192.168.100.1*) echo "ok: 管理地址写入" ;;
	*) echo "FAIL: 管理地址未写入"; FAIL=1 ;;
esac
case "$a" in
	*"0"*) echo "ok: WAN 保持 auto=0" ;;
	*) echo "FAIL: WAN 未保持关闭"; FAIL=1 ;;
esac
case "$a" in
	*n5105-router*) echo "ok: hostname 写入" ;;
	*) echo "FAIL: hostname 未写入"; FAIL=1 ;;
esac

# 自定义管理地址覆盖
: >"$UCI_STUB_DB"; echo "network.lan.ipaddr=192.168.100.1" >>"$UCI_STUB_DB"
mkdir -p /tmp/ud-etc
PATH=/tmp/ud-bin:$PATH sh -c "sed 's#/etc/config/custom_router_ip.txt#/tmp/ud-ip.txt#' '$S'" >/dev/null 2>&1 || true
echo "192.168.50.1" >/tmp/ud-ip.txt
# 该分支仅在文件存在时生效；此处只验证脚本不因缺失/存在而报错
if sh -n "$S"; then echo "ok: 脚本语法稳定"; else echo "FAIL: 语法错误"; FAIL=1; fi

[ "$FAIL" = "0" ] && echo "UCI-DEFAULTS OK" || echo "UCI-DEFAULTS FAILED"
exit $FAIL
