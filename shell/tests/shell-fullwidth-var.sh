#!/bin/sh
# 护栏：`$VAR` 紧跟非 ASCII 字符（中文全角标点）在 `set -u` 下会变成"未绑定的变量"。
#
# 为什么值得一条全仓护栏（2026-11-07 一天内踩中三次）：
#   `bad "…（opts: $opts）"` 里 `$opts）` 会被 shell 当成变量名 `opts）`；`set -u` 直接报
#   `opts：未绑定的变量` 并中断整条判据。更阴的是它**只出现在失败分支**——正向用例一路绿，
#   只有"故意破坏"的反向用例才走到这些消息，于是很容易被误读成"反向用例没生效"。
#   正确写法是 `${opts}`。本用例扫描全仓 shell 脚本（跳过注释行与非代码目录），把它挡在门外。
set -u
. "$(dirname "$0")/lib-assert.sh"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fwvar.XXXXXX")

# 匹配「$VAR 紧跟非 ASCII」，跳过注释行（注释不执行，写中文没问题）
FIND_BAD='my $line = $_; $line =~ s/^\s+//; print "$.: $line" if $line !~ /^#/ && $line =~ /\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])/;'

echo "== 1. 全仓 shell 脚本无「\$VAR 紧跟中文全角标点」（跳过注释行）=="
HITS=$(cd "$ROOT" && find . \
	-path ./.git -prune -o \
	-path ./.workflow -prune -o \
	-path ./.venv -prune -o \
	-path ./node_modules -prune -o \
	-path ./workspaces -prune -o \
	-type f -name '*.sh' -print 2>/dev/null |
	sed 's|^\./||' |
	while IFS= read -r _f; do
		[ -n "${_f}" ] || continue
		# 本用例自己要造"坏样例"字面量，跳过自身
		[ "${_f}" = 'shell/tests/shell-fullwidth-var.sh' ] && continue
		perl -ne "${FIND_BAD}" "${_f}" 2>/dev/null | sed "s|^|${_f}:|"
	done)
if [ -z "${HITS}" ]; then
	ok "未发现 \$VAR 紧跟非 ASCII 的代码行"
else
	bad "发现 \$VAR 紧跟非 ASCII 的代码行（改成 \${VAR}）"
	printf '%s\n' "${HITS}" | head -10 | sed 's/^/       /'
fi

echo "== 2. 护栏自身灵敏度（坏样例必须被抓到）=="
printf '#!/bin/sh\necho "x $foo）"\n' >"${SB_ROOT}/bad.sh"
if perl -ne "${FIND_BAD}" "${SB_ROOT}/bad.sh" 2>/dev/null | grep -q .; then
	ok "坏样例被抓到（护栏不是空转）"
else
	bad "坏样例没被抓到 —— 护栏失效"
fi

echo "== 3. 正确写法与注释不被误报 =="
printf '#!/bin/sh\necho "x ${foo}）"\n' >"${SB_ROOT}/good.sh"
if perl -ne "${FIND_BAD}" "${SB_ROOT}/good.sh" 2>/dev/null | grep -q .; then
	bad "花括号写法被误报"
else
	ok "花括号写法不被误报"
fi
printf '#!/bin/sh\n# 注释里写 $foo，是可以的\necho ok\n' >"${SB_ROOT}/comment.sh"
if perl -ne "${FIND_BAD}" "${SB_ROOT}/comment.sh" 2>/dev/null | grep -q .; then
	bad "注释行被误报（护栏会制造噪音）"
else
	ok "注释行不被误报"
fi

finish shell-fullwidth-var
