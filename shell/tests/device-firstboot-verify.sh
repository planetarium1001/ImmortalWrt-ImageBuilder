#!/bin/sh
# device-firstboot-verify.sh 的**离线**用例（不需要真机）：
#   1) --collected 正向：齐全的证据 ⇒ DEVICE-FIRSTBOOT OK
#   2) --collected 反向：live 根 / 前提不成立 / 缺文件 / 每条判据单独破坏 ⇒ 必须 FAILED
#   3) live 模式的**抓取流水线**：用桩命令 + FB_ROOT 夹具跑通 collect → assert
#   4) 无 ROUTER ⇒ PEND（退出码 2）
#
# 为什么反向用例是重点：判据最常见的坏法是"啥都判过"（假阳性），只测正向等于没测。
set -u
. "$(dirname "$0")/lib-assert.sh"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="${ROOT}/phase1/tools/device-firstboot-verify.sh"
SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fbv.XXXXXX")

# ---------------------------------------------------------------- 夹具
good_proc_mounts() {
	cat <<'EOF'
overlayfs:/overlay / overlay rw,noatime,lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work,xino=off 0 0
/dev/nvme0n1p2 /lower btrfs ro,noatime,subvol=/@root 0 0
/dev/nvme0n1p2 /overlay btrfs rw,noatime,subvol=/@overlay,compress=zstd:1 0 0
/dev/nvme0n1p2 /opt/docker btrfs rw,noatime,subvol=/@docker,compress=zstd:1 0 0
/dev/nvme0n1p2 /swap btrfs rw,noatime,subvol=/@swap,compress=zstd:1 0 0
EOF
}

good_gpt() {
	cat <<'EOF'
OVERLAY_DEV=/dev/nvme0n1p2
DISK=/dev/nvme0n1
SECTORS=1000215216
Disk /dev/nvme0n1: 1000215216 sectors, 476.9 GiB
First usable sector is 34, last usable sector is 1000215182
Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048          526335   256.0 MiB   EF00  phase1-boot
   2          534528       1000215182   476.4 GiB   8300  phase1-root
 128          526336          534527   4.0 MiB     EF02  phase1-core
EOF
}

good_subvols() {
	cat <<'EOF'
ID 256 gen 11 top level 5 path @root
ID 257 gen 11 top level 5 path @overlay
ID 258 gen 11 top level 5 path @docker
ID 259 gen 11 top level 5 path @swap
EOF
}

good_df() {
	cat <<'EOF'
Filesystem     1024-blocks      Used  Available Capacity Mounted on
/dev/nvme0n1p2   499841368    412345  495000000       1% /overlay
/dev/nvme0n1p2      266240      1024     265216       1% /lower
/dev/nvme0n1p2           0         0          0        - /opt/docker
/dev/nvme0n1p2           0         0          0        - /swap
EOF
}

good_dev_image() {
	cat <<'EOF'
type=dev
built_at=2026-11-07T07:03:04Z
git_sha=95bb792
note=dev 构建：WAN 全端口放行（firewall 规则 dev-open-wan）+ hostname 追加 -dev。
EOF
}

good_firewall() {
	cat <<'EOF'
firewall.dev-open-wan=rule
firewall.dev-open-wan.name='dev-open-wan'
firewall.dev-open-wan.src='wan'
firewall.dev-open-wan.proto='all'
firewall.dev-open-wan.target='ACCEPT'
EOF
}

good_dropbear() {
	cat <<'EOF'
drwx------    2 root     root          4096 Nov  7 15:03 /etc/dropbear
-rw-------    1 root     root            97 Nov  7 15:03 /etc/dropbear/authorized_keys
700 /etc/dropbear
600 /etc/dropbear/authorized_keys
KEYS=1
KEY1=ssh-ed25519
EOF
}

good_hostname() { printf 'wrt-n5105-dev\n'; }

good_boot_listing() {
	cat <<'EOF'
vmlinuz
grub
--- grub ---
grub.cfg
i386-pc
EOF
}

good_boot_log() {
	cat <<'EOF'
2026-11-07 15:30:40 phase1-init: start build=phase1-v7 dev=/dev/nvme0n1p2
2026-11-07 15:30:41 phase1-init: ok stage=devnode /dev/nvme0n1p2 + /dev/nvme0n1p1 就绪
2026-11-07 15:30:42 phase1-init: ok stage=compress /overlay 的 compress=zstd:1 生效
2026-11-07 15:30:43 initramfs: switching root upperdir=/overlay/upper
EOF
}

good_dmesg() {
	cat <<'EOF'
[    0.000000] Linux version 6.12.55
[    3.120000] btrfs: device fsid 1234 uuid 5678 devid 1 transid 42 /dev/nvme0n1p2
[    3.400000] initramfs: overlay: mount -t btrfs -o subvol=@overlay,noatime,compress=zstd:1 /dev/nvme0n1p2 /overlay
[    3.900000] initramfs: switching root upperdir=/overlay/upper
[   12.100000] br-lan: port 1(lan1) entered forwarding state
EOF
}

good_grow_log() {
	cat <<'EOF'
2026-11-07 15:30:12 10-grow-p2: 开始：DEV=/dev/nvme0n1p2 DISK=/dev/nvme0n1 PN=2 BTRFS_MNT=/overlay
2026-11-07 15:30:12 10-grow-p2: 几何: p128 start=526336 < p2 start=534528, p2 end=16777182, 盘尾=1000215182
2026-11-07 15:30:13 10-grow-p2: done：p2 已扩到盘尾（原 end=16777182，盘尾=1000215182），btrfs filesystem resize max /overlay 完成
EOF
}

mk_good() { # <目录>
	_d=$1
	mkdir -p "${_d}" || return 1
	good_proc_mounts   >"${_d}/proc_mounts"
	good_gpt           >"${_d}/gpt"
	good_subvols       >"${_d}/subvols"
	good_df            >"${_d}/df"
	good_dev_image     >"${_d}/dev_image"
	good_firewall      >"${_d}/firewall"
	good_dropbear      >"${_d}/dropbear"
	good_hostname      >"${_d}/hostname"
	good_boot_listing  >"${_d}/boot_listing"
	good_dmesg         >"${_d}/dmesg_tail"
	good_boot_log      >"${_d}/boot_log"
	good_grow_log      >"${_d}/grow_log"
}

# run_collected <目录> → 打印输出，设置 RC
run_collected() {
	OUT=$("${S}" --collected "$1" 2>&1)
	RC=$?
}

# ---------------------------------------------------------------- 0) 脚本自身
echo "== 0. 脚本形态与 --help =="
[ -x "${S}" ] && ok "脚本可执行" || bad "脚本不可执行"
H=$("${S}" --help 2>&1); RC=$?
eq "--help 退出 0" 0 "${RC}"
contains "--help 声明 OK 终态" 'DEVICE-FIRSTBOOT OK' "${H}"
contains "--help 声明 FAILED 终态" 'DEVICE-FIRSTBOOT FAILED' "${H}"
contains "--help 声明 PEND 终态" 'DEVICE-FIRSTBOOT PEND' "${H}"
contains "--help 含新几何子卷 @root" '@root' "${H}"
contains "--help 含新几何子卷 @overlay" '@overlay' "${H}"
contains "--help 含 p128" 'p128' "${H}"
contains "--help 列出 fb-1 前提判据" 'fb-1' "${H}"
contains "--help 列出 fb-17 扩容日志判据" 'fb-17' "${H}"

echo "== 0b. 未知参数 ⇒ 退出 2（不给结论）=="
"${S}" --nonsense >/dev/null 2>&1; eq "未知参数退出 2" 2 "$?"

# ---------------------------------------------------------------- 1) 正向
echo "== 1. --collected 正向：齐全证据 ⇒ OK =="
G="${SB_ROOT}/good"
mk_good "${G}"
run_collected "${G}"
eq "齐全证据退出 0" 0 "${RC}"
contains "末行是 OK 终态" 'DEVICE-FIRSTBOOT OK' "${OUT}"
contains "fb-1 合成根判定成立" 'ok   fb-1' "${OUT}"
contains "fb-6 子卷恰为四个" 'ok   fb-6' "${OUT}"
contains "fb-9 扩到盘尾" 'ok   fb-9' "${OUT}"
contains "fb-11 git_sha 命中" 'ok   fb-11' "${OUT}"
_fail_lines=$(printf '%s\n' "${OUT}" | grep -c '^  FAIL ' || true)
eq "判据里没有 FAIL 行" 0 "${_fail_lines:-0}"

# ---------------------------------------------------------------- 2) 反向：前提
echo "== 2. --collected 反向：前提三条 =="
L="${SB_ROOT}/live"
mk_good "${L}"
cat >"${L}/proc_mounts" <<'EOF'
overlayfs:/overlay / overlay rw,noatime,lowerdir=/,upperdir=/overlay/upper,workdir=/overlay/work,xino=off 0 0
/dev/nvme0n1p3 /overlay btrfs rw,noatime,subvol=/@overlay 0 0
EOF
run_collected "${L}"
eq "live 根退出 1" 1 "${RC}"
contains "live 根判 FAILED" 'DEVICE-FIRSTBOOT FAILED' "${OUT}"
contains "live 根点明是 live" 'live' "${OUT}"
contains "live 根不再往下判（无 fb-2 结论）" '前提不成立' "${OUT}"

X="${SB_ROOT}/notoverlay"
mk_good "${X}"
printf '/dev/sda2 / ext4 rw,relatime 0 0\n' >"${X}/proc_mounts"
run_collected "${X}"
eq "非 overlay 根退出 1" 1 "${RC}"
contains "非 overlay 根判 FAILED" 'DEVICE-FIRSTBOOT FAILED' "${OUT}"

# extroot 但有 lowerdir=/lower 之外的 lowerdir（例如 lowerdir=/rom）
E="${SB_ROOT}/extroot"
mk_good "${E}"
sed 's|lowerdir=/lower|lowerdir=/rom|' "${G}/proc_mounts" >"${E}/proc_mounts"
run_collected "${E}"
eq "lowerdir 不是 /lower 退出 1" 1 "${RC}"
contains "lowerdir 错位判 FAILED" 'DEVICE-FIRSTBOOT FAILED' "${OUT}"

# ---------------------------------------------------------------- 3) 反向：缺证据
echo "== 3. --collected 反向：缺证据 fail-closed =="
M="${SB_ROOT}/missing"
mk_good "${M}"
rm -f "${M}/subvols"
run_collected "${M}"
eq "缺 subvols 退出 1" 1 "${RC}"
contains "缺文件点名文件名" '缺证据文件 subvols' "${OUT}"

EMPTY="${SB_ROOT}/empty"
mkdir -p "${EMPTY}"
run_collected "${EMPTY}"
eq "空证据目录退出 1" 1 "${RC}"
contains "空目录判 FAILED" 'DEVICE-FIRSTBOOT FAILED' "${OUT}"

"${S}" --collected "${SB_ROOT}/does-not-exist" >/dev/null 2>&1
eq "证据目录不存在退出 2" 2 "$?"

# ---------------------------------------------------------------- 4) 反向：逐条判据
echo "== 4. --collected 反向：每条判据单独破坏都必须变红 =="
mut() { # <判据id> <证据文件> <变异函数>
	_id=$1
	_file=$2
	_fn=$3
	_dd="${SB_ROOT}/mut-${_id}"
	mk_good "${_dd}"
	${_fn} "${_dd}/${_file}"
	run_collected "${_dd}"
	eq "${_id}：退出 1" 1 "${RC}"
	contains "${_id}：命中判据 id" "FAIL ${_id}" "${OUT}"
}

mut_subvols()  { printf 'ID 260 gen 12 top level 5 path @old\n' >>"$1"; }
mut_p2()       { awk '{ if ($1 == 2) $3 = "2000000000"; print }' "$1" >"$1.n" && mv "$1.n" "$1"; }
mut_sha()      { grep -v '^git_sha=' "$1" >"$1.n" || true; mv "$1.n" "$1"; }
mut_fw()       { sed "s/target='ACCEPT'/target='REJECT'/" "$1" >"$1.n" && mv "$1.n" "$1"; }
mut_dropbear() { sed 's/^600 /644 /' "$1" >"$1.n" && mv "$1.n" "$1"; }
mut_hostname() { printf 'wrt-n5105\n' >"$1"; }
mut_dmesg()    { printf '[  0.100000] no usable overlay filesystem found, using tmpfs overlay\n' >>"$1"; }
mut_bootlog()  { grep -v 'switching root' "$1" >"$1.n" || true; mv "$1.n" "$1"; }
mut_grow()     { printf '2026-11-07 15:30:14 10-grow-p2: FAIL: btrfs resize 失败（命令: btrfs filesystem resize max /overlay）\n' >>"$1"; }
mut_lower()    { sed 's|subvol=/@root|subvol=/@rot|' "$1" >"$1.n" && mv "$1.n" "$1"; }
mut_compress() { sed 's|,compress=zstd:1||' "$1" >"$1.n" && mv "$1.n" "$1"; }
mut_docker()   { sed 's|subvol=/@docker|subvol=/@dock|' "$1" >"$1.n" && mv "$1.n" "$1"; }

mut fb-6  subvols    mut_subvols
mut fb-9  gpt        mut_p2
mut fb-11 dev_image  mut_sha
mut fb-12 firewall   mut_fw
mut fb-13 dropbear   mut_dropbear
mut fb-14 hostname   mut_hostname
mut fb-16 dmesg_tail mut_dmesg
mut fb-16 boot_log   mut_bootlog
mut fb-17 grow_log   mut_grow
mut fb-2  proc_mounts mut_lower
mut fb-3  proc_mounts mut_compress
mut fb-4  proc_mounts mut_docker

# ---------------------------------------------------------------- 5) live 流水线（桩命令）
echo "== 5. live 模式：桩命令 + FB_ROOT 夹具跑通 collect → assert =="
STUB="${SB_ROOT}/stub"
FAKE="${SB_ROOT}/fake"
mkdir -p "${STUB}" "${FAKE}/etc/dropbear" "${FAKE}/etc/config" "${FAKE}/boot/grub"
good_subvols >"${SB_ROOT}/subvols.fixture"
{ printf 'SECTORS=1000215216\n'; good_gpt | sed -n '/^Disk/,$p'; } >"${SB_ROOT}/gpt.fixture"
good_firewall >"${SB_ROOT}/fw.fixture"
good_dmesg >"${SB_ROOT}/dmesg.fixture"
good_df >"${SB_ROOT}/df.fixture"
good_dev_image >"${FAKE}/etc/DEV-IMAGE"
cp "${SB_ROOT}/fw.fixture" "${FAKE}/etc/config/firewall"
good_grow_log >"${FAKE}/boot/phase1-grow.log"
good_boot_log >"${FAKE}/boot/phase1-boot.log"
: >"${FAKE}/boot/vmlinuz"
: >"${FAKE}/boot/grub/grub.cfg"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample n5105-dev-debug\n' >"${FAKE}/etc/dropbear/authorized_keys"
chmod 0600 "${FAKE}/etc/dropbear/authorized_keys"
chmod 0700 "${FAKE}/etc/dropbear"
good_proc_mounts >"${SB_ROOT}/proc_mounts.fixture"
good_hostname >"${SB_ROOT}/hostname.fixture"

cat >"${STUB}/btrfs" <<'EOF'
#!/bin/sh
cat "${FBV_SUBVOLS_FIXTURE}"
EOF
cat >"${STUB}/df" <<'EOF'
#!/bin/sh
cat "${FBV_DF_FIXTURE}"
EOF
cat >"${STUB}/dmesg" <<'EOF'
#!/bin/sh
cat "${FBV_DMESG_FIXTURE}"
EOF
cat >"${STUB}/uci" <<'EOF'
#!/bin/sh
cat "${FBV_FW_FIXTURE}"
EOF
cat >"${STUB}/ip" <<'EOF'
#!/bin/sh
printf '2: br-lan    inet 192.168.100.1/24 brd 192.168.100.255 scope global br-lan\n'
EOF
cat >"${STUB}/blockdev" <<'EOF'
#!/bin/sh
printf '1000215216\n'
EOF
cat >"${STUB}/sgdisk" <<'EOF'
#!/bin/sh
cat "${FBV_GPT_FIXTURE}"
EOF
chmod 0755 "${STUB}"/*

OUT=$(
	PATH="${STUB}:${PATH}" \
	FBV_SUBVOLS_FIXTURE="${SB_ROOT}/subvols.fixture" \
	FBV_DF_FIXTURE="${SB_ROOT}/df.fixture" \
	FBV_DMESG_FIXTURE="${SB_ROOT}/dmesg.fixture" \
	FBV_FW_FIXTURE="${SB_ROOT}/fw.fixture" \
	FBV_GPT_FIXTURE="${SB_ROOT}/gpt.fixture" \
	PROC_MOUNTS="${SB_ROOT}/proc_mounts.fixture" \
	FB_ROOT="${FAKE}" \
	FB_HOSTNAME="${SB_ROOT}/hostname.fixture" \
	PHASE1_FIRSTBOOT_OUT="${SB_ROOT}/archive" \
	ROUTER=local "${S}" 2>&1
)
RC=$?
eq "live 流水线退出 0" 0 "${RC}"
contains "live 流水线末态 OK" 'DEVICE-FIRSTBOOT OK' "${OUT}"
contains "live 流水线归档了 proc_mounts" 'archive' "${OUT}"
[ -f "${SB_ROOT}/archive/proc_mounts" ] && ok "归档目录里真的有 proc_mounts" || bad "归档目录里没有 proc_mounts"

# 归档的证据必须能被 --collected 复核成同一个结论（现场与事后同一份判据）
run_collected "${SB_ROOT}/archive"
eq "刚归档的证据 --collected 也 OK" 0 "${RC}"

# ---------------------------------------------------------------- 6) 无 ROUTER ⇒ PEND
echo "== 6. 无 ROUTER ⇒ PEND（退出 2）=="
OUT=$(env -u ROUTER "${S}" 2>&1)
RC=$?
eq "无 ROUTER 退出 2" 2 "${RC}"
contains "无 ROUTER 打印 PEND 终态" 'DEVICE-FIRSTBOOT PEND' "${OUT}"

echo "== 7. 显式给 --router 但连不上 ⇒ 必须 exit 1（不许用 PEND 掩盖设备死了）=="
OUT=$(sh "${S}" --router root@203.0.113.9 2>&1)
RC=$?
eq "不可达设备退出 1" 1 "${RC}"
contains "不可达设备判 FAILED" 'DEVICE-FIRSTBOOT FAILED' "${OUT}"
contains "点名是设备不可达" 'fb-0' "${OUT}"

finish phase1-device-firstboot-verify
