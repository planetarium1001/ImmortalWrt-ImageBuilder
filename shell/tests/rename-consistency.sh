#!/bin/sh
# ac-2：改名后配置、脚本、测试、文档四处一致
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAIL=0

[ -f "$ROOT/files/etc/config/ruijie-guard" ] && echo "ok: 配置 ruijie-guard" || { echo "FAIL: 缺配置 ruijie-guard"; FAIL=1; }
[ -x "$ROOT/files/usr/sbin/ruijie-guard" ] && echo "ok: 脚本 ruijie-guard 可执行" || { echo "FAIL: 脚本缺失或不可执行"; FAIL=1; }
[ -f "$ROOT/x86-64/docs/n5105/ruijie.md" ] && echo "ok: 文档 ruijie.md" || { echo "FAIL: 缺 ruijie.md"; FAIL=1; }
[ -f "$ROOT/shell/tests/ruijie-guard-toggle.sh" ] && echo "ok: 测试 ruijie-guard-toggle.sh" || { echo "FAIL: 缺测试"; FAIL=1; }

# 脚本读的 UCI 前缀必须与配置文件段名一致
grep -q 'ruijie-guard.globals' "$ROOT/files/usr/sbin/ruijie-guard" && echo "ok: 脚本 UCI 前缀一致" || { echo "FAIL: UCI 前缀不一致"; FAIL=1; }
grep -q "config guard 'globals'" "$ROOT/files/etc/config/ruijie-guard" && echo "ok: 配置段名正确" || { echo "FAIL: 配置段名不对"; FAIL=1; }

# profile 名与文档示例一致
grep -q "config profile 'ruijie'" "$ROOT/files/etc/config/wanprofile" && echo "ok: profile 名 ruijie" || { echo "FAIL: profile 名未改"; FAIL=1; }
grep -rq "wanmode apply ruijie" "$ROOT/x86-64/docs/n5105" && echo "ok: 文档示例一致" || { echo "FAIL: 文档示例未同步"; FAIL=1; }

# 首启脚本引用的命令必须存在
grep -q "/usr/sbin/ruijie-guard" "$ROOT/files/etc/uci-defaults/99-custom.sh" 2>/dev/null \
	|| echo "ok: 首启脚本未强依赖 ruijie-guard（无需处理）"

[ "$FAIL" = "0" ] && echo "RENAME OK" || echo "RENAME FAILED"
exit $FAIL
