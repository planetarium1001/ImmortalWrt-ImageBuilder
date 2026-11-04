#!/bin/sh
# 供 ipv6mode 记忆测试用的 uci 桩：支持 get/set/delete/add_list/del_list/show/commit
db=${UCI_STUB_DB:-/tmp/uci6.db}
touch "$db"
q=0
while [ $# -gt 0 ]; do
	case "$1" in -q) q=1; shift ;; *) break ;; esac
done
cmd=$1; shift
getk() { grep -F "$1=" "$db" 2>/dev/null | tail -n1 | sed 's/^[^=]*=//'; }
case "$cmd" in
	get)
		v=$(getk "$1")
		if [ -z "$v" ] && [ "$q" != "1" ]; then exit 1; fi
		printf '%s\n' "$v" ;;
	set)
		case "$1" in
			*=*) k=${1%%=*}; v=${1#*=} ;;
			*) k=$1; v=$2 ;;
		esac
		grep -vF "$k=" "$db" >"$db.t" 2>/dev/null; mv "$db.t" "$db" 2>/dev/null || : >"$db"
		echo "$k=$v" >>"$db" ;;
	delete|del_list)
		k=${1%%=*}
		grep -vF "$k=" "$db" >"$db.t" 2>/dev/null; mv "$db.t" "$db" ;;
	add_list)
		k=${1%%=*}; v=${1#*=}
		prev=$(getk "$k")
		grep -vF "$k=" "$db" >"$db.t" 2>/dev/null; mv "$db.t" "$db"
		if [ -n "$prev" ]; then echo "$k=$prev $v" >>"$db"; else echo "$k=$v" >>"$db"; fi ;;
	show)
		# 仅用于解析 wan zone：输出 firewall.<sec>.name='wan'
		sed -n "s/^\(firewall\.[^.]*\.name\)=\(.*\)$/\1='\2'/p" "$db" ;;
	commit|reload) : ;;
	*) : ;;
esac
