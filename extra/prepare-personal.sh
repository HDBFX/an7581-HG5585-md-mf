#!/usr/bin/env bash
# 个人精简版（xg-040g-md / xg-040g-mf）云端构建准备：
# 全新克隆 pbs05/ponwrt；只装 QModem 全功能(v3.2.0) + OpenClash(不带内核)
# + USB 4G/5G 驱动 + PON 基础栈；不含任何主题/其他代理/调优组件。
# 由 .github/workflows/build-personal.yml 调用，运行在 GitHub-hosted runner 上。
set -euo pipefail

MODEL="${1:?缺少机型名}"
PROFILE="${2:?缺少 target profile}"
SUBTARGET="${3:?缺少 subtarget (an7581/an7583)}"

REPO="${GITHUB_WORKSPACE:?缺少 GITHUB_WORKSPACE}"
SRC="$REPO/ponwrt"
SEED="$REPO/extra/seed-personal.config"

case "$SUBTARGET" in
  an7581|an7583) ;;
  *) echo "::error::不支持的 subtarget: ${SUBTARGET}"; exit 1 ;;
esac

group(){ echo "::group::$*"; }
endg(){ echo "::endgroup::"; }

# ---------------------------------------------------------------
# 1) 主源码（pbs05/ponwrt 的 master 分支同时含 an7581 与 an7583 子目标）
# ---------------------------------------------------------------
group "克隆 pbs05/ponwrt (master)"
git clone --depth 1 https://github.com/pbs05/ponwrt.git "$SRC"
cd "$SRC"

# 编译缓存：dl 与 ccache 放到源码树之外，由 Actions cache 跨构建复用
mkdir -p "$REPO/cache/dl" "$REPO/cache/ccache"
[ -e "$SRC/dl" ] || ln -s "$REPO/cache/dl" "$SRC/dl"
[ -e "$SRC/.ccache" ] || ln -s "$REPO/cache/ccache" "$SRC/.ccache"
endg

# ---------------------------------------------------------------
# 2) feeds：qmodem 锁定 v3.2.0 tag（用户指定 3.2 或以下）
# ---------------------------------------------------------------
group "写入 feeds.conf"
cat > feeds.conf <<'FEEDS'
src-git packages https://github.com/immortalwrt/packages.git
src-git luci https://github.com/immortalwrt/luci.git
src-git routing https://github.com/openwrt/routing.git
src-git telephony https://github.com/openwrt/telephony.git
src-git video https://github.com/openwrt/video.git
src-git pon_drivers https://github.com/pbs05/openwrt-pon-drivers.git
src-git onu https://github.com/naoki66/OpenWrt_ONU_CONFIG.git;main
src-git airoha https://github.com/naoki66/luci-app-airoha.git;main
src-git qmodem https://github.com/FUjr/QModem.git;v3.2.0
FEEDS
cat feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
endg

# ---------------------------------------------------------------
# 2.5) luci-app-airoha-npu（rchen14b 版 v1.0.1）
#      NPU 监控 + CPU 频率控制 + PLL 超频（500-1600MHz 直写寄存器）
#      支持 AN7581/AN7583 双 SoC 检测，拷入 package/ 覆盖 feed 同名包
# ---------------------------------------------------------------
group "引入 luci-app-airoha-npu (NPU 监控 / CPU 超频)"
NPU_DIR="$SRC/package/luci-app-airoha-npu"
if [ ! -f "$NPU_DIR/Makefile" ]; then
  rm -rf /tmp/airoha-npu-src
  git clone --depth 1 https://github.com/rchen14b/luci-app-airoha-npu.git /tmp/airoha-npu-src
  mkdir -p "$NPU_DIR"
  cp -a /tmp/airoha-npu-src/. "$NPU_DIR/"
  rm -rf /tmp/airoha-npu-src
fi
grep -q 'LUCI_TITLE:=LuCI Airoha SoC Status' "$NPU_DIR/Makefile" || {
  echo "::error::luci-app-airoha-npu 源码不完整"
  exit 1
}
# 确认后端带超频实现（AIROHA_OC_MAX_MHZ 上限配置 + devmem PLL 写入）
grep -q 'AIROHA_OC_MAX_MHZ' "$NPU_DIR/root/usr/libexec/rpcd/luci.airoha_npu" || {
  echo "::error::该版本不含 CPU 超频实现（AIROHA_OC_MAX_MHZ），请检查仓库"
  exit 1
}
grep -q 'devmem' "$NPU_DIR/root/usr/libexec/rpcd/luci.airoha_npu" || {
  echo "::error::该版本后端缺 devmem 超频路径，请检查仓库"
  exit 1
}
echo "luci-app-airoha-npu rchen14b 版就绪（含超频）"
endg

# ---------------------------------------------------------------
# 3) 机型定制（OpenWrt files/ overlay，直接编进 rootfs）
#    个人精简版只保留：概览页读数脚本 / root 密码 / LAN IP / 简体中文。
#    不注入 RPS、代理调优、dnsmasq 缓存、主题切换等任何调优。
# ---------------------------------------------------------------
group "注入机型定制 ($MODEL)"
OVL="$SRC/files"
mkdir -p "$OVL/etc/uci-defaults"

# 3.1 概览页频率/温度显示：LuCI 状态页通过 /sbin/cpuinfo、/sbin/tempinfo 读数。
#     autocore 只在 ipq*/mediatek*/qualcommax* 安装这两个脚本，airoha 不在其列，
#     因此直接从本仓库 overlay 注入，不引入 autocore 包、不改 .config。
mkdir -p "$OVL/sbin"
install -m 0755 "$REPO/config/overlay/sbin/cpuinfo"  "$OVL/sbin/cpuinfo"
install -m 0755 "$REPO/config/overlay/sbin/tempinfo" "$OVL/sbin/tempinfo"

# 3.2 登录密码 root
ROOT_HASH="$(openssl passwd -1 -salt airoha root 2>/dev/null || true)"
[ -n "$ROOT_HASH" ] || ROOT_HASH='$1$airoha$lzq0xSV6pJiFfzc/JwIoc0'
cat > "$OVL/etc/shadow" <<SHADOW
root:${ROOT_HASH}:0:0:99999:7:::
daemon:*:0:0:99999:7:::
ftp:*:0:0:99999:7:::
network:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
ntp:*:0:0:99999:7:::
SHADOW

# 3.3 登录 IP 192.168.2.1
cat > "$OVL/etc/uci-defaults/99-lan-ip" <<'LANIP'
#!/bin/sh
uci -q batch <<'UCIBATCH'
set network.lan.ipaddr='192.168.2.1'
set network.lan.netmask='255.255.255.0'
commit network
UCIBATCH
exit 0
LANIP

# 3.4 默认简体中文 + 默认主题 Argon（99- 前缀保证开机最后执行覆盖）
cat > "$OVL/etc/uci-defaults/99-lang-theme" <<'LANGTHEME'
#!/bin/sh
uci -q set luci.main.lang='zh_cn'
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
exit 0
LANGTHEME
chmod +x "$OVL/etc/uci-defaults/"*
endg

# ---------------------------------------------------------------
# 4) 预置源码包：an7583 的 DEFAULT_PACKAGES 同样含 uboot-envtools
# ---------------------------------------------------------------
group "预置 u-boot / openssl 源码"
mkdir -p dl
UB="dl/u-boot-2026.10.tar.bz2"
if ! curl -fL --connect-timeout 15 --max-time 180 --retry 1 \
      "https://git.u-boot-project.org/u-boot/u-boot/-/releases/v2026.10/downloads/u-boot-2026.10.tar.bz2" \
      -o "$UB"; then
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/src.tar.gz" \
    "https://github.com/u-boot/u-boot/archive/refs/tags/v2026.10.tar.gz"
  TOP="$(tar -tzf "$TMP/src.tar.gz" | head -1 | cut -d/ -f1)"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP"
  tar -cjf "$UB" -C "$TMP" "$TOP"
  rm -rf "$TMP"
fi
UB_HASH="$(sha256sum "$UB" | cut -d' ' -f1)"
sed -i -E "s/^PKG_HASH:=.*/PKG_HASH:=${UB_HASH}/" \
  tools/mkimage/Makefile package/boot/uboot-tools/Makefile
echo "u-boot hash: ${UB_HASH}"

if [ ! -f dl/openssl-3.5.9.tar.gz ]; then
  curl -fL --retry 3 -o dl/openssl-3.5.9.tar.gz \
    https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
fi
echo "openssl hash: $(sha256sum dl/openssl-3.5.9.tar.gz | cut -d' ' -f1)"
endg

# ---------------------------------------------------------------
# 5) .config：平台按 subtarget 动态写入
#    设备符号 CONFIG_TARGET_airoha_<subtarget>_DEVICE_<profile>=y
# ---------------------------------------------------------------
group "生成 .config (${SUBTARGET} / ${PROFILE})"
# ccache 选项默认带可见性条件（bool "Use ccache" if DEVEL），DEVEL 未开时
# kconfig 视为不可见符号，defconfig 会把它重置回默认值 n，种子里写 y 也无效。
# 这里去掉该条件，让 CONFIG_CCACHE=y 真正生效；不影响其他开发选项。
sed -i 's/^\([[:space:]]*\)bool "Use ccache" if DEVEL$/\1bool "Use ccache"/' config/Config-devel.in
grep -q 'bool "Use ccache"$' config/Config-devel.in || {
  echo "::error::改写 ccache 可见性失败，config/Config-devel.in 结构可能已变"
  exit 1
}
{
  echo "CONFIG_TARGET_airoha=y"
  echo "CONFIG_TARGET_airoha_${SUBTARGET}=y"
  echo 'CONFIG_TARGET_BOARD="airoha"'
  echo "CONFIG_TARGET_SUBTARGET=\"${SUBTARGET}\""
  echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
  cat "$SEED"
  echo "CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${PROFILE}=y"
} > .config

make defconfig

# ccache 是构建加速项，未生效不阻塞出固件，但要显式告警
if grep -q "^CONFIG_CCACHE=y$" .config; then
  echo "ccache: 已启用"
else
  echo "::warning::CONFIG_CCACHE 未生效，本次构建不会写编译缓存"
fi

if ! grep -q "^CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${PROFILE}=y$" .config; then
  echo "::error::机型设备未选中: ${SUBTARGET} / ${PROFILE}"
  echo "--- .config 中实际选中的设备符号 ---"
  grep -E "^CONFIG_TARGET_.*_DEVICE_.*=y$" .config | head -20 || true
  echo "--- 含 ${PROFILE} 的所有行 ---"
  grep -n "$PROFILE" .config | head -20 || true
  exit 1
fi
echo "已选设备: $(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' .config | tr '\n' ' ')"
grep -E "^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)=" .config || true

# 关闭设备独立 bootloader / ATF / 外部交叉工具链包
KEYS="$(grep -E '^CONFIG_PACKAGE_(u-boot-|trusted-firmware-a-|arm-gnu-toolchain)[^=]*=y$' .config | sed 's/=y$//' || true)"
for k in $KEYS; do
  sed -i "s|^${k}=y|# ${k} is not set|" .config
done

# ---------------------------------------------------------------
# an7583 专属修复：XG-040G-MF(UBI) 设备除 sysupgrade.itb 外还定义了
#   ARTIFACTS := bl31-uboot.fip preloader.bin
# 这两个 ARTIFACT 是「首次烧录用」的独立 bootloader，生成时要调用 host
# 工具 fiptool（由 arm-trusted-firmware-tools/host 提供），其输入
# bl2.bin / bl31.lzma / u-boot.lzma 又由上面刚禁用的 ATF / u-boot 包产出。
# 于是云端上一轮报 `fiptool: No such file or directory` → target/linux
# 构建失败（Error 127）。它们不属于 sysupgrade 固件，直接移除 ARTIFACT
# 定义，只保留 IMAGES := sysupgrade.itb，与 an7581 三机型处理一致。
# ---------------------------------------------------------------
if [ "$SUBTARGET" = "an7583" ]; then
  group "移除 an7583 独立 bootloader ARTIFACT 规则（修复 fiptool 缺失）"
  MK="target/linux/airoha/image/an7583.mk"
  sed -i -E '/^[[:space:]]*ARTIFACT/d' "$MK"
  echo "剩余 ARTIFACT 定义行数: $(grep -cE '^[[:space:]]*ARTIFACT' "$MK" || true)"
  echo "--- mf-ubi 设备块（确认只产 sysupgrade.itb）---"
  sed -n '/define Device\/nokia_xg-040g-mf-ubi/,/^endef/p' "$MK"
  endg
fi

# ---------------------------------------------------------------
# 6) 严格校验：个人精简版正反向双向校验
# ---------------------------------------------------------------
group "校验个人精简版包集合"
# 正向：必须全部入选（QModem 全家 + OpenClash + USB 驱动 + PON 基础 + 中文
#       + NPU/超频界面 + 短信转发）
for p in luci-app-onu luci-app-pon-status airoha-ponctl airoha-pond airoha-pon-debug \
         qmodem qfirehose \
         luci-app-qmodem-next luci-app-qmodem-monitor \
         luci-app-qmodem-ttlfw4 \
         sms-forwarder-next \
         luci-app-airoha-npu \
         luci-app-openclash luci-i18n-base-zh-cn luci-theme-argon \
         usb-modeswitch kmod-usb-net-qmi-wwan chat comgt \
         kmod-usb-serial-sierrawireless kmod-mtk-t7xx; do
  if ! grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::个人精简版缺少 ${p}"
    exit 1
  fi
done
# 超频依赖：busybox CUSTOM 开关 + devmem applet + 内核 /dev/mem 全部必须开启
for c in CONFIG_BUSYBOX_CUSTOM CONFIG_BUSYBOX_CONFIG_DEVMEM CONFIG_KERNEL_DEVMEM; do
  if ! grep -q "^${c}=y$" .config; then
    echo "::error::缺少 ${c}，CPU 超频功能不可用"
    exit 1
  fi
done
# 反向：确认精简目标确实不在固件里
for p in luci-theme-aurora luci-app-aurora-config luci-theme-vantage \
         luci-app-vantage luci-app-passwall xray-core \
         kmod-crypto-hw-eip93 kmod-cryptodev kmod-tcp-bbr \
         luci-app-cpufreq autocore \
         luci-app-qmodem luci-app-qmodem-sms luci-app-qmodem-mwan \
         luci-app-qmodem-ttl sms-forwarder; do
  if grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::个人精简版不应包含 ${p}"
    exit 1
  fi
done
# 语言开关是 HIDDEN 中文包能否被选中的前提，必须存在
if ! grep -q "^CONFIG_LUCI_LANG_zh_Hans=y$" .config; then
  echo "::error::缺少 CONFIG_LUCI_LANG_zh_Hans，中文翻译包不会生效"
  exit 1
fi
echo "个人精简版包校验通过（QModem 全功能 v3.2.0 + 短信转发 + OpenClash 无内核 + USB 驱动 + NPU/超频）"
endg
