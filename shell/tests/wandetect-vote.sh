#!/bin/sh
# ac-6：多探针投票按阈值判定
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W="$ROOT/files/usr/sbin/wandetect"
mkdir -p /tmp/wd-bin
cp "$ROOT/shell/tests/run-uci" /tmp/wd-bin/uci
cp "$ROOT/shell/tests/lib-uci-stub.sh" /tmp/wd-bin/lib-uci-stub.sh
chmod +x /tmp/wd-bin/uci
export UCI_STUB_DB=/tmp/wd.db
: >"$UCI_STUB_DB"
cat >>"$UCI_STUB_DB" <<DB
wandetect.globals.quorum_online=2
wandetect.globals.quorum_offline=0
DB
FAIL=0
chk() {
	got=$(PATH=/tmp/wd-bin:$PATH sh "$W" verdict --http-ok "$1" --http-total "$2" --icmp-ok "$3" 2>/dev/null)
	if [ "$got" != "$4" ]; then
		echo "FAIL: ok=$1/$2 icmp=$3 期望 $4 实际 $got"; FAIL=1
	else
		echo "ok: ok=$1/$2 icmp=$3 -> $got"
	fi
}
chk 6 6 3 online
chk 2 6 0 online      # 宽松成功侧：达到 quorum 即在线
chk 1 6 3 degraded    # 中间态：只告警
chk 1 6 0 degraded
chk 0 6 3 degraded    # 有 ICMP 但无 HTTP：疑似劫持，仍不判 failed
chk 0 6 0 failed      # 全失败才判 failed

# 阈值可配置
sed 's/quorum_online=2/quorum_online=4/' "$UCI_STUB_DB" >"$UCI_STUB_DB.new" && mv "$UCI_STUB_DB.new" "$UCI_STUB_DB"
chk 3 6 3 degraded
sed 's/quorum_online=4/quorum_online=2/' "$UCI_STUB_DB" >"$UCI_STUB_DB.new" && mv "$UCI_STUB_DB.new" "$UCI_STUB_DB"

[ "$FAIL" = "0" ] && echo "WANDETECT OK" || echo "WANDETECT FAILED"
exit $FAIL
