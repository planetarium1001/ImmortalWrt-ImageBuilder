# phase1/ —— Phase 1 装机链（只读 btrfs 子卷根 + 独立 overlay 写层）

这一目录是 Phase 1 的**构建与装机骨架**。`20261106-btrfs-root-phase1` 已把引导链做到真机可用
（ac-8…ac-14 全 PASS）；`20261107-btrfs-root-image-ci` 在此基础上补上 **CI 可刷镜像**：
`phase1/build.sh` 单一入口 + `assemble-image.sh --image` 镜像文件模式 + `dev`/`prod` 两种构建类型。
**镜像本身还没刷过真机**（用户拔盘写、下一任务验）。

权威依据（有冲突以它们为准）：

- `.workflow/assets/2026-11-06-btrfs-ab-decisions.md` §0.1（几何）/ §O.1（fstools 二次叠 tmpfs）/ §O.2（`tar -T` 递归拷目录）
- `.workflow/assets/wrt-ab-00-HANDOFF.md` §0.6 与 §5（坑 1 `rootwait`、坑 8 `fstools_ignore_partname`、坑 13 sysupgrade 整盘 dd、坑 14 PARTUUID 漂移）
- `.workflow/tasks/20261106-btrfs-root-phase1/prd.md` 的 ac-5 / ac-6

## 1. 交付物

| 文件 | 用途 | 本轮状态 |
|---|---|---|
| `phase1/grub/grub.cfg.in` | GRUB 菜单模板：0 号项（已知良好项）+ 可选试跑项 + `set fallback=0` | 渲染 + 断言已跑通 |
| `phase1/assemble-image.sh` | 装机骨架：分区 / 子卷 / 解包 / `/.ab-base-manifest` / grub 安装 | `--dry-run`、`--grub-dir` 可用；真装机路径写全但**未执行** |
| `phase1/tests/grub-cfg.sh` | ac-5 用例（模板渲染语义） | `sh phase1/tests/grub-cfg.sh` |
| `phase1/tests/assemble-dry-run.sh` | ac-6 用例（dry-run 行为 + 静态安全约束） | `sh phase1/tests/assemble-dry-run.sh` |
| `phase1/tests/fixtures/grub.cfg.device-r38135` | 真机 `/boot/grub/grub.cfg` 的结构拷贝（18 行 / 826 字节；**两块盘的 PARTUUID 已匿名化**为 `00000000-…-00000000000{1,2}`，md5 `1c52ef71d322462703cee86dd34acd50`，文件内不含任何注释），`--preserve-existing` 的用例输入 | 只读 fixture；出处与原始 md5 见同目录 `.provenance` |
| `phase1/tests/fixtures/grub.cfg.device-r38135.provenance` | 上面这个 fixture 的出处（来源路径 / 版本 r38135 / 取回时间 2026-11-06 / md5 / 第 3 条是 spick 遗留项） | 只读说明 |
| `phase1/make-initramfs.sh`、`phase1/initramfs/init` | initrd 构建与 `/init` 引导链（teammate tm-02 的产出，本目录只读参考） | 见各自文件 |
| `phase1/build.sh` | **CI 单一入口**：解包 rootfs → 注入 firstboot(+dev) → 组 initrd 的 STAGE → `make-initramfs.sh` → `assemble-image.sh --image` → `gzip -9` + sha256 | 已实现；离线用 `--prepare-rootfs` / `--dry-run` 验 |
| `phase1/dev/rootfs/**` | **仅 dev 镜像**注入：`etc/DEV-IMAGE`（模板 `.in`）+ `etc/uci-defaults/90-dev-image`（首启写 `dev-open-wan` 全放行 + hostname `-dev`）+ `etc/dropbear/authorized_keys`（调试公钥，构建期 chmod 0700/0600） | 已实现；`phase1/tests/dev-mode-content.sh` 断言 |
| `phase1/firstboot/rootfs/etc/uci-defaults/10-grow-p2.sh` | **两种类型都注入**：首启把 p2 扩到盘尾（幂等，失败不阻断启动） | 已实现；`phase1/tests/firstboot-grow.sh` 用桩断言 |
| `phase1/tests/assemble-image-mode.sh` | ac-1：`--image` 参数校验 / dry-run 计划 / 失败也拆 loop / Linux 真跑（`PHASE1_IMAGE_REAL=1`） | `sh phase1/tests/assemble-image-mode.sh` |
| `phase1/tests/dev-mode-content.sh` | ac-4：dev vs prod 的注入差异（真跑 `--prepare-rootfs` 后比对） | `sh phase1/tests/dev-mode-content.sh` |
| `phase1/tests/firstboot-grow.sh` | ac-5：扩容脚本 6 个场景（真跑脚本 + 桩 `sgdisk`/`partx`/`btrfs`） | `sh phase1/tests/firstboot-grow.sh` |
| `.github/workflows/Build-phase1-btrfs.yml` | CI：`workflow_dispatch` 选 `mode=dev\|prod`，产出 `.img.gz` + sha256，并在 runner 上做布局/内容/dev-vs-prod 自检 | 已实现；`sh shell/tests/phase1-workflow-shape.sh` 断言结构 |

## 2. 装配几何（Phase 1 装机即按此，避免将来重刷）

```
p1    FAT32  256M   <p1>/boot/grub/grub.cfg   /boot/vmlinuz   /boot/initrd.cpio.gz
p128  EF02    4M    GRUB core.img 预留（建 4M，但 Phase 1 不重建 core.img）
p2    btrfs   至盘尾  单块，全部子卷都在这一块上：
      @root      只读基座（上游 rootfs 解包，运行期以 ro 挂到 /rom）
      @overlay   upper/ + work/ —— 唯一读写层（运行期挂 /overlay）
      @docker    → /opt/docker（chattr +C，nocow）
      @swap      → /swap（chattr +C，nocow）
```

引导链：`GRUB(p1) → vmlinuz + initrd → /init`：挂 `@root` **ro** → `/lower`，挂 `@overlay` → `/overlay`，
`mount -t overlay lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work` → `/newroot` → `switch_root`。
细节见 `phase1/initramfs/init`。

`@docker` / `@swap` **不是可选装饰**：`/opt/docker` 不是独立挂载时 docker 会退化到 `vfs` 驱动迅速写满
`@overlay`；swapfile 放在 overlayfs 上 `swapon` 直接不支持（decisions 修正 D30）。

## 3. cmdline 硬规则

`assemble-image.sh` 在渲染后**强制校验**，不合格直接退出非 0（不做任何"自动修补"）：

1. **禁 `rootwait`**（任何一项）。带它时找不到根会无限等待 ⇒ `panic=10` 永不触发 ⇒ 无人值守只能人肉断电
   （handoff §5 坑 1）。`/init` 也不依赖它。
2. **必含 `fstools_ignore_partname=1`**：否则 fstools 的 `volume_find("rootfs_data")` 命中非 ext4/f2fs 设备时会
   `mkfs.ext4 -F` 抹掉整块盘（坑 8）。
3. **必含 `panic=10`**：失败要能自动重启回 0 号项。
4. **禁 `root=PARTUUID=`**：上游每次构建都会换 PARTUUID（坑 14）；我们的根由 initrd 决定，不写死。
5. 试跑项额外带（键名与 `phase1/initramfs/init` 逐字一致）：
   `rdinit=/init phase1_dev=<p2> phase1_boot=<p1> phase1_bootsub=<bootsub> phase1_lower=@root phase1_overlay=@overlay`。
   `phase1_bootsub` 取 `--boot-subdir`（默认 `boot`），决定 `/init` 去 `<p1>/boot/` 还是 `<p1>/` 找标记与日志
   （PRD 硬规则 15）；渲染后校验会检查它与 `--boot-subdir` 一致，不一致直接非 0。
   `/init` 另认可选键 `phase1_docker` / `phase1_swap`（有内置默认，本模板不注入）。

0 号项默认 cmdline：`fstools_ignore_partname=1 panic=10 console=ttyS0,115200n8 console=tty1`。
若 `/init` 需要显式设备/子卷参数，用 `--cmdline` 把 `phase1_*` 也带进 0 号项（渲染时会一起校验）。

## 4. 输入约定

| 输入 | 从哪来 | 说明 |
|---|---|---|
| rootfs | 上游 ImmortalWrt 的 `rootfs.tar.gz`（或已解开的目录） | 只当**基座**用，不重跑 ImageBuilder |
| kernel | 与 rootfs 同一次构建的 `vmlinuz`（`/boot/vmlinuz`） | 名字与 `bzImage` 一致即可；grub 路径由 `--kernel-path` 控制 |
| initrd | `sh phase1/make-initramfs.sh` 的产物（newc + gzip -9） | 载荷里有 btrfs 的 10 个 ko 与 vfat/fat/nls_* |
| 盘 | 目标**整盘**（如 `/dev/nvme0n1`） | 分区表会被整体重建；盘上有分区被挂载或在 swap 里就硬失败 |

### 4.1 rootfs 基线必须是 `fe53232`（否则脚本**默认拒绝**）

Phase 1 的基座按 PRD 是 `fe53232` 内容：**没有** `/etc/init.d/btrfs-subvols`、**没有** extroot/`@overlay` 的
`/etc/config/fstab`。而仓库 HEAD 时代的基座里：

- `btrfs-subvols` 用 `btrfs filesystem show wrt-overlay` 找 p3（`LABEL=${OVERLAY_LABEL:-wrt-overlay}`）；
- 它还要挂 `@data`（`mount_one @data "$DATA_DIR"`）。

本脚本默认 `mkfs.btrfs -L phase1` 且只建 `@root @overlay @docker @swap`。用 HEAD 时代 rootfs 装出来的系统，
每次启动都会在 `p3_dev` 就 `return 1`：一个子卷都不挂、不跑 `swapctl`、`/data` 缺失 —— 而这个故障会被
`/init` 已经挂好的 `@docker`/`@swap` **掩盖**，到 Phase 2 才爆。

所以脚本**显式拦截**（不是靠改默认值）：rootfs（tar 或已解开的目录）里一旦出现
`/etc/init.d/btrfs-subvols` 或含 `extroot`/`@overlay` 的 `/etc/config/fstab`，就非 0 退出并提示
"这份 rootfs 是 HEAD 时代内容，Phase 1 要求 fe53232 基线"。确实要用那种基座时必须显式三件套：

```sh
sh phase1/assemble-image.sh --rootfs head-rootfs.tar.gz … \
	--allow-legacy-rootfs --btrfs-label wrt-overlay --with-data-subvol
```

- `--btrfs-label NAME`：p2 的 btrfs 标签（默认 `phase1`），`mkfs.btrfs -L` 直接用；
- `--with-data-subvol`：额外建 `@data`（默认关）；
- `--allow-legacy-rootfs`：放行 HEAD 时代 rootfs（会告警；没对齐 label/@data 时再提醒）。

`--dry-run` 会把 `btrfs 标签`、`@data 子卷`、`rootfs 基线` 三行都打出来，刷机前就能看到。

## 5. 用法

### 5.1 只看计划（任何机器都能跑，不写盘）

```sh
sh phase1/assemble-image.sh --dry-run \
	--rootfs phase1-rootfs.tar.gz --kernel vmlinuz --initrd initrd.cpio.gz \
	--disk /dev/nvme0n1
```

打印分区表（p1 256M / p128 EF02 4M / p2 至盘尾）、`btrfs 标签`/`@data 子卷`/`rootfs 基线`三行、
子卷清单（默认四个，`--with-data-subvol` 时五个）、解包排除清单、`/.ab-base-manifest` 规则、
grub 安装命令、0 号项与试跑项 cmdline、以及真装机前的占用检查/三层校验与 `yes` 确认点。
退出码 0，**不碰任何设备**。

### 5.2 只渲染 grub.cfg（不碰磁盘）

```sh
# 纯模板 · 最终镜像形态：只有我们的 0 号项
sh phase1/assemble-image.sh --grub-dir /tmp/grub-out \
	--kernel vmlinuz --initrd initrd.cpio.gz

# 纯模板 · 多一条试跑项（标记文件存在时它成为默认项）
sh phase1/assemble-image.sh --grub-dir /tmp/grub-out \
	--kernel vmlinuz --initrd initrd.cpio.gz \
	--disk /dev/nvme0n1 --trial \
	--trial-initrd /boot/initrd-trial.cpio.gz

# 保留现存（**真机试跑用这个**）：上游 squashfs 项逐字保留，末尾追加我们的试跑项
sh phase1/assemble-image.sh --grub-dir /tmp/grub-out \
	--preserve-existing /path/to/备份的grub.cfg \
	--kernel vmlinuz --initrd initrd.cpio.gz --trial --disk /dev/nvme0n1
```

常用覆盖：`--kernel-path` / `--initrd-path`（grub 视角的路径）、`--trial-kernel` / `--trial-initrd`
（试跑项用另一份内核或 initrd = 上一版已验证产物）、`--boot-subdir`（引导分区内的前缀目录）、
`--marker-path` / `--marker-path-alt`（试跑标记的 grub 视角路径）、`--trial-index`（覆盖自动序号）。

### 5.3 两种渲染模式（先看这一节，别混用）

| 模式 | 参数 | 0 号项是什么 | 用在哪 |
|---|---|---|---|
| **纯模板** | `--grub-dir DIR` | 我们自己渲染的 initrd 项 | **最终镜像**（真装机路径自己调它写 p1） |
| **保留现存** | `--grub-dir DIR --preserve-existing <现存 grub.cfg>` | 上游 squashfs 项（原文件 0 号项，逐字保留） | **真机试跑**（设备现有系统必须继续可引导） |

真机上现存的已知良好项**不是** initrd 项，而是上游 squashfs 项：

```
menuentry "ImmortalWrt" {
	linux /boot/vmlinuz root=PARTUUID=<该盘 PARTUUID> rootwait  console=tty1 console=ttyS0,115200n8 noinitrd
}
```

它带 `rootwait` 与 `root=PARTUUID=`，**这是合法的**（它不是我们的项）。所以保留模式的规则是：

1. 现存 grub.cfg **每一行原样输出**——`serial` / `terminal_*` / `set default="0"` / `set timeout="0"` /
   `search -l kernel -s root`（设置 grub root 的关键行）/ 全部 menuentry，一个字节都不改；
2. 只在现存 `set default=...` **之后**插入标记守卫（单行写法，避免在 grub 里用 `-o`/`||`）。
   主路径与 live 一致（`/boot/try-phase1` = `p1:/boot/try-phase1`），`/try-phase1` 只作兜底；
   两者相同时只输出一条：
   ```
   if [ -f /boot/try-phase1 ]; then set default=<N>; fi
   if [ -f /try-phase1 ]; then set default=<N>; fi        ← 兜底（--marker-path-alt）
   ```
   试跑项的 cmdline 还会带 `phase1_bootsub=<--boot-subdir>`（默认 `boot`），让 `/init` 去
   `<p1>/boot/` 找标记与日志；校验会检查它与 `--boot-subdir` 逐字一致。
3. 文件末尾追加**一条**试跑项（标题/内核/initrd/cmdline 与模板模式同一套占位符语义）；
4. `N` **自动** = 现存文件里 `menuentry` 的条数（`--trial-index N` 可覆盖）。真机现状是 3 条
   （`ImmortalWrt` / `ImmortalWrt (failsafe)` / 上一轮 spick 遗留的 `TEST btrfs subvol root (initramfs)`）
   ⇒ `N=3`；用例还覆盖了 0 条和 1 条的输入（`N=0` / `N=1`）；
5. **运行期断言**：原文件每一非空行都必须逐字出现在输出里，否则非 0 退出（不只是用例里检查）；
6. **cmdline 硬规则只校验我们生成的试跑项**。保留行不参与校验——这不是"脚本在放行"，而是
   "上游项不是我们的项"：只有追加的那一条 `linux` 行会被查（禁 `rootwait`、禁 `root=PARTUUID=`、
   必含 `fstools_ignore_partname=1 panic=10`）；
7. **为什么保留模式也补 `set fallback=0`**（现存文件若没有 `set fallback=`，就新增这一行，
   不改动任何保留行，且只在 `--trial` 时补）：① 上游是 `set timeout="0"`，试跑项的内核/initrd
   加载失败时 GRUB 会停在菜单等按键 ⇒ 无人值守等于挂死；② 保留模式下 **0 号项就是 live 项**
   （上游 squashfs 根），`fallback=0` 的语义完全正确 —— 试跑项加载失败就回 live。

真机试跑时 initrd 的给法：`--initrd` 决定**试跑项**的 initrd（保留项自带 `noinitrd`，我们不改它）；
`--trial-initrd` 可让试跑项用另一份。想让"两项用同一个我们的 initrd"，就把两者指到同一个文件。

### 5.4 真装机（本轮不执行，仅说明）

```sh
sh phase1/assemble-image.sh \
	--rootfs phase1-rootfs.tar.gz --kernel vmlinuz --initrd initrd.cpio.gz \
	--disk /dev/nvme0n1
```

顺序固定，任一步失败即非 0 退出并给可执行的下一步提示：

0. **目标盘占用检查**（第一条）：`/proc/mounts` 里出现 `$DISK` 或它的任一分区（含 `/`、`/boot`、`/rom`、
   `/overlay`）、`/proc/cmdline` 里出现它、或 `swapon -s` 里有它 ⇒ 直接非 0。在设备本机跑等于重建正在
   运行的分区表，必须从另一介质（U 盘 / Live）运行。rootfs 基线检查（§4.1）也在这之前完成；
1. **分层校验三连**（全部打印）：`sgdisk -p` 的 p1 元数据 → 每个分区的 `blkid -s UUID -o value` →
   子卷枚举（`btrfs subvolume list`）与期望清单比对（默认 `@root @overlay @docker @swap`，
   `--with-data-subvol` 时再加 `@data`）；
2. 必须**手工输入 `yes`** 才继续（默认拒绝，其它任何输入都取消）；
3. 破坏性动作全部集中在 `destructive_install()`：`sgdisk`（p1 → p128 → p2，`--set-alignment=2048` 固定几何）→
   `mkfs.vfat` / `mkfs.btrfs -L <--btrfs-label>` → `btrfs subvolume create` → 解包 `@root` →
   写 `/.ab-base-manifest` → `grub-install --target=i386-pc` + `--target=x86_64-efi --removable`（双模）→ 渲染 `grub.cfg`；
4. 解包**必须**排除挂载点（`/proc /sys /dev /tmp /run /boot /rom /overlay /opt/docker /swap /data`）：
   `tar` 会把目录条目递归进去，实测误拷 22GB docker 镜像（decisions §O.2）；
5. 解包是**两段式**（先 `tar -cf` 到临时 tar 并判 rc，再 `tar -xpf`）：POSIX sh 没有 `pipefail`，
   `tar -c | tar -x` 会吞掉源侧失败、留下半残基座。manifest 条目 <1000 也直接 fail（不再只告警）；
6. `/.ab-base-manifest` 只收 `/etc /usr /lib /sbin /bin /www` 的普通文件（不含 `/var /tmp /run`），
   格式 `path<TAB>sha256`，条目数会打印（预期数千）；
7. 脚本里没有递归强制删除，也没有通配删除（`phase1/tests/assemble-dry-run.sh` 会静态断言这一条）。

### 5.5 镜像文件模式（`--image`，CI 用；只写一个普通文件）

```sh
# 在 Linux + root 上：从零产出一个可 dd 的镜像（不碰 /dev 下的任何整盘，因此不需要人工 yes）
sudo sh phase1/assemble-image.sh --image out.img --size 8G \
	--rootfs phase1-rootfs.tar.gz --kernel vmlinuz --initrd initrd.cpio.gz

# 同一套计划（任何机器都能跑，一个字节都不写）
sh phase1/assemble-image.sh --dry-run --image out.img --size 8G \
	--rootfs phase1-rootfs.tar.gz --kernel vmlinuz --initrd initrd.cpio.gz
```

- 步骤与真装机同源：`truncate` → `losetup --find --show --partscan` → `sgdisk`（p1/p128/p2）→
  `mkfs.vfat`/`mkfs.btrfs` → 子卷（`chattr +C`）→ 解包 `@root` + `/.ab-base-manifest` →
  内核/initrd/`grub.cfg` → `grub-install --target=i386-pc` → `grub-install --target=x86_64-efi --removable`（写 `EFI/BOOT/BOOTX64.EFI`）→ 卸载 → `losetup -d`。
- **`--image` 只产出未压缩 `.img`**；`gzip -9 -n` 与 `.sha256` 由 `phase1/build.sh` 负责。
- 互斥：`--image` 不能与 `--disk` / `--grub-dir` / `--trial` 同时用；输出路径不许落在 `/dev/` 或是块设备；
  `--size` 下限 2G（`8G` 或 `8192M` 两种写法）。
- 覆盖已有非空镜像要显式 `--force-overwrite`（默认拒绝：随后的 `truncate` 不可逆）。
- 挂载点 `/mnt/phase1-{boot,btrfs}` 被占用（并发构建 / 上次失败残留）时**硬失败**并提示先 `umount`：
  叠挂会让子卷比对读到别的盘、`umount` 只摘顶层、loop 变 busy。
- **失败也会拆 loop**：`trap image_teardown EXIT INT TERM HUP` 负责 `umount` + `losetup -d`，
  用例用桩验证过这条路径（`phase1/tests/assemble-image-mode.sh` §4）。
- 镜像里的根设备来自 **initrd 烘焙的默认值**（`build.sh --rootdev/--bootdev`，默认 `/dev/nvme0n1p2`、`/dev/nvme0n1p1`）：
  最终镜像的 `grub.cfg` 仍**不含** `phase1_dev=` 键（0 号项口径见 §3 的渲染校验）。
  **dd 到别的盘型（SATA/USB）必须用 `--rootdev/--bootdev` 重建 initrd。**

### 5.6 CI 单一入口 `phase1/build.sh` 与 `dev`/`prod`

```sh
# 完整构建（CI 就是这么调的）：rootfs + 内核 → initrd → .img.gz + sha256
sudo sh phase1/build.sh --type prod --rootfs /path/rootfs --kernel /path/vmlinuz \
	--image-out out.img.gz --size 8G

# 只做"解包 + 注入"（离线可跑，用例走这条）：不碰 loop/分区/grub
sh phase1/build.sh --type dev --rootfs /path/rootfs --prepare-rootfs /tmp/prepared \
	--kernel vmlinuz --image-out /dev/null --size 8G

# 只打印将执行的完整 argv（与真跑同一份 argv，不是另写一份计划文本）
sh phase1/build.sh --type dev --rootfs /path/rootfs --kernel vmlinuz \
	--image-out out.img.gz --size 8G --dry-run
```

`--type` **必填**且只认 `dev|prod`（不设默认值：这两个是安全边界）。差异**只在注入层**，静态可判定：

| 项 | dev | prod |
|---|---|---|
| `/etc/config/firewall` 的 `dev-open-wan` 规则（`src=wan, proto=all, target=ACCEPT`） | 首启由 `/etc/uci-defaults/90-dev-image` 写入（幂等） | 不写；镜像里没有这个脚本 |
| hostname 后缀 `-dev` | 同上脚本追加（幂等） | 无 |
| `/etc/DEV-IMAGE` 标记（含 type/built_at/git_sha） | 有（构建期从 `DEV-IMAGE.in` 渲染） | 无 |
| `/etc/dropbear/authorized_keys`（调试公钥；目录 0700、文件 0600） | 有（`phase1/dev/rootfs` 注入，构建期 `chmod`） | **无**——`assert_prod_clean` 见到就硬失败 |
| `/etc/uci-defaults/10-grow-p2.sh`（首启扩容） | 有 | 有 |

STAGE（initrd 载荷）**缺任何一项就失败并点名到包**（`kmod-fs-btrfs`/`kmod-fs-vfat`/`kmod-nls-*`/`attr`/`libgcc`/`libubox`），
不做"半残 initrd"。`--work DIR` 可复用，但每次会先清空 `<WORK>/rootfs` 与 `<WORK>/stage`
（否则上一次 dev 注入会污染下一次 prod），且 `--work` 会 `pwd -P` 规范化并拒绝 `/`、`/tmp`、`/home` 这类系统目录。

- **`libubox` 不改名**：STAGE 里放的必须是 rootfs 里那个 `libubox.so.<版本日期>` 的**原名**（kmodloader 的
  `DT_NEEDED` 就是它自己那版的 soname，改名 ⇒ initrd 里连 `btrfs.ko` 都加载不起来）。
- **`INIT_SHA=<sha256>`**：每次构建都打印这一行（渲染 `/init` 的所有参数与真跑完全一致；`--dry-run` 也会在
  `TMPDIR` 里临时渲染后删除来打印它）。CI 用它和镜像内 initrd 里的 `/init` 做逐字比对（ac-3）。
- **大小闸**：压 `gzip` 之前断言镜像的实际字节数**恰好等于** `--size`（`8G`/`8192M`/`512K` 都支持解析）。
  不等就 `die` —— 半成品镜像绝不会被压成 `.img.gz` 当成功产物。
- **dev 的 WAN 放行是"镜像里就有"**：`--type dev` 在构建期把 `phase1/dev/rootfs/etc/config/firewall.dev-rule`
  append 进镜像的 `/etc/config/firewall`（判重幂等，末尾没换行会先补）；首启的 `90-dev-image` 保留作兜底，
  它按规则名判重所以不会叠第二条。**
- **dev 的调试公钥（无外设设备唯一的登录通道）**：`--type dev` 把 `phase1/dev/rootfs/etc/dropbear/authorized_keys`
  注入镜像，并在构建期 `chmod 0700 /etc/dropbear` + `chmod 0600 authorized_keys`——
  git 只记录 644/755，检出到工作区/CI 的都是 0644，不显式收紧的话镜像里就是 0644。
  路径依据：OpenWrt 给 dropbear 打了 `100-pubkey_path.patch`，root（uid 0）读 `/etc/dropbear/authorized_keys`
  且只校验**目录**不可被 group/other 写（见 `.workflow/knowledge/fact/active/2026-11-07-openwrt-dropbear-root-etc-dropbear-autho.md`）。
  **prod 镜像不得带任何公钥**：`assert_prod_clean` 见到 `etc/dropbear/authorized_keys` 直接 `die`。
  私钥只在 `.workflow/assets/router-ssh/`（该目录被 `.gitignore` 整体忽略，不进版本库）。

### 5.7 首启扩容的失败语义（`10-grow-p2.sh`）

- **不该重试**的分支 `exit 0`：p2 已到盘尾（already-full）、根分区号不是 2、几何异常
  （`p128.start >= p2.start`）、推不出整盘、缺 `sgdisk`/`partx`/`btrfs`。
- **瞬时失败**（`sgdisk -e`/`sgdisk -d -n`/`partx` 两路都失败/`btrfs filesystem resize max` 失败）`exit 1`：
  uci-defaults 只在 `exit 0` 时删除脚本，所以 `exit 1` = **下次开机自动重试**，且**不阻断启动**。
- 日志：`/boot/phase1-grow.log` + `/dev/kmsg`（能写才写）。

## 6. 真机试跑（GRUB 路径，唯一被完整证明过的路径）

### 6.1 真机前置（缺一条就别开跑）

1. **基座里的 `/lib/preinit/80_mount_root` 必须是仓库补丁本体**（也就是 ac-1/ac-2 的
   `files/lib/preinit/80_mount_root`）。上一轮手改过的 `# PHASE1-DISABLED` 版本必须先替换掉：
   否则 `do_mount_root` 仍会在我们的合成根上再叠一层 tmpfs，**拿不到**
   `80_mount_root: skip fstools mount_root` 这条取证，ac-11 会失败，而且看起来像"补丁逻辑没生效"。
   一行核对（两边摘要必须逐字相同）：

   ```sh
   # 开发机
   sha256sum files/lib/preinit/80_mount_root      # macOS: shasum -a 256 <文件>
   # 测试基座（设备上，或解包后的 rootfs 目录里）
   sha256sum /rom/lib/preinit/80_mount_root
   ```

2. initrd 必须是 `sh phase1/make-initramfs.sh` 的**新**产物（载荷含 `vfat/fat/nls_*`，
   否则 `/boot` 上的日志写不出来，失败会表现为"零痕迹"）。
3. 先备份设备上现有的 `/boot/grub/grub.cfg`，并用它做 `--preserve-existing` 的输入（见下）。

### 6.2 标记与日志的层级（F-1 真机裁定，别改）

| 视角 | 标记文件 | 日志 |
|---|---|---|
| live 系统 | `/boot/try-phase1` | `/boot/phase1-boot.log` |
| GRUB | `/boot/try-phase1` | —— |
| initramfs 里 | `<p1>/<bootsub>/try-phase1` | `<p1>/<bootsub>/phase1-boot.log` |

三者是**同一个文件**：`p1:/boot/try-phase1`（`bootsub` = cmdline 键 `phase1_bootsub`，默认 `boot`）。
设备上 p1 根下有 `boot/`、`efi/`；内核与 grub 配置在 `p1:/boot/vmlinuz`、`p1:/boot/grub/grub.cfg`，
live 的 `/boot` 最终指向 `p1:/boot`（`79_move_config` 先把 p1 挂到 `/boot`，再 `mount --bind /boot/boot /boot`）。

**为什么写死这一条**：上一版把"标记在引导分区根（`p1:/try-phase1`）"当默认，而操作者按 live 习惯
`touch /boot/try-phase1` 实际落在 `p1:/boot/try-phase1`，`/init` 却去 `p1:/try-phase1` 找 ⇒ **删不掉标记**
⇒ `panic=10` 无限重启（ac-12 才暴露）。现在主守卫就是 `/boot/try-phase1`，`/try-phase1` 只作兜底；
`phase1_bootsub` 让 `/init` 知道要去 `<p1>/boot/` 而不是分区根。

### 6.3 试跑步骤

1. 备份设备上现有的 `/boot/grub/grub.cfg`（改名保存，别原地覆盖而不留副本），把它拷到开发机当
   `--preserve-existing` 的输入。基线样例在 `phase1/tests/fixtures/grub.cfg.device-r38135`
   （逐字节拷贝，出处见同目录 `.provenance`；用例会用 md5 断言它没被"美化"过）。
   注意设备上第 3 条 `TEST btrfs subvol root (initramfs)` 是上一轮 spick 的遗留项，**不改不删**，
   tm-03 把它当非默认项忽略即可；要清理属于设备现场整理，不在本任务范围。
2. 用**保留模式**渲染：

   ```sh
   sh phase1/assemble-image.sh --grub-dir /tmp/grub-out \
       --preserve-existing /path/to/备份的grub.cfg \
       --kernel vmlinuz --initrd initrd.cpio.gz --trial --disk /dev/nvme0n1
   ```

   上游 squashfs 项（含 `search -l kernel -s root`）逐字保留，末尾多一条我们的试跑项，序号自动算。
3. 把渲染结果放回引导分区的 `grub/grub.cfg`（grub 视角 `/boot/grub/grub.cfg`），并确认
   我们的 `initrd.cpio.gz` 就在 grub 视角 `/boot/` 下（路径与上游项的 `linux /boot/vmlinuz` 同一层）。
4. **让标记文件存在**：`touch /boot/try-phase1`（live 视图）。它就是 grub 视角的 `/boot/try-phase1`
   = `p1:/boot/try-phase1` = `/init` 的 `<p1>/<bootsub>/try-phase1`（见 6.2）。
   不要写成 `p1:/try-phase1`（那是兜底路径，只有 grub root 指到分区根时才命中）。
5. 重启。成功：`/boot/phase1-boot.log` 里有 `=== phase1-init: start` 与 `initramfs: switching root upperdir=/overlay/upper`。
   失败：`/init` 写 `FAIL stage=...`、**删掉标记**，`panic=10` 自动重启 ⇒ 回到 0 号项（已知良好项）。
6. 回滚 = 删掉标记文件（`set fallback=0` + `set default=0` 保证 0 号项是已知良好项）；
   要彻底还原就把备份的 `grub.cfg` 放回去。
   **删的就是这一个路径**：live 上 `rm /boot/try-phase1`（= `p1:/boot/try-phase1`）。
   不要去 `/p1/...` 或 `p1:/try-phase1` 找 —— 那是 initramfs 内部视角与 grub 兜底路径，不是你要删的文件。
7. **标记是一次性的**：`/init` 在**成功切根之前**也会删掉它（与失败路径同一个函数），
   所以"成功启动一次"同样消耗标记。想再进我方根，必须重新 `touch /boot/try-phase1`。
   这样任何一条路径（成功 / die / 看门狗）都只消耗一次机会，不会形成重启循环。

试跑项与 0 号项都是同一套 `linux <kernel>` + `initrd <initrd>` 形式，路径与 cmdline 都由渲染参数逐字决定；
`--trial-initrd` 可以让 0 号项继续指向"上一版已验证的 initrd"，这样 `set fallback=0` 才有实际意义。

## 7. 真机验证结果与仍未验证的部分

### 7.1 已在真机验证（2026-11-06 晚，两轮，含一次故意失败）

| 判据 | 结果 | 证据要点 |
|---|---|---|
| ac-8 `/` = overlay 且 `lowerdir=/lower`+`upperdir=/overlay/upper`；`/rom` 是 `@root` 且 `ro` | PASS | `/proc/mounts` 原文；`/boot` 为 `p1:/boot` 视图 |
| ac-9 写入真落 `@overlay/upper` | PASS | 探针与 `uci` 改动同时出现在 upper，`/rom` 上没有 |
| ac-10 重启后写入仍在、`/` 行不变 | PASS | 两轮重启，sha256 不变 |
| ac-11 `dmesg` 无 `tmpfs overlay`，有 `80_mount_root: skip ...` | PASS | 每轮一条 skip 记录 |
| ac-12 故意失败 → 自动回 live、标记被删、无循环 | PASS | `FAIL stage=lower-mount` → `removed .../try-phase1` → 59s 后回 live |
| ac-13 `apk add nano` 与自有配置跨重启仍在 | PASS | `/overlay/upper/usr/bin/nano` sha256 不变；`/rom` 上无 nano |
| ac-14 按文档路径放标记即生效（F-1 修复后） | PASS | `marker present` → `removed /p1/boot/try-phase1`；日志在 live 与新系统都可读 |

附带确认：`/lower`→`/rom`、`/overlay` 两次搬运都走 `mount -o move`（未走退化路径）；搬后 overlay 仍可写。
**F-1 的教训**：p1 根下有 `boot/` 子目录，若 `/init` 把 p1 根当 `/boot`，标记与 GRUB 看的就不是同一个文件，
失败时删不掉标记 ⇒ 无限重启。现在路径唯一（硬规则 15 / ac-14），并有"主路径删不到就按已知位置兜底"的救援。

### 7.2 仍未验证（下一轮先验这些）

- **整盘重分区与刷机**：`destructive_install()` 一次都没在真机跑过；`sgdisk`/`mkfs.*`/`grub-install`
  的参数与顺序只经过 `sh -n` 与静态审查；`partx -a -n` 的节点出现时机、`chattr +C` 的可用性未实测。
- **`@docker` / `@swap` 真机行为**：子卷会建，但没有真的跑过 docker 或 `swapon`。
- **HEAD 时代基座 + `wrt-overlay`/`@data` 这条路**：脚本默认拦（§4.1），放行参数
  （`--allow-legacy-rootfs --btrfs-label wrt-overlay --with-data-subvol`）只在离线用例里验过；
  而且 `@data` 在 `/init` 里没有 `mount_optional` 对应（属 Phase 2）。
- **GRUB `set fallback=0`**：设计上用于"内核/initrd 加载失败"，但故意破坏 initrd 会让设备停在菜单等按键
  （无显示器只能拔电）⇒ 本轮**没有**造这个状态，属"设计有、真机未证"。
- **看门狗超时删标记**、**`phase1_bootsub` 与几何不一致时的兜底救援**：仅静态断言。
- **xattr / scrub**：`opaque`/whiteout 处理属 Phase 3，本轮只在载荷里带上 `getfattr/setfattr`（已真机确认闭包完整）。
- **A/B 双槽**：没有 grubenv 计数与槽切换，只有"标记 + 失败即删 + `fallback=0`"的等价一次性语义。
- **`grub-install` 的模块集**：`--modules` 清单未在真机确认 core.img 能否只用 p1 上的模块树。
- **残留风险**：失败发生在 p1 挂上之前（模块加载阶段）且补挂也失败时，仍可能重启循环
  —— 那等价于磁盘/文件系统已坏，见 PRD「遗留风险」。

## 8. 下一轮待办

- ~~**CI 入口**：在 `x86-64/build25.sh` 旁新增 phase1 构建入口~~ —— 已由
  `phase1/build.sh` + `.github/workflows/Build-phase1-btrfs.yml` 完成（见 §5.5 / §5.6）。
- **镜像刷真机**：`20261107-btrfs-root-image-ci` 的产物还没写过盘；首启扩容（`10-grow-p2.sh`）
  与 dev 镜像的 WAN 全放行只在离线用例里验过（桩），真机首启属下一任务。
- 真机刷机前：用 `phase1/tools/device-verify.sh` 把 ac-8…ac-14 固化成可复跑检查（本轮已落地）。
- 真机确认最终几何后，固定 `--boot-subdir` 与标记路径，并删掉兜底路径（`/try-phase1`）。
- Phase 2：换基座复验（设计见任务 `research/phase2-3-device-tests.md` 第 2 节）。

## 9. 自测

```sh
sh phase1/tests/grub-cfg.sh            # ac-5：模板渲染语义
sh phase1/tests/assemble-dry-run.sh    # ac-6：dry-run + 静态安全约束
sh phase1/tests/assemble-image-mode.sh # ac-1：--image 参数校验 / dry-run 计划 / 失败拆 loop / Linux 真跑
sh phase1/tests/dev-mode-content.sh    # ac-4：dev vs prod 注入差异（真跑 --prepare-rootfs）
sh phase1/tests/firstboot-grow.sh      # ac-5：首启扩容 6 场景（真跑脚本 + 桩命令）
# 一次跑完全部（含 shell/tests 与 phase1/tests）：
sh shell/tests/all.sh
```

镜像本身只能在 Linux + root 上验（loop 挂载），所以有三段式取证：

```sh
# 1) CI 里跑（workflow 的 Self-check image 步骤就是它）
sudo sh phase1/tools/image-selfcheck.sh <out.img.gz> --mode prod --init-sha <build.sh 打印的 INIT_SHA>

# 2) 把 CI 那份 PASS 报告存成本地证据文件后，在任意机器上机械复核（缺项/FAIL 都非 0）
sh phase1/tools/verify-ci-report.sh selfcheck-prod.txt --mode prod --stage all

# 3) 产物本身的完整性（macOS 也能跑）
shasum -a 256 -c <out.img.gz>.sha256 && gzip -t <out.img.gz>
```

两个用例都只用 POSIX sh + 仓库内 `shell/tests/lib-assert.sh`；已在 macOS 的 `/bin/sh`（bash 3.2）与
`dash`（busybox ash 的近似替代）上跑通，产物只落在 `mktemp -d /tmp/...` 里。
