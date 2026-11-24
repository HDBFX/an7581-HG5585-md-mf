# AN7581 FTTR 光猫第三方固件

基于 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（OpenWrt main / 内核 6.18，APK 包管理）为 Airoha AN7581 平台 FTTR 光猫定制的固件，GitHub Actions 全自动构建，产物发布在 [Releases](https://github.com/luxinxin0378-create/an7581-HG5585-md-mf/releases)。

## 支持机型

| 机型 | 平台 | 说明 |
|---|---|---|
| 烽火 XG-040G-MD / MF | AN7581 | FTTR 主猫（MD/MF 为不同批次硬件） |
| 中兴 HG5585F-CT / CU | AN7581 | FTTR 主猫 |
| 华三 HM2004-DU | AN7581 + MT7916 | FTTR 母猫（首刷前务必备份 factory 分区） |

## 固件版本

| 版本 | 后缀 | 定位 |
|---|---|---|
| 正式版 | `B26` | 五机型全家桶，功能完整 |
| 个人版 | `P26` | MD/MF 专享，QModem 4G/5G 全功能 + 更多插件 |
| 光猫专版 | `O26` | 极简 PON 桥接，仅基础光猫功能 |

## 本次构建内容（2026-11-24）

- **代理换装 PassWall**：正式版 / 个人版同步从 PassWall2 换为 PassWall，内置 **Xray 核心**开箱即用（VLESS/VMess/Trojan/SS 全协议）；SingBox/SS-Rust/Haproxy 等多余内核已裁剪（单核省 ~30MB）
- **默认时区 Asia/Shanghai**：开机即北京时间（CST-8），NTP 服务器为国内源（ntp.aliyun.com / ntp.tencent.com / cn.pool.ntp.org），LuCI 时区下拉可正常选择（zoneinfo-core/asia 已入包）——VMess/TLS 握手对时间敏感，已消除时间偏差故障点
- **个人版新增五插件**：
  - **iStore 应用商店**（linkease 官方，ipk/apk 双前端，界面中文，在线一键装插件）
  - **LibreSpeed 测速**（本地 Go 后端，浏览器开箱即测）
  - **ZeroTier 异地组网**（官方中文界面）
  - **USB 打印机共享**（p910nd + kmod-usb-printer）
  - **NFS 共享**（nfs-kernel-server 全家 + LuCI 中文界面）

## 全版本内置

- **ddnsto 远程访问**（中文界面，微信扫码绑定，免公网 IP；uci-defaults 首次开机自动安装）
- 常用插件全家桶：WOL 网络唤醒 / SmartDNS / 硬盘休眠 / UPnP / NLBW 流量统计 / SQM 智能队列 / 访问控制 / 微信推送（全中文）
- EIP93 硬件加密引擎 + cryptodev、CPU 超频（devmem 路径）、airoha NPU 界面
- 概览页 CPU 频率 / 温度 / 编译时间全部正常显示（autocore + 直读内核节点）
- 中文界面（luci-i18n-zh-cn）、Argon 主题、kmod-tcp-bbr、TCP/RPS 调优
- 个人版另有：QModem 全功能 v3.2.0（短信转发 / TTL 修整 / QFirehose）、USB 4G/5G 驱动栈（QMI/PPP/MT7xx）、FileBrowser、SMB 开箱即用、CPU 频率调节界面

## 刷机注意

- **HM2004-DU 首刷必做**：先备份 factory 分区（决定路由模式的原厂数据）
  ```sh
  cat /proc/mtd   # 确认 factory 分区编号
  dd if=/dev/mtd5 of=/tmp/factory.bin   # 编号按实际替换
  ```
- 通用升级：LuCI「系统 → 备份/升级」上传对应 `.itb`，保留配置升级
- 刷机有变砖风险，请自备 TTL 恢复手段

## 构建

- 推送到 `main`（`config/**`、`scripts/**` 变更）自动触发正式版五机型构建
- 手动触发：Actions 页 `build-personal.yml`（个人版）、`build-pon.yml`（光猫专版）
- 脚本结构：`scripts/prepare.sh`（正式版）、`extra/prepare-personal.sh`（个人版）、`extra/prepare-pon.sh`（光猫版）；包清单见 `config/seed.config`、`extra/seed-*.config`

## 致谢

[pbs05/ponwrt](https://github.com/pbs05/ponwrt) · [Openwrt-Passwall](https://github.com/Openwrt-Passwall) · [linkease/iStore](https://github.com/linkease/istore) · immortalwrt 团队
