#!/bin/sh
# ac-2：认证配置与上游对齐，启动只传 --conf-file
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONF="$ROOT/files/etc/minieap.conf"
INIT="$ROOT/files/etc/init.d/minieap"
FAIL=0

[ -f "$CONF" ] && echo "ok: 存在 /etc/minieap.conf" || { echo "FAIL: 缺 conf"; FAIL=1; }

# 必含键
for k in username= password= nic= module=; do
	grep -q "^$k" "$CONF" && echo "ok: 含键 $k" || { echo "FAIL: 缺键 $k"; FAIL=1; }
done

# 不得出现任何 IPv4/IPv6 相关键——minieap 只管认证
if grep -qE "^(ipaddr|netmask|gateway|ipv6|dhcp|dns)=" "$CONF"; then
	echo "FAIL: conf 中出现地址相关键"; FAIL=1
else
	echo "ok: 无地址相关键"
fi

# 启动命令只传 --conf-file
grep -q -- "--conf-file /etc/minieap.conf" "$INIT" && echo "ok: 传 --conf-file" || { echo "FAIL: 未传 conf"; FAIL=1; }
if grep -v "^[[:space:]]*#" "$INIT" | grep -q -- "--daemonize"; then
	echo "FAIL: init 不应使用 --daemonize（procd 会丢进程）"; FAIL=1
else
	echo "ok: 未使用 --daemonize"
fi
if grep -q "respawn 3600 5 0" "$INIT"; then echo "ok: respawn 不放弃"; else echo "FAIL: respawn 会永久放弃"; FAIL=1; fi
if grep -q "^dhcp-type=0" "$CONF"; then echo "ok: dhcp-type=0"; else echo "FAIL: 缺 dhcp-type=0"; FAIL=1; fi

if grep -qE "\-\-module|\-u |\-p |udhcpc" "$INIT"; then
	echo "FAIL: init 脚本注入了额外参数"; FAIL=1
else
	echo "ok: 未注入额外参数"
fi

# 账号为空时不启动（避免无意义重试）
grep -q "username 为空" "$INIT" && echo "ok: 空账号跳过" || { echo "FAIL: 未处理空账号"; FAIL=1; }

[ "$FAIL" = "0" ] && echo "MINIEAP-NATIVE OK" || echo "MINIEAP-NATIVE FAILED"
exit $FAIL
