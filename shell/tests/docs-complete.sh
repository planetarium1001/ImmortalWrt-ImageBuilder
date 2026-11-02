#!/bin/sh
# ac-14：文档覆盖刷写、回滚、AP 配置、profile 切换与合规提示
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D="$ROOT/x86-64/docs/n5105"
FAIL=0

if [ ! -d "$D" ]; then
	echo "SKIP: $D 尚未产出（U06 未完成）"
	echo "DOCS PENDING"
	exit 2
fi

for f in README.md install.md campus.md network.md ops.md compliance.md packages.md; do
	if [ -s "$D/$f" ]; then echo "ok: $f"; else echo "FAIL: 缺少或为空 $f"; FAIL=1; fi
done

need() { # 文件 关键词 说明
	if grep -q "$2" "$D/$1" 2>/dev/null; then echo "ok: $1 含 $3"; else echo "FAIL: $1 缺 $3"; FAIL=1; fi
}
need install.md "dd " "dd 刷写命令"
need install.md "Ventoy\|Etcher" "U 盘工具"
need install.md "192.168.100.1" "管理地址"
need campus.md "minieap" "minieap 配置"
need campus.md "rjv3" "锐捷 v3 模块"
need network.md "masq6\|NAT66" "NAT66 说明"
need network.md "AP" "AP 模式说明"
need ops.md "wanmode" "profile 切换"
need ops.md "campus-guard" "防检测开关"
need ops.md "swapctl" "swap 调整"
need ops.md "回滚" "回滚步骤"
need compliance.md "责任\|条款" "合规声明"

[ "$FAIL" = "0" ] && echo "DOCS OK" || echo "DOCS FAILED"
exit $FAIL
