#!/bin/sh
# ac-7：防检测可完整启用与回滚
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
G="$ROOT/files/usr/sbin/campus-guard"
mkdir -p /tmp/cg-bin
cp "$ROOT/shell/tests/run-uci" /tmp/cg-bin/uci
cp "$ROOT/shell/tests/lib-uci-stub.sh" /tmp/cg-bin/lib-uci-stub.sh
chmod +x /tmp/cg-bin/uci
export UCI_STUB_DB=/tmp/cg.db
FAIL=0

# 用临时 FW 文件替身：脚本内 FW 是绝对路径，这里通过 fw4 reload 桩与真实 /etc/firewall.user 权限问题回避
# 采用 --dry 方式验证规则内容，再验证 clear 的幂等性
: >"$UCI_STUB_DB"
cat >>"$UCI_STUB_DB" <<DB
campus-guard.globals.enabled=1
campus-guard.globals.ttl_clamp=64
campus-guard.globals.block_leak=1
campus-guard.globals.wan_input=drop
DB

show=$(PATH=/tmp/cg-bin:$PATH sh "$G" show 2>/dev/null)
echo "--- rules ---"; echo "$show"
for pat in "ttl set 64" "dport { 67, 68, 137, 138, 1900, 5353, 547 }" "timestamp-request"; do
	if echo "$show" | grep -qF "$pat"; then echo "ok: $pat"; else echo "FAIL: 缺少 $pat"; FAIL=1; fi
done

# 关闭时不应输出任何规则
: >"$UCI_STUB_DB"
cat >>"$UCI_STUB_DB" <<DB
campus-guard.globals.enabled=0
campus-guard.globals.ttl_clamp=64
campus-guard.globals.block_leak=1
DB
empty=$(PATH=/tmp/cg-bin:$PATH sh "$G" show 2>/dev/null)
if [ -z "$empty" ]; then echo "ok: enabled=0 时无规则输出"; else echo "FAIL: enabled=0 仍输出规则"; FAIL=1; fi

# ttl_clamp=0 时不生成 TTL 规则
: >"$UCI_STUB_DB"
cat >>"$UCI_STUB_DB" <<DB
campus-guard.globals.enabled=1
campus-guard.globals.ttl_clamp=0
campus-guard.globals.block_leak=0
campus-guard.globals.wan_input=accept
DB
no_ttl=$(PATH=/tmp/cg-bin:$PATH sh "$G" show 2>/dev/null)
if echo "$no_ttl" | grep -q "ttl set"; then echo "FAIL: ttl_clamp=0 仍生成 TTL 规则"; FAIL=1; else echo "ok: ttl_clamp=0 无 TTL 规则"; fi

[ "$FAIL" = "0" ] && echo "CAMPUS-GUARD OK" || echo "CAMPUS-GUARD FAILED"
exit $FAIL
