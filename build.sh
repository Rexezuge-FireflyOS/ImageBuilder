#!/usr/bin/env bash
set -euo pipefail

# 配置区（按需修改）
ROOTFS_DIR=$(pwd)/out/rootfs
IMAGE_FILE=$(pwd)/out/fireflyos.img # 修改：输出文件为 .img
IMAGE_SIZE_MB=2048 # 新增：定义镜像大小（MB）
MOUNT_POINT=$(mktemp -d) # 新增：临时挂载点
PKG_LIST_FILE=config/package-list.txt
PACMAN_CONF=$(pwd)/pacman.conf.build

# 清理
rm -rf "$ROOTFS_DIR" "$IMAGE_FILE" "${IMAGE_FILE}.sig"
mkdir -p "$ROOTFS_DIR" "$(dirname "$IMAGE_FILE")"

# =====================================================================
# 步骤 1：安装第三方仓库的 Keyring (在 Root 容器中，创建 Builder 用户)
# =====================================================================
BUILDER_USER="builduser" # 新建一个用户用于 makepkg
KEYRING_NAME="alhp-keyring"
KEYRING_DIR=$(mktemp -d)
PKG_BUILD_DIR="$KEYRING_DIR/$KEYRING_NAME"

echo "-> 检查并安装 $KEYRING_NAME 从 AUR..."

# 1. **创建临时非 root 用户** builduser
useradd -m -s /bin/bash "$BUILDER_USER"
echo "-> 临时用户 $BUILDER_USER 创建成功。"

# 2. 克隆 AUR 仓库
git clone https://aur.archlinux.org/alhp-keyring.git "$PKG_BUILD_DIR"

# **关键修复：将构建目录的所有权转移给 builduser**
chown -R "$BUILDER_USER:$BUILDER_USER" "$KEYRING_DIR"

# 3. **切换到新用户 ($BUILDER_USER) **运行 makepkg -s
echo "-> 切换到 $BUILDER_USER 用户构建 $KEYRING_NAME..."
ALHP_SIGNING_KEY="8CA32F8BF3BC8088"
su "$BUILDER_USER" -c "
    set -euo pipefail; 
    cd \"$PKG_BUILD_DIR\" || exit 1; 
    echo '导入源码签名公钥 $ALHP_SIGNING_KEY...';
    gpg --keyserver keyserver.ubuntu.com --recv-keys $ALHP_SIGNING_KEY 2>/dev/null || \
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys $ALHP_SIGNING_KEY || true;
    makepkg -s --noconfirm
"

# 4. 找到生成的包文件名
cd "$PKG_BUILD_DIR"
ALHP_PKG=$(ls alhp-keyring-*.pkg.tar.zst 2>/dev/null | head -n 1)

# 5. **Root 用户**运行 pacman -U 安装包
if [ -f "$ALHP_PKG" ]; then
    echo "-> 找到包: $ALHP_PKG，正在以 root 身份安装..."
    pacman-key --init || true
    pacman -U "$ALHP_PKG" --noconfirm --needed
    ALHP_MAIN_KEY="BC3993A9EBDD40E5C242D72F0FE58E8D1B980E51"
    echo "-> 明确信任 ALHP GPG 密钥 $ALHP_MAIN_KEY..."
    pacman-key --lsign-key "$ALHP_MAIN_KEY"
else
    echo "错误: 未找到生成的 alhp-keyring 包！请检查 makepkg 输出。"
    exit 1
fi

# 6. 清理临时用户、目录和文件
cd - > /dev/null
userdel -r "$BUILDER_USER"
rm -rf "$KEYRING_DIR"
echo "-> $KEYRING_NAME 安装完成，GPG 密钥已导入到容器的 pacman 密钥环。"

# ==========================================================
# 步骤 2: 创建 RootFS
# ==========================================================
# 安装基础包（使用 pacstrap）
sudo mkdir -p "$ROOTFS_DIR/var/lib/pacman"
sudo pacman --noconfirm --noprogressbar -r "$ROOTFS_DIR" --config "$PACMAN_CONF" -Sy $(cat "$PKG_LIST_FILE")

# ==========================================================
# 步骤 3: 配置目标系统 (在包安装完成后！)
# ==========================================================
echo "==> Configuring the target system..."
sudo mkdir -p "$ROOTFS_DIR/etc"
sudo tee "$ROOTFS_DIR/etc/os-release" > /dev/null <<'EOF'
NAME="FireflyOS"
VERSION="$(date +%Y.%m)"
ID=arch
EOF
echo "mystable" | sudo tee "$ROOTFS_DIR/etc/hostname"

# ==========================================================
# 步骤 4: 创建 DD 镜像并复制文件 (替换原有的打包步骤)
# ==========================================================
echo "==> Creating DD image..."

# 1. 创建一个空镜像文件
truncate -s "${IMAGE_SIZE_MB}M" "$IMAGE_FILE"

# 2. 创建分区表 (MBR) 和一个主分区 (ext4)
parted -s "$IMAGE_FILE" mklabel msdos
parted -s "$IMAGE_FILE" mkpart primary ext4 1MiB 100%

# 3. 将镜像关联到 loop 设备
LOOP_DEV=$(sudo losetup -f --show "$IMAGE_FILE")
if [ -z "$LOOP_DEV" ]; then
    echo "错误：无法找到可用的 loop 设备。"
    exit 1
fi
echo "-> 镜像已关联到 $LOOP_DEV"

# 分区设备名，通常是 /dev/loopXp1
PART_DEV="${LOOP_DEV}p1"

# 等待分区设备节点创建
sleep 2 

# 4. 在分区上创建 ext4 文件系统
echo "-> 正在格式化分区 $PART_DEV..."
sudo mkfs.ext4 -L ROOTFS "$PART_DEV"

# 5. 挂载分区并复制 rootfs 内容
echo "-> 正在挂载 $PART_DEV 到 $MOUNT_POINT..."
sudo mount "$PART_DEV" "$MOUNT_POINT"

echo "-> 正在将 rootfs 内容复制到镜像..."
sudo rsync -a "$ROOTFS_DIR/" "$MOUNT_POINT/"

# 6. 卸载并清理
echo "-> 卸载分区并分离 loop 设备..."
sudo umount "$MOUNT_POINT"
sudo losetup -d "$LOOP_DEV"
rm -rf "$MOUNT_POINT"

# ==========================================================
# 步骤 5: 清理和签名
# ==========================================================
echo "==> Cleaning up rootfs directory..."
sudo rm -rf "$ROOTFS_DIR"

# GPG 签名
echo "==> Signing the image..."
gpg --detach-sign --armor --local-user "$GPG_KEY" -o "${IMAGE_FILE}.sig" "$IMAGE_FILE"

echo "Built DD image $IMAGE_FILE and signature ${IMAGE_FILE}.sig"
