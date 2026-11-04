#!/bin/sh
# 真 UCI 语义 fake 的自测（audit T1 要求的"shim 自身单测"）。
# 覆盖 libuci 三种关键行为：缺段 set → Invalid argument 且不建段、
# 缺段 add_list → Invalid argument 且不建段、@type[N] 匿名段解析；
# 以及 get 的精确匹配（禁止子串/正则模糊）与 show 的引号/匿名段格式。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

sb_new ucifake
sb_fixture net-anon
NET=$UCI_STUB_DIR/network
before=$(cksum <"$NET")

echo "== 读取：精确匹配 =="
eq "段存在时 get 段名" 'lan' "$(uci -q get network.lan)"
eq "键精确命中" 'br-lan' "$(uci -q get network.lan.device)"
eq "列表用空格连接" 'eth0' "$(uci -q get network.@device[0].ports)"
eq "@type[0] 可取内部名" 'ok' "$(uci -q get network.@device[0] >/dev/null && echo ok)"

uci -q get network.br_lan >/dev/null 2>&1; rc=$?
ne "不存在的段 get 返回非 0" '0' "$rc"
eq "不存在的段 get 不打印内容" '' "$(uci -q get network.br_lan 2>/dev/null)"
uci -q get network.wan.devic >/dev/null 2>&1; rc=$?
ne "键名不做前缀匹配（wan.devic 不得命中 device）" '0' "$rc"
uci -q get network.la >/dev/null 2>&1; rc=$?
ne "段名不做前缀匹配（network.la 不得命中 lan）" '0' "$rc"
uci -q get network.@device[9].ports >/dev/null 2>&1; rc=$?
ne "@device[9] 越界返回非 0" '0' "$rc"
eq "-q 静音 stderr" '' "$(uci -q get network.nosuchsec 2>&1)"

echo "== 写：缺段必须 UCI_ERR_INVAL 且不建段（uci list.c:603-605）=="
out=$(uci set network.br_lan.ports='eth1' 2>&1); rc=$?
ne "set 缺段返回非 0" '0' "$rc"
contains "set 缺段报 Invalid argument" 'Invalid argument' "$out"
eq "set 缺段未在配置里留下 br_lan" '0' "$(grep -c 'br_lan' "$NET" || true)"

out=$(uci add_list network.br_lan.ports='eth1' 2>&1); rc=$?
ne "add_list 缺段返回非 0" '0' "$rc"
contains "add_list 缺段报 Invalid argument" 'Invalid argument' "$out"
eq "add_list 缺段未建段" '0' "$(grep -c 'br_lan' "$NET" || true)"
eq "两次失败后配置逐字节未变" "$before" "$(cksum <"$NET")"

echo "== 写：建段只能靠 set pkg.sec=type =="
uci set network.br_lan=device >/dev/null 2>&1; rc=$?
eq "set pkg.sec=type 成功" '0' "$rc"
eq "段已建出" 'br_lan' "$(uci -q get network.br_lan)"
uci add_list network.br_lan.ports='eth1' >/dev/null 2>&1; rc=$?
eq "建段后 add_list 成功" '0' "$rc"
eq "新段只有写入的成员" 'eth1' "$(uci -q get network.br_lan.ports)"

echo "== 写：其余错误语义 =="
uci -q delete network.nosuchsec.ports >/dev/null 2>&1; rc=$?
ne "delete 缺段返回非 0" '0' "$rc"
uci set network.lan.device='br-ex' >/dev/null 2>&1
eq "已有段写键成功" 'br-ex' "$(uci -q get network.lan.device)"
uci set network.lan.device='br-lan' >/dev/null 2>&1
uci add_list network.wan.proto='oops' >/dev/null 2>&1; rc=$?
ne "add_list 到非列表 option 返回非 0" '0' "$rc"
eq "非列表 option 未被破坏" 'dhcp' "$(uci -q get network.wan.proto)"
uci set network.wan.hostname='x' >/dev/null 2>&1
uci set network.wan.hostname='' >/dev/null 2>&1
uci -q get network.wan.hostname >/dev/null 2>&1; rc=$?
ne "空值 set = 删除该键" '0' "$rc"

echo "== show：匿名段与列表格式（对照 uci-cli.c:128,198-211）=="
eq "show 匿名段打印为 @device[0]" '1' "$(uci show network | grep -c '^network\.@device\[0\]=device$')"
eq "show 列表条目逐个加引号" '1' "$(uci show network | grep -c "^network\.@device\[0\]\.ports='eth0'$")"
eq "show 命名字段加引号" '1' "$(uci show network | grep -c "^network\.wan\.proto='dhcp'$")"

finish UCI-FAKE
