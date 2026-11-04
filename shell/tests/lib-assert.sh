#!/bin/sh
# 断言小工具（被各用例 `.` 进来；不单独执行）。
# 约定：每个用例最后调 finish <名字>，它按 FAIL 出 "NAME OK"/"NAME FAILED" 并给退出码。

FAIL=0

ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAIL=1; }

eq() { # 描述 期望 实际
	if [ "${2:-}" = "${3:-}" ]; then
		ok "$1"
	else
		bad "$1"
		printf '       期望 [%s]\n       实际 [%s]\n' "${2:-}" "${3:-}"
	fi
}

ne() { # 描述 不应等于 实际
	if [ "${2:-}" != "${3:-}" ]; then
		ok "$1"
	else
		bad "$1"
		printf '       不应等于 [%s]\n' "${2:-}"
	fi
}

contains() { # 描述 期望子串 实际文本
	case "${3:-}" in
	*"${2:-}"*) ok "$1" ;;
	*)
		bad "$1"
		printf '       期望包含 [%s]\n       实际     [%s]\n' "${2:-}" "$(printf '%s' "${3:-}" | head -6 | tr '\n' '|')"
		;;
	esac
}

not_contains() { # 描述 不应出现的子串 实际文本
	case "${3:-}" in
	*"${2:-}"*) bad "$1"; printf '       不应出现 [%s]\n' "${2:-}" ;;
	*) ok "$1" ;;
	esac
}

finish() { # 用例名
	if [ "$FAIL" = 0 ]; then
		printf '%s OK\n' "$1"
		# 成功时清掉沙盒；失败时保留现场便于排查
		[ -n "${SB_ROOT:-}" ] && rm -rf "$SB_ROOT"
		exit 0
	fi
	printf '%s FAILED\n' "$1"
	[ -n "${SB_ROOT:-}" ] && printf '沙盒保留在 %s\n' "$SB_ROOT"
	exit 1
}
