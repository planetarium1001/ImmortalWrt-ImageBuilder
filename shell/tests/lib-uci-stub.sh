#!/bin/sh
# 测试用的最小 uci 桩：只实现本仓脚本用到的子集。
# 用法：在 PATH 前置一个名为 uci 的可执行脚本，内容为 `exec sh <this> "$@"`
# 数据文件由 UCI_STUB_DB 指定，格式为 key=value（key 形如 network.wan.proto）。
uci() {
	q=0
	while [ $# -gt 0 ]; do
		case "$1" in
			-q) q=1; shift ;;
			*) break ;;
		esac
	done
	cmd=$1; shift
	db=${UCI_STUB_DB:-/tmp/uci-stub.db}
	touch "$db"

	case "$cmd" in
		get)
			key=$1
			v=$(sed -n "s/^${key}=//p" "$db" | tail -n1)
			if [ -z "$v" ] && [ "$q" != "1" ]; then exit 1; fi
			printf '%s\n' "$v"
			;;
		set)
			case "$1" in
				*=*) echo "$1" >>"$db" ;;
				*) key=$1; val=$2; echo "${key}=${val}" >>"$db" ;;
			esac
			;;
		add_list)
			key=${1%%=*}; val=${1#*=}
			prev=$(sed -n "s/^${key}=//p" "$db" | tail -n1)
			[ -n "$prev" ] && val="$prev $val"
			echo "${key}=${val}" >>"$db"
			;;
		del_list|delete)
			key=${1%%=*}
			grep -v "^${key}=" "$db" >"$db.tmp" 2>/dev/null; mv "$db.tmp" "$db"
			;;
		commit|reload) : ;;
		show)
			# 从 db 还原出 section 列表：xxx=port 形式
			sed -n 's/^\([a-zA-Z0-9_]*\.[a-zA-Z0-9_]*\)=port$/\1=port/p' "$db"
			;;
		*) : ;;
	esac
}

uci "$@"
