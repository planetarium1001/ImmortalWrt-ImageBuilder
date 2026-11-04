#!/bin/sh
# 测试用 uci —— **按 libuci 语义**实现的最小 fake（不是"扁平键值表"）。
#
# 为什么要有这一层（audit T1）：旧桩是一个扁平 key=value 表，
#   ① 没有"段"的概念，造不出 25.12 真实的匿名 config device / @zone[N] 段形；
#   ② 缺段不报错（自动建键）→ 真机上必然失败的调用在测试里全部"成功"；
#   ③ get 用未转义正则（`network.br_lan.ports` 里的 . 是通配），子串也能命中。
# 于是 31 项全绿而真机故障零覆盖。本 fake 直接解析**真实 UCI 文件格式**
# （config / option / list），并把 libuci 的错误语义照抄过来。
#
# 数据：每个包一个文件 `$UCI_STUB_DIR/<pkg>`（默认 /tmp/uci-stub），内容就是
# 真实 /etc/config/<pkg> 的文本 —— 测试既拿它当 fixture，也拿它断言"配置未变"。
#
# 用法：
#   PATH 前置一个名为 uci 的可执行脚本：`exec sh <this> "$@"`（见同目录 run-uci）
#   export UCI_STUB_DIR=/tmp/xxx     # 配置目录
#   sh lib-uci-stub.sh -c /tmp/xxx get network.lan.device
#
# 已实现的 libuci 语义（对照任务 pin 住的 uci 66127cd7：list.c / cli.c）：
#   get      段与键必须**精确**存在；否则 stderr "Entry not found" + 退出 1（-q 静音）。
#            解析只按"段名相等"或"@type[N]"索引，没有子串/正则匹配。
#   set      `set pkg.sec.opt=v` 要求段存在：缺段 → UCI_ERR_INVAL
#            （"Invalid argument"，list.c:603-605）+ 退出 1，**且不建段**。
#            只有 `set pkg.sec=<type>` 能建段（libuci 唯一的建段方式）。
#            值为空串 = 删除该 option（uci 的"空值即删除"）。
#   add_list 同样要求段存在（缺段 → Invalid argument，不建段）；对非列表 option → Parse error。
#   delete   缺段/缺键 → UCI_ERR_NOTFOUND（"Entry not found"）+ 退出 1，不建段。
#   show     `pkg.sec=type`；匿名段打印为 `pkg.@type[N]`；字符串单引号包起来，
#            列表打印成 `'a' 'b'`（与 uci-cli.c:128,198-211 一致）。
#   export   输出规范化后的 uci 文本（无注释）。
#   commit   提交；本 fake 每条写命令即落盘，且**无实质变化时不动文件**，
#            所以测试可以用 cmp 断言"配置逐字节未变"。
#   add      新建匿名段并打印其内部名（cfgXXXXXX 形态，同 libuci 观感）。
#
# 未实现（本仓用不到）：reorder / rename / import / -P 等。
# 退出码：0 成功；1 参数或存在性错误（同 uci）；2 本 fake 用法错误。

set -u

QUIET=0
CFGDIR=
while [ $# -gt 0 ]; do
	case "$1" in
		-q) QUIET=1; shift ;;
		-c) shift; CFGDIR=${1:-}; shift ;;
		-c*) CFGDIR=${1#-c}; shift ;;
		*) break ;;
	esac
done

CMD=${1:-}
[ $# -gt 0 ] && shift

DIR=${CFGDIR:-${UCI_STUB_DIR:-/tmp/uci-stub}}
mkdir -p "$DIR" 2>/dev/null || {
	printf 'uci: 无法创建配置目录 %s\n' "$DIR" >&2
	exit 1
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/uci-fake.XXXXXX" 2>/dev/null) || {
	printf 'uci: 无法创建临时目录\n' >&2
	exit 1
}
trap 'rm -rf "$TMPD"' 0

err() { if [ "$QUIET" != 1 ]; then printf 'uci: %s\n' "$*" >&2; fi }

# 取出本文件里以 #@<name>@ 开始、#@end@ 结束的内嵌 awk 程序
prog() {
	awk -v m="#@$1@" '
		$0 == m { p = 1; next }
		p && $0 == "#@end@" { p = 0 }
		p { print }
	' "$0"
}
AWK_PARSE=$(prog parse)
AWK_CORE=$(prog core)

load() { # pkg → $TMPD/ir（内部表示：S/O/L 记录）
	if [ -f "$DIR/$1" ]; then
		awk "$AWK_PARSE" "$DIR/$1" >"$TMPD/ir"
	else
		: >"$TMPD/ir"
	fi
}

store() { # pkg：把 $TMPD/ir.new 落盘；与现有文本一致时不触碰文件
	awk -v mode=dump -v pkg="$1" "$AWK_CORE" "$TMPD/ir.new" >"$TMPD/text"
	if [ -f "$DIR/$1" ] && cmp -s "$TMPD/text" "$DIR/$1"; then
		return 0
	fi
	cp "$TMPD/text" "$DIR/$1"
}

pkg_of() { printf '%s' "${1%%.*}"; }

# ---------- 读命令 ----------
do_get() {
	key=${1:-}
	[ -n "$key" ] || { err 'Invalid argument'; return 1; }
	pkg=$(pkg_of "$key")
	load "$pkg"
	out=$(awk -v mode=get -v key="$key" "$AWK_CORE" "$TMPD/ir")
	rc=$?
	if [ $rc -ne 0 ]; then
		err 'Entry not found'
		return 1
	fi
	printf '%s\n' "$out"
	return 0
}

do_show() {
	pkg=${1:-}
	if [ -n "$pkg" ]; then
		load "$pkg"
		awk -v mode=show -v pkg="$pkg" "$AWK_CORE" "$TMPD/ir"
		return 0
	fi
	for f in "$DIR"/*; do
		[ -f "$f" ] || continue
		p=$(basename "$f")
		load "$p"
		awk -v mode=show -v pkg="$p" "$AWK_CORE" "$TMPD/ir"
	done
	return 0
}

do_export() {
	pkg=${1:-}
	if [ -n "$pkg" ]; then
		[ -f "$DIR/$pkg" ] || { err 'Entry not found'; return 1; }
		load "$pkg"
		awk -v pkg="$pkg" "$AWK_CORE" "$TMPD/ir"
		return 0
	fi
	for f in "$DIR"/*; do
		[ -f "$f" ] || continue
		p=$(basename "$f")
		load "$p"
		awk -v pkg="$p" "$AWK_CORE" "$TMPD/ir"
	done
	return 0
}

# ---------- 写命令 ----------
do_mutate() { # cmd key value
	key=${2:-}
	[ -n "$key" ] || { err 'Invalid argument'; return 1; }
	pkg=$(pkg_of "$key")
	load "$pkg"
	awk -v mode=op -v cmd="$1" -v key="$key" -v val="${3:-}" \
		"$AWK_CORE" "$TMPD/ir" >"$TMPD/ir.new"
	rc=$?
	case $rc in
		0) store "$pkg"; return 0 ;;
		3) err 'Invalid argument'; return 1 ;;
		4) err 'Entry not found'; return 1 ;;
		5) err 'Parse error (option is not a list)'; return 1 ;;
		*) err 'Invalid argument'; return 1 ;;
	esac
}

do_add() { # add <pkg> <type>
	pkg=${1:-}
	typ=${2:-}
	[ -n "$pkg" ] && [ -n "$typ" ] || { err 'Invalid argument'; return 1; }
	load "$pkg"
	awk -v mode=add -v typ="$typ" "$AWK_CORE" "$TMPD/ir" >"$TMPD/ir.new" ||
		{ err 'Invalid argument'; return 1; }
	newname=$(awk -v mode=lastname -v typ="$typ" "$AWK_CORE" "$TMPD/ir.new")
	store "$pkg"
	printf '%s\n' "$newname"
	return 0
}

case "$CMD" in
	get)
		do_get "${1:-}" || exit 1
		exit 0
		;;
	changes)
		# 本 fake 立即落盘，没有未提交的 delta
		exit 0
		;;
	show) do_show "${1:-}" ;;
	export) do_export "${1:-}" ;;
	set)
		k=${1:-}
		v=${2:-}
		case "$k" in
			*=*) v=${k#*=}; k=${k%%=*} ;;
		esac
		do_mutate set "$k" "$v" || exit 1
		exit 0
		;;
	add_list)
		k=${1:-}
		v=${2:-}
		case "$k" in
			*=*) v=${k#*=}; k=${k%%=*} ;;
		esac
		do_mutate add_list "$k" "$v" || exit 1
		exit 0
		;;
	del_list)
		k=${1:-}
		v=${2:-}
		case "$k" in
			*=*) v=${k#*=}; k=${k%%=*} ;;
		esac
		do_mutate del_list "$k" "$v" || exit 1
		exit 0
		;;
	delete)
		do_mutate delete "${1:-}" '' || exit 1
		exit 0
		;;
	add)
		do_add "${1:-}" "${2:-}" || exit 1
		exit 0
		;;
	commit|reload)
		exit 0
		;;
	''|-h|--help)
		printf '用法: uci [-q] [-c DIR] get|set|add_list|del_list|delete|show|export|commit|add ...\n' >&2
		exit 1
		;;
	*)
		err "未知命令 [$CMD]"
		exit 1
		;;
esac
exit 0

#@parse@
# 真实 uci 文本 → 内部记录（S 段 / O option / L list，制表符分隔，\036 代表空串）
function toks(s,   i, c, cur, q, n) {
	n = 0; cur = ""; q = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (q != "") {
			if (c == q) q = ""; else cur = cur c
			continue
		}
		if (c == "'" || c == "\"") { q = c; continue }
		if (c == " " || c == "\t") {
			if (cur != "") { TOK[++n] = cur; cur = "" }
			continue
		}
		cur = cur c
	}
	if (cur != "") TOK[++n] = cur
	return n
}
function enc(s) { return (s == "") ? "\036" : s }
{
	line = $0
	gsub(/\r/, "", line)
	sub(/^[ \t]+/, "", line)
	sub(/[ \t]+$/, "", line)
	if (line == "" || substr(line, 1, 1) == "#") next
	kw = line
	sub(/[ \t].*$/, "", kw)
	rest = (kw == line) ? "" : substr(line, length(kw) + 2)
	if (kw == "config") {
		n = toks(rest)
		typ = (n >= 1) ? TOK[1] : ""
		nm = (n >= 2) ? TOK[2] : ""
		id = ++sid
		printf "S\t%d\t%s\t%s\n", id, enc(typ), enc(nm)
		cur = id
		next
	}
	if (kw == "option" || kw == "list") {
		if (cur == 0) next
		n = toks(rest)
		if (n < 1) next
		k = TOK[1]
		v = ""
		for (i = 2; i <= n; i++) v = v ((i > 2) ? " " : "") TOK[i]
		printf "%s\t%d\t%s\t%s\n", (kw == "list" ? "L" : "O"), cur, enc(k), enc(v)
		next
	}
}
#@end@

#@core@
BEGIN { FS = "\t"; N = 0; rc = 0 }
function dec(s) { return (s == "\036") ? "" : s }
function enc(s) { return (s == "") ? "\036" : s }
function qq(s) { return "'" s "'" }

$1 == "S" { N++; rk[N] = "S"; rid[N] = $2; if ($2 + 0 > maxid) maxid = $2 + 0; rtyp[N] = dec($3); rnam[N] = dec($4); next }
$1 == "O" { N++; rk[N] = "O"; rid[N] = $2; if ($2 + 0 > maxid) maxid = $2 + 0; rkey[N] = dec($3); rval[N] = dec($4); next }
$1 == "L" { N++; rk[N] = "L"; rid[N] = $2; if ($2 + 0 > maxid) maxid = $2 + 0; rkey[N] = dec($3); rval[N] = dec($4); next }

# 匿名段的内部名：libuci 也是 cfg+6 位十六进制（每个 load 重新生成，脚本不应依赖）
function cfgname(n) { return sprintf("cfg%06x", (rid[n] * 2654435761) % 16777216) }

# 段地址 → 记录下标；0 表示不存在
function secidx(a,   i, j, typ, idx, nm, n) {
	if (a == "") return 0
	if (substr(a, 1, 1) == "@") {
		if (!match(a, /\[-?[0-9]+\]$/)) return 0
		typ = substr(a, 2, RSTART - 2)
		idx = substr(a, RSTART + 1, RLENGTH - 2) + 0
		nm = 0
		for (i = 1; i <= N; i++)
			if (rk[i] == "S" && !del[i] && rtyp[i] == typ) ord[++nm] = i
		if (nm == 0) return 0
		# @type[0] 是第一个（libuci 0 基），@type[-1] 是最后一个
		if (idx >= 0) { n = idx + 1; return (n > nm) ? 0 : ord[n] }
		n = nm + idx + 1
		return (n < 1) ? 0 : ord[n]
	}
	for (i = 1; i <= N; i++) if (rk[i] == "S" && !del[i] && rnam[i] == a) return i
	for (i = 1; i <= N; i++) if (rk[i] == "S" && !del[i] && cfgname(i) == a) return i
	return 0
}

function addr_of(n,   i, c) {
	if (rnam[n] != "") return rnam[n]
	c = 0
	for (i = 1; i <= N; i++)
		if (rk[i] == "S" && !del[i] && rtyp[i] == rtyp[n]) {
			if (i == n) return "@" rtyp[n] "[" (c) "]"
			c++
		}
	return "@" rtyp[n] "[0]"
}

# 在 pos 之后插入一条记录
function splice_after(pos, kind, id, k, v,   j) {
	for (j = N; j > pos; j--) {
		rk[j + 1] = rk[j]; rid[j + 1] = rid[j]; rkey[j + 1] = rkey[j]
		rval[j + 1] = rval[j]; rtyp[j + 1] = rtyp[j]; rnam[j + 1] = rnam[j]
		del[j + 1] = del[j]
	}
	N++
	rk[pos + 1] = kind; rid[pos + 1] = id; rkey[pos + 1] = k; rval[pos + 1] = v
	rtyp[pos + 1] = ""; rnam[pos + 1] = ""; del[pos + 1] = 0
	return pos + 1
}

function sec_last(id,   i, last) {
	last = 0
	for (i = 1; i <= N; i++) if (!del[i] && rid[i] == id) last = i
	return last
}

function flush(   i) {
	for (i = 1; i <= N; i++) {
		if (del[i]) continue
		if (rk[i] == "S") printf "S\t%s\t%s\t%s\n", rid[i], enc(rtyp[i]), enc(rnam[i])
		else printf "%s\t%s\t%s\t%s\n", rk[i], rid[i], enc(rkey[i]), enc(rval[i])
	}
}

function splitkey(key,   p, i) {
	p = index(key, ".")
	if (p == 0) { kpkg = key; krest = ""; return }
	kpkg = substr(key, 1, p - 1)
	krest = substr(key, p + 1)
	# 段地址 = 取到最后一个 "." 之前；`@type[N].opt` 与 `sec.opt` 都成立
	p = 0
	for (i = length(krest); i >= 1; i--) if (substr(krest, i, 1) == ".") { p = i; break }
	if (p == 0) { ksec = krest; kopt = "" }
	else { ksec = substr(krest, 1, p - 1); kopt = substr(krest, p + 1) }
}

END {
	if (mode == "op") {
		splitkey(key)
		si = secidx(ksec)
		if (cmd == "delete" || cmd == "del_list") {
			if (si == 0) { rc = 4; exit rc }
			if (kopt == "") { # 删整段
				del[si] = 1
				for (i = 1; i <= N; i++) if (rid[i] == rid[si]) del[i] = 1
				flush(); exit 0
			}
			found = 0
			for (i = 1; i <= N; i++)
				if (!del[i] && rid[i] == rid[si] && rkey[i] == kopt) {
					if (cmd == "del_list" && rk[i] == "L" && val != "" && rval[i] != val) continue
					del[i] = 1; found = 1
				}
			if (!found) { rc = 4; exit rc }
			flush(); exit 0
		}
		if (cmd == "set") {
			if (kopt == "") {
				# 段级：set pkg.sec=<type>（唯一建段方式）
				if (si == 0) {
					if (val == "") { rc = 3; exit rc }
					N++
					rk[N] = "S"; rid[N] = ++maxid; rtyp[N] = val; rnam[N] = ksec
					rkey[N] = ""; rval[N] = ""; del[N] = 0
					flush(); exit 0
				}
				if (val == "") {
					del[si] = 1
					for (i = 1; i <= N; i++) if (rid[i] == rid[si]) del[i] = 1
				} else rtyp[si] = val
				flush(); exit 0
			}
			if (si == 0) { rc = 3; exit rc }   # 缺段：Invalid argument，不建段
			last = 0; first = 0; nlist = 0
			for (i = 1; i <= N; i++)
				if (!del[i] && rid[i] == rid[si] && rkey[i] == kopt) {
					last = i
					if (first == 0) first = i
					if (rk[i] == "L") nlist = 1
				}
			if (first == 0) {
				if (val == "") { flush(); exit 0 }   # 空值 set 一个不存在的键：无操作
				splice_after(sec_last(rid[si]), "O", rid[si], kopt, val)
				flush(); exit 0
			}
			if (val == "") {
				for (i = 1; i <= N; i++)
					if (!del[i] && rid[i] == rid[si] && rkey[i] == kopt) del[i] = 1
				flush(); exit 0
			}
			# 就地更新第一条（保持顺序，便于"无变化则不落盘"）
			rk[first] = "O"; rtyp[first] = ""; rval[first] = val
			for (i = first + 1; i <= N; i++)
				if (!del[i] && rid[i] == rid[si] && rkey[i] == kopt) del[i] = 1
			flush(); exit 0
		}
		if (cmd == "add_list") {
			if (si == 0) { rc = 3; exit rc }    # 缺段：Invalid argument，不建段
			if (kopt == "") { rc = 3; exit rc }
			last = 0; nlist = 0; hasplain = 0
			for (i = 1; i <= N; i++)
				if (!del[i] && rid[i] == rid[si] && rkey[i] == kopt) {
					last = i
					if (rk[i] == "L") nlist = 1; else hasplain = 1
				}
			if (hasplain) { rc = 5; exit rc }   # 非列表 option
			if (last == 0) splice_after(sec_last(rid[si]), "L", rid[si], kopt, val)
			else splice_after(last, "L", rid[si], kopt, val)
			flush(); exit 0
		}
		rc = 3
		exit rc
	}

	if (mode == "add") {
		N++
		rid[N] = ++maxid; rk[N] = "S"; rtyp[N] = typ; rnam[N] = ""
		rkey[N] = ""; rval[N] = ""; del[N] = 0
		flush()
		exit 0
	}

	if (mode == "lastname") {
		for (i = 1; i <= N; i++) if (rk[i] == "S" && rtyp[i] == typ) last = i
		if (last) printf "%s\n", cfgname(last)
		exit 0
	}

	if (mode == "dump") {
		for (i = 1; i <= N; i++) {
			if (del[i]) continue
			if (rk[i] == "S") {
				if (rnam[i] == "") printf "config %s\n", rtyp[i]
				else printf "config %s %s\n", rtyp[i], qq(rnam[i])
				continue
			}
			printf "\t%s %s %s\n", (rk[i] == "L" ? "list" : "option"), rkey[i], qq(rval[i])
		}
		exit 0
	}

	if (mode == "get") {
		splitkey(key)
		if (kpkg == "" || krest == "") { rc = 3; exit rc }
		si = secidx(ksec)
		if (si == 0) { rc = 4; exit rc }
		if (kopt == "") {
			printf "%s\n", (rnam[si] != "" ? rnam[si] : cfgname(si))
			exit 0
		}
		found = 0; out = ""; islist = 0
		for (i = 1; i <= N; i++)
			if (!del[i] && rid[i] == rid[si] && rkey[i] == kopt) {
				found = 1
				if (rk[i] == "L") { islist = 1; out = out (out == "" ? "" : " ") rval[i] }
				else out = rval[i]
			}
		if (!found) { rc = 4; exit rc }
		printf "%s\n", out
		exit 0
	}

	if (mode == "show") {
		for (i = 1; i <= N; i++) {
			if (rk[i] != "S" || del[i]) continue
			printf "%s.%s=%s\n", pkg, addr_of(i), rtyp[i]
			seen = ""
			for (j = 1; j <= N; j++) {
				if (rk[j] == "S" || del[j] || rid[j] != rid[i]) continue
				if (index("\n" seen "\n", "\n" rkey[j] "\n")) continue
				seen = seen "\n" rkey[j]
				if (rk[j] == "L") {
					s = ""
					for (k = 1; k <= N; k++)
						if (!del[k] && rid[k] == rid[i] && rk[k] == "L" && rkey[k] == rkey[j])
							s = s (s == "" ? "" : " ") qq(rval[k])
					printf "%s.%s.%s=%s\n", pkg, addr_of(i), rkey[j], s
				} else {
					printf "%s.%s.%s=%s\n", pkg, addr_of(i), rkey[j], qq(rval[j])
				}
			}
		}
		exit 0
	}

	exit 0
}
#@end@
