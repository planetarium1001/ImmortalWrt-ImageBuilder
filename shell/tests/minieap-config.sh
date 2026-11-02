#!/bin/sh
# ac-5：minieap 配置生成正确（rjv3、超时参数、账号特殊字符转义）
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p /tmp/mi-bin
cp "$ROOT/shell/tests/run-uci" /tmp/mi-bin/uci
cp "$ROOT/shell/tests/lib-uci-stub.sh" /tmp/mi-bin/lib-uci-stub.sh
chmod +x /tmp/mi-bin/uci
export UCI_STUB_DB=/tmp/mi.db
FAIL=0

: >"$UCI_STUB_DB"
cat >>"$UCI_STUB_DB" <<DB
wanprofile.ruijie=profile
wanprofile.ruijie.proto=minieap
wanprofile.ruijie.username=20230001
wanprofile.ruijie.password=p@ss w0rd'x
wanprofile.ruijie.module=rjv3
wanprofile.ruijie.dhcp_type=1
wanprofile.home=profile
wanprofile.home.proto=dhcp
wanprofile.globals.active=ruijie
DB

PATH=/tmp/mi-bin:$PATH sh "$ROOT/files/usr/sbin/wanmode" apply ruijie >/dev/null 2>&1
proto=$(sed -n 's/^network\.wan\.proto=//p' "$UCI_STUB_DB" | tail -1)
user=$(sed -n 's/^network\.wan\.username=//p' "$UCI_STUB_DB" | tail -1)
mod=$(sed -n 's/^network\.wan\.module=//p' "$UCI_STUB_DB" | tail -1)
auto=$(sed -n 's/^network\.wan\.auto=//p' "$UCI_STUB_DB" | tail -1)

[ "$proto" = "minieap" ] && echo "ok: proto=minieap" || { echo "FAIL: proto=$proto"; FAIL=1; }
[ "$mod" = "rjv3" ] && echo "ok: module=rjv3" || { echo "FAIL: module=$mod"; FAIL=1; }
[ "$auto" = "1" ] && echo "ok: auto=1" || { echo "FAIL: auto=$auto"; FAIL=1; }
[ "$user" = "20230001" ] && echo "ok: username 原样保留" || { echo "FAIL: username=$user"; FAIL=1; }

# 密码含空格与引号必须完整保留（写入的是 UCI 值，不能被 shell 截断）
case "$(sed -n 's/^network\.wan\.password=//p' "$UCI_STUB_DB" | tail -1)" in
	"p@ss w0rd'x") echo "ok: password 含空格与引号完整保留" ;;
	*) echo "FAIL: password 被截断"; FAIL=1 ;;
esac

# 切到 dhcp 应清掉账号
PATH=/tmp/mi-bin:$PATH sh "$ROOT/files/usr/sbin/wanmode" apply home >/dev/null 2>&1
if sed -n 's/^network\.wan\.username=//p' "$UCI_STUB_DB" | grep -q .; then
	echo "FAIL: 切到 dhcp 后 username 未清除"; FAIL=1
else
	echo "ok: 切到 dhcp 清除账号"
fi

[ "$FAIL" = "0" ] && echo "MINIEAP OK" || echo "MINIEAP FAILED"
exit $FAIL
