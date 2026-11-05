#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "根分区固定 512 MiB（squashfs 只读根；写层在 p3 的 btrfs 子卷 @overlay）"
echo "Include Docker: $INCLUDE_DOCKER"

# 拨号与认证都不在构建期配置：认证走设备上的 /etc/minieap.conf，
# 宽带账号走 WAN 接口的 UCI；构建期写死的账号既不能换网也不能撤销。
mkdir -p /home/build/immortalwrt/files/etc/config

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi


# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#25.12
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件 暂时注释
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# ============= 锐捷认证网络/便携路由必备组件 =============
# 认证：minieap(锐捷 v3) + 官方 LuCI 协议页；luci-compat 是 Lua proto handler 的依赖
PACKAGES="$PACKAGES minieap luci-proto-minieap luci-i18n-minieap-zh-cn luci-compat"
# 网络与分发：NAT66 用原生 masq6，此处只补内核与工具
PACKAGES="$PACKAGES kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket kmod-br-netfilter kmod-nf-nathelper-extra kmod-tcp-bbr"
PACKAGES="$PACKAGES ip-full ethtool-full irqbalance conntrack"
# 首启扩容依赖：feed 里没有 growpart，用 parted/sfdisk + resize2fs
# 25.12 把 e2fsprogs 拆成多个包：resize2fs / dumpe2fs / partx-utils 必须单独声明，
# 否则扩容时"分区扩了、文件系统没扩"，表现为容量不变。
# chattr / lsattr 同样是 25.12 拆出来的独立 apk 包（不在 e2fsprogs 里）：
# btrfs 子卷靠 `chattr +C` 置 NOCOW（@docker/@swap）并用 `lsattr` 复核，
# 缺了它们 nodatacow 意图落不了地，swapfile 落在非 NOCOW 文件上 swapon 会直接失败。
PACKAGES="$PACKAGES parted sfdisk e2fsprogs fdisk resize2fs dumpe2fs partx-utils blockdev chattr lsattr"
# 内存压缩 swap
PACKAGES="$PACKAGES zram-swap kmod-zram"
# 防检测/探测依赖
PACKAGES="$PACKAGES curl ca-bundle jq"
# 调试与运维（用户要求便于排障）
PACKAGES="$PACKAGES luci-theme-argon luci-app-argon-config luci-app-ttyd luci-app-filemanager luci-app-commands openssh-sftp-server luci-app-package-manager"
PACKAGES="$PACKAGES htop iftop tcpdump iperf3 bind-dig lm-sensors pciutils usbutils smartmontools nvme-cli rsync tmux bash jq lsof"
PACKAGES="$PACKAGES luci-app-nlbwmon luci-app-vnstat2 luci-app-statistics luci-app-watchcat luci-app-autoreboot"
# 存储/共享/容器
PACKAGES="$PACKAGES luci-app-diskman luci-app-samba4 luci-app-minidlna luci-app-openlist luci-app-hd-idle"
# btrfs 写层（p3 上的 @overlay/@docker/@swap/@data）：
#   kmod-fs-btrfs 内核无内置 btrfs，必须带模块（preinit 里 modprobe）
#   btrfs-progs   挂载/子卷/属性命令（btrfs subvolume、property 等）
#   gdisk         sgdisk -e 把 GPT 备份头挪到盘尾，否则建不出到盘尾的 p3
# 这三个包必须写在这里：ImageBuilder 下 imm25.config 的 CONFIG_PACKAGE_* 不生效。
PACKAGES="$PACKAGES kmod-fs-btrfs btrfs-progs gdisk"
# 说明：不含 ppp/pppoe —— 当前场景用不到，需要时再装

# ============= 代理：nikki（mihomo）==============
# 官方 25.12.2 源没有 mihomo，必须先把 nikki 上游 apk 源接进来；
# 脚本在源不可达时会回退到 packages/ 里预置的 apk，不会中断构建。
if [ -f /home/build/immortalwrt/shell/nikki-repo.sh ]; then
    sh /home/build/immortalwrt/shell/nikki-repo.sh --workdir /home/build/immortalwrt \
        || echo "nikki repo setup skipped (fallback)"
fi
PACKAGES="$PACKAGES nikki luci-app-nikki luci-i18n-nikki-zh-cn mihomo-meta"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    # 光有中文语言包没有 dockerd/守护进程，docker 页签是空的
    PACKAGES="$PACKAGES dockerd docker docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn"
    echo "Adding docker stack: dockerd + dockerman + compose"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# 根分区固定 512 MiB：squashfs payload 实测 159.2 MiB，留 3.2x 余量。
# 不接受外部改尺寸——改 ROOTFS_PARTSIZE 会让镜像分区表与盘上不一致，
# sysupgrade 走整盘覆写，p3（@overlay/@docker/@swap/@data）全丢。
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=512 EXTRA_IMAGE_NAME="n5105"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
