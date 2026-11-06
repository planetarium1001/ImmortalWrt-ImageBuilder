#!/bin/sh
# 回归守卫：脚本要能在**开发机（macOS 的 sh = bash 3.2）**与**设备（busybox ash）**上真的跑起来。
#
# 背景（2026-11-06 真机验收时踩到）：
#   ① `pend "连不上 $ROUTER（或密钥未授权）"` —— `$ROUTER` 后面紧跟全角括号。
#      macOS 的 sh(bash 3.2) 在非 UTF-8 环境下会把多字节字节当成变量名的一部分，
#      `set -u` 下直接报 `ROUTER（: 未绑定的变量`，脚本一行没跑就死。
#      修法：紧邻非 ASCII 字符时必须写 `${VAR}`。
#   ② `chk "..." '[ "$(awk '\''$2=="/overlay"{print $3}'\'' /proc/mounts)" = btrfs ]'`
#      这种 `'\''` 嵌套引号经 ssh 传到远端 ash 会变成未闭合引号（`unterminated quoted string`）。
#   ③ `swapon`（无参数）在 OpenWrt 上是指向 /sbin/block 的软链，只打 usage 并 rc=255；
#      要看 swap 必须 `swapon -s`（真机实测）。
set -u
. "$(dirname "$0")/lib-assert.sh"

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO" || { bad "进不去仓库根目录"; echo "SHELL-PORTABILITY FAILED"; exit 1; }

echo "== \$VAR 后紧跟非 ASCII 字符时必须用 \${VAR}（macOS bash 3.2 会吞掉变量名）=="
# 只看代码行：注释里的示例不算违规。
bad_lines=$(perl -ne '
	next if /^\s*#/;
	print "$ARGV:$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]/;
' $(git ls-files 'files/usr/sbin/*' 'files/etc/init.d/*' 'files/etc/uci-defaults/*' 'files/lib/preinit/*' 'phase1/*.sh' 'phase1/tests/*.sh' 'phase1/tools/*.sh' 'shell/tests/*.sh' 'shell/*.sh' 'x86-64/*.sh' 2>/dev/null) 2>/dev/null)
if [ -z "$bad_lines" ]; then
	ok "没有 \$VAR 紧邻非 ASCII 的写法"
else
	bad "\$VAR 紧邻非 ASCII（改成 \${VAR}）"
	printf '%s\n' "$bad_lines" | sed 's/^/       /'
fi

echo "== 真机验收脚本不许用 '\"'\"' 这种嵌套引号（经 ssh 到远端 ash 会未闭合）=="
for f in shell/tests/device-verify.sh shell/tests/device-upgrade-check.sh; do
	[ -f "$f" ] || { bad "缺 $f"; continue; }
	hit=$(grep -nF "\\'\\\\''" "$f" || true)
	if [ -z "$hit" ]; then
		ok "$(basename "$f") 无嵌套引号"
	else
		bad "$(basename "$f") 还在用 '\\'' 嵌套引号"
		printf '%s\n' "$hit" | sed 's/^/       /'
	fi
done

echo "== 真机验收脚本用 swapon -s（OpenWrt 的 swapon 是 /sbin/block 软链，无参数 rc=255）=="
hit=$(grep -nE '(^|[^-_a-z])swapon[[:space:]]+2?>' shell/tests/device-verify.sh shell/tests/device-upgrade-check.sh || true)
if [ -z "$hit" ]; then
	ok "没有裸 swapon 调用"
else
	bad "裸 swapon 调用（改用 swapon -s）"
	printf '%s\n' "$hit" | sed 's/^/       /'
fi
grep -q 'swapon -s' shell/tests/device-verify.sh && ok "device-verify 用 swapon -s" || bad "device-verify 没用 swapon -s"

echo "== 没给 ROUTER 时要干净地 PEND（而不是死在未绑定变量上）=="
# 这一条是 ① 的行为面：静态扫描可能被新写法绕过，真正跑一次才证明脚本能启动到底。
_out=$(ROUTER= sh shell/tests/device-verify.sh 2>&1 || true)
case "$_out" in
*PEND*) ok "无 ROUTER 时输出 PEND" ;;
*)
	bad "无 ROUTER 时没有 PEND 输出"
	printf '%s\n' "$_out" | head -3 | sed 's/^/       /'
	;;
esac
case "$_out" in
*未绑定的变量* | *unbound*)
	bad "启动阶段报未绑定变量"
	printf '%s\n' "$_out" | head -3 | sed 's/^/       /'
	;;
*) ok "启动阶段无未绑定变量报错" ;;
esac

finish SHELL-PORTABILITY
