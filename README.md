<div align="center">
  <img src="docs/icons/po0fw.png" width="76" height="76" alt="po0fw logo" />
  <h1>po0fw</h1>
  <p><b>po0 防火墙白名单全平台自动维护工具</b></p>
  <p>覆盖 OpenWrt 软路由 · Linux / macOS / Windows · Android · iOS / macOS 六大代理客户端</p>
  <p>
    <a href="https://po0fw.uuuz.de/"><b>在线配置与一键安装页</b></a>
    &nbsp;·&nbsp;
    <a href="https://wiki.uuuz.de/guide/tutorials/po0fw-whitelist">Wiki 图文教程</a>
    &nbsp;·&nbsp;
    <a href="#快速安装">快速安装</a>
    &nbsp;·&nbsp;
    <a href="#命令行与管理">命令参考</a>
    &nbsp;·&nbsp;
    <a href="#常见问题">FAQ</a>
  </p>
  <p>
    <a href="https://github.com/w0ven/po0fw/actions/workflows/shell.yml"><img src="https://github.com/w0ven/po0fw/actions/workflows/shell.yml/badge.svg" alt="Shell & JS CI" /></a>
    <a href="https://github.com/w0ven/po0fw/actions/workflows/windows-powershell.yml"><img src="https://github.com/w0ven/po0fw/actions/workflows/windows-powershell.yml/badge.svg" alt="Windows PowerShell CI" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-059669.svg" alt="MIT License" /></a>
  </p>
</div>

---

## 核心设计

po0「鸡险」机器防火墙仅放行白名单内的最近来源 IP 网段。`po0fw` 通过定时巡检与网络切换事件双通道，在设备公网 IP 变动时自动完成上报与自愈：

- **官方 IP 直连免分流**：直接请求官方 Let's Encrypt IP 证书端点 `POST https://124.221.69.228/api/firewall/<token>/add[?slot=N]`，无需第三方 IP 探测服务，也不会被常规域名分流规则误劫持。
- **服务端 `/24` 幂等加白**：服务端按请求源 IP 自动提取 C 段（`/24`）；同网段重复上报完全幂等，不占新坑位、不推进淘汰队列。
- **固定槽位常驻 (`@0`–`@4`)**：支持在 Token 后追加 `@槽位号`（如 `pgnfw_xxx@0`）将家宽等核心出口钉死在指定槽位，满额时永不参与 FIFO 淘汰；流动设备留空即可自动轮转自愈。
- **多机合并与故障自愈**：单处配置即可用英文逗号拼接多台机器 Token 同时维护；内置瞬时网络断连与服务端偶发裸 `400` / `5xx` 退避重试，精准诊断 `403` 槽位冲突与防火墙未启用状态。

> **凭证安全提示**：Token（形如 `pgnfw_...`，在 po0 控制台机器详情页「防火墙」卡片获取）等同于对应机器的白名单写入凭证，请勿在公开仓库或群聊中泄露。若设备启用了全局 TUN 透明代理，请确认包含 `IP-CIDR,124.221.69.228/32,DIRECT,no-resolve` 直连规则（本仓库所有代理客户端模块均已内置）。

---

## 平台支持矩阵

| 运行环境 | 部署方案 | 触发机制 | 推荐场景 |
| :--- | :--- | :--- | :--- |
| **OpenWrt / Kwrt 软路由** | [`openwrt/install-openwrt.sh`](openwrt/install-openwrt.sh) | WAN `ifup`/`ifupdate` 秒级 + 10 分钟 cron | **首选推荐**：重拨秒级恢复，全家 Wi-Fi 设备共享 |
| **Linux / macOS** | [`install-linux.sh`](install-linux.sh) + [`po0fw.sh`](po0fw.sh) | `systemd` timer（root）或 `crontab`（非 root） | 桌面工作站、Linux 主机、macOS 终端 |
| **Windows** | [`windows/install-windows.ps1`](windows/install-windows.ps1) | 静默计划任务：网络连接事件 + 10 分钟定时 | Windows 10 / 11 台式机与笔记本（无黑框闪烁） |
| **iOS / macOS 代理客户端** | Surge / Loon / Stash / QX / SR / Egern | `network-changed` 即时 + 10 分钟 cron | iPhone / iPad / Mac 移动蜂窝与多网络切换 |
| **Android** | [MacroDroid / HTTP Shortcuts / Termux](android/README.md) | 网络连接变化触发 + 15 分钟定期兜底 | 安卓手机移动数据与外出 Wi-Fi 切换 |
| **iOS 无代理环境** | [系统「快捷指令」个人自动化](ios/README.md) | 连接任意 Wi-Fi 时自动运行 | 未安装代理客户端的轻量 iOS 用户 |

> **社群集成客户端**：网友 [yuuuki-creation](https://github.com/yuuuki-creation/po0-clash) 维护了基于 FlClash 内置自动加白功能的 **[po0-clash](https://github.com/yuuuki-creation/po0-clash)**（支持 Windows / macOS / Android，使用指南见 [wiki.uuuz.de](https://wiki.uuuz.de/guide/clients/po0-clash)），适合希望在同一客户端内管理节点与白名单的用户。

---

## 快速安装

前往 **[https://po0fw.uuuz.de/](https://po0fw.uuuz.de/)** 粘贴你的 Token，可直接生成填好参数的各平台命令与请求地址。

### 1. OpenWrt / Kwrt 软路由（推荐）

```sh
curl -fsSL https://raw.githubusercontent.com/w0ven/po0fw/main/openwrt/install-openwrt.sh -o /tmp/i.sh
PO0FW_TOKENS="pgnfw_你的token@0" sh /tmp/i.sh
```

- 自动安装至 `/usr/bin/po0fw`，写入 `0600` 权限 `/etc/po0fw.conf`；
- 注册 `/etc/hotplug.d/iface/99-po0fw`（自动忽略 `wan6` 等纯 IPv6 接口避免重拨双倍并发）与每 10 分钟 cron 兜底。

### 2. Linux / macOS / Android Termux

```sh
curl -fsSL https://raw.githubusercontent.com/w0ven/po0fw/main/install-linux.sh | PO0FW_TOKENS="pgnfw_你的token" sh
```

- **Linux (root + systemd)**：安装至 `/usr/local/bin/po0fw` 并启用 `po0fw.timer`；
- **macOS / 非 root 普通用户**：自动适配用户目录 `~/.local/bin/po0fw` 与 `~/.config/po0fw/po0fw.conf` 并注册 `crontab`；
- **Termux**：安装至 `$PREFIX/bin/po0fw`，自动配置 `cronie` 定时任务（装完执行 `sv-enable crond`）。

### 3. Windows（PowerShell 5.1+）

以**管理员身份**打开 PowerShell 执行：

```powershell
irm https://raw.githubusercontent.com/w0ven/po0fw/main/windows/install-windows.ps1 -OutFile i.ps1
powershell -ExecutionPolicy Bypass -File i.ps1 -Tokens "pgnfw_你的token"
```

- 部署至 `%ProgramData%\po0fw\`，通过 `wscript.exe` 无窗口静默拉起；
- 同时绑定每 10 分钟重复触发器与 `EventID 10000` 网络连接事件触发器（含 3 秒路由就绪防抖延迟与单实例保护）。

### 4. iOS / macOS 代理客户端模块

推荐通过 **[https://po0fw.uuuz.de/](https://po0fw.uuuz.de/)** 一键唤起客户端导入，或手动复制以下模块地址：

| 客户端 | 模块 / 片段路径 | Token 配置方式 |
| :--- | :--- | :--- |
| **Surge** | [`surge/po0-firewall-whitelist.sgmodule`](surge/po0-firewall-whitelist.sgmodule) | 模块参数 `tokens`（多机器用 `,` 分隔，自带状态面板） |
| **Loon** | [`loon/po0-firewall-whitelist.plugin`](loon/po0-firewall-whitelist.plugin) | 插件参数 `API tokens`（多机器用 `,` 分隔） |
| **Stash** | [`stash/po0-firewall-whitelist.stoverride`](stash/po0-firewall-whitelist.stoverride) | 编辑覆写内两处 `argument: tokens=`（自带磁贴面板） |
| **Shadowrocket** | [`shadowrocket/po0-firewall-whitelist.srmodule`](shadowrocket/po0-firewall-whitelist.srmodule) | 长按模块 → 编辑纯文本，替换两行占位（多机器用 `\|` 分隔） |
| **Egern** | [`egern/po0-firewall-whitelist.yaml`](egern/po0-firewall-whitelist.yaml) | 模块参数 `tokens`（原生异步脚本，多机器用 `,` 分隔） |
| **Quantumult X** | [`quantumultx/po0-firewall-whitelist.snippet`](quantumultx/po0-firewall-whitelist.snippet) | 加入本地 `[task_local]`，用 BoxJs 写入键 `po0fw_tokens` |

Android 免 Root 自动化（MacroDroid / HTTP Shortcuts）与 iOS 系统快捷指令详见：
- [Android 配置指南 (`android/README.md`)](android/README.md)
- [iOS / macOS 配置指南 (`ios/README.md`)](ios/README.md)

---

## 命令行与管理

### Shell CLI（OpenWrt / Linux / macOS / Termux）

```sh
po0fw                          # 读取配置文件并执行加白
po0fw status                   # 只读查询白名单状态与槽位占用（GET 端点，绝不写入或挤占坑位）
po0fw pgnfw_aaa@0,pgnfw_bbb    # 临时指定单台/多台机器 Token 与固定槽位执行加白
po0fw uninstall                # 一键卸载定时任务、hotplug、配置文件与已安装的程序
po0fw --help                   # 查看命令行帮助
```

### Windows PowerShell

```powershell
# 只读查询当前白名单与槽位状态
powershell -ExecutionPolicy Bypass -File "$env:ProgramData\po0fw\po0fw.ps1" -Status

# 一键卸载计划任务与本地文件（管理员 PowerShell）
irm https://raw.githubusercontent.com/w0ven/po0fw/main/windows/install-windows.ps1 -OutFile u.ps1
powershell -ExecutionPolicy Bypass -File u.ps1 -Uninstall
```

### 配置来源与优先级

命令行参数 > 环境变量 `PO0FW_TOKENS` > 本地配置文件：

| 环境 | 默认配置文件路径 | 格式说明 |
| :--- | :--- | :--- |
| Linux (root) / OpenWrt | `/etc/po0fw.conf` | `PO0FW_TOKENS="pgnfw_xxx@0,pgnfw_yyy"`（权限 `0600`） |
| macOS / Linux (非 root) | `~/.config/po0fw/po0fw.conf` | 同上，亦兼容每行一条裸 Token 写法 |
| Windows | `%ProgramData%\po0fw\po0fw.conf` | 纯 Token 串或 `PO0FW_TOKENS="..."` 均可 |

---

## 开发与测试

仓库包含完整的 POSIX Shell 测试套件与 Node.js 多客户端沙箱测试（零外部 npm 依赖）：

```sh
/bin/sh tests/test-po0fw.sh       # 验证 add/status/uninstall、重试自愈、403 冲突、安全配置解析与非 root 安装
node tests/test-js-clients.mjs    # 模拟 Surge/Loon/Shadowrocket/QX/Egern 运行环境、落地页交互与编码规范校验
```

---

## 常见问题

- **为什么推荐家宽加 `@0` 而手机不加？**  
  白名单默认上限 5 个网段，满额按最早写入时间淘汰。家宽路由器一旦被挤出全家设备都会断连，加 `@0` 可常驻不淘汰；手机蜂窝网络 IP 变化频繁，留给剩余 4 个 FIFO 坑位自动轮转即可。
- **更换槽位号时报 `403 槽位冲突` 怎么办？**  
  服务端不允许同一 `/24` 网段同时占据两个不同的固定槽位。先在 po0 控制台防火墙面板删除旧槽位记录，再重新运行即可。
- **支持 IPv6 吗？**  
  po0 防火墙按 IPv4 `/24` 网段放行，脚本已强制通过 IPv4 发起加白请求。

---

## 致谢与许可

- iOS / macOS 客户端模块的早期整理借鉴了 [reallinzc/po0fw](https://github.com/reallinzc/po0fw)，感谢原作者与社群贡献者（[po0-clash](https://github.com/yuuuki-creation/po0-clash)）的分享。
- 本项目基于 [MIT License](LICENSE) 开源。
