# po0fw

po0 防火墙自动加白 —— 覆盖软路由（OpenWrt / Kwrt）、PC（Linux / macOS / Windows）、安卓（MacroDroid / HTTP Shortcuts / Termux）与 iOS / Mac 代理客户端（Surge / Loon / Stash / Quantumult X / Shadowrocket / Egern）全平台。

👉 **在线交互安装页：<https://po0fw.uuuz.de/>**（粘贴 token 自动生成各平台命令与请求地址）

## 原理

- 每 10 分钟（+ 网络切换事件）向 po0 官方 **IP 直连端点**发起加白：
  `POST https://124.221.69.228/api/firewall/<token>/add[?slot=N]`
- 服务端按请求来源 IP 自动识别 `/24` 网段并**幂等**加白（已在白名单则不占新坑、不推进 FIFO 淘汰）
- 客户端无需自行探测出口 IP，也**无需配置任何域名分流规则**（IP 直连不经 DNS 解析）
- 支持 `@槽位`（`0`–`4`）固定常驻坑位；多台 po0 机器 token 用英文逗号 `,` 分割
- 内置网络瞬断与服务端瞬时异常自动退避重试，403 槽位冲突与未启用状态清晰诊断

> 提示：若设备跑了 TUN 全局接管代理，建议加一条 `IP-CIDR,124.221.69.228/32,DIRECT,no-resolve` 保证加白请求直连（本仓库所有 iOS/Mac 模块已内置该规则）。

Token 在 po0 控制台机器详情页「防火墙」卡片获取，形如 `pgnfw_...`。**token 即加白凭证，请勿公开分享。**

## 平台总览

| 平台 | 方案 | 触发方式 |
|---|---|---|
| OpenWrt / Kwrt 软路由 ⭐ | 本仓库 shell 脚本 | cron 每 10 分钟 + hotplug WAN 重连秒级触发 |
| Linux / macOS | 本仓库 shell 脚本 | systemd timer（root）或 crontab（macOS / 非 root） |
| Windows | 本仓库 PowerShell | 静默计划任务：10 分钟 + 网络连接事件（EventID 10000） |
| 安卓 | [android/](android/)：MacroDroid / HTTP Shortcuts / Termux | 网络切换 + 定时 |
| iOS / Mac 代理客户端 | 本仓库脚本模块：Surge / Loon / Stash / QX / Shadowrocket / Egern（[一键安装页](https://po0fw.uuuz.de/)） | network-changed 即时 + 10 分钟 cron |
| iOS 无代理 App | [ios/](ios/)：系统快捷指令自动化 | Wi-Fi 切换触发 |

> 社群客户端选择：热心网友还维护了基于 FlClash 内置自动加白的 [po0-clash](https://github.com/yuuuki-creation/po0-clash)（支持 Windows / macOS / Android，使用教程见 [wiki.uuuz.de](https://wiki.uuuz.de/guide/clients/po0-clash)）。

## iOS / Mac 代理客户端模块

Surge / Loon / Stash / Quantumult X / Shadowrocket / Egern 六客户端脚本模块，带面板显示、固定槽位 `📌` 标记、蜂窝 `📶` 标记、network-changed 即时触发 + 每 10 分钟 cron 兜底：

👉 **一键安装页：<https://po0fw.uuuz.de/>**

| 客户端 | 载体 | token 配置 |
|---|---|---|
| Surge | `surge/po0-firewall-whitelist.sgmodule` | 模块参数 `tokens` |
| Loon | `loon/po0-firewall-whitelist.plugin` | 插件设置 `API tokens` |
| Stash | `stash/po0-firewall-whitelist.stoverride` | 覆写内两处 `argument: tokens=` |
| Quantumult X | `quantumultx/po0-firewall-whitelist.snippet` | BoxJs key `po0fw_tokens` 或脚本内 `INLINE_TOKENS` |
| Shadowrocket | `shadowrocket/po0-firewall-whitelist.srmodule` | 长按模块编辑纯文本（多 token 用 `\|` 分割） |
| Egern | `egern/po0-firewall-whitelist.yaml` | 模块参数 `tokens` |

> 客户端模块的整理借鉴了 [reallinzc/po0fw](https://github.com/reallinzc/po0fw)，感谢原作者。

## 安装

### OpenWrt / Kwrt 软路由

```sh
curl -fsSL https://raw.githubusercontent.com/w0ven/po0fw/main/openwrt/install-openwrt.sh -o /tmp/i.sh
PO0FW_TOKENS="pgnfw_你的token" sh /tmp/i.sh
```

- cron 每 10 分钟兜底 + `hotplug.d/iface` WAN 变化即时触发（自动忽略纯 IPv6 接口避免重复并发）

### Linux / macOS / 安卓 Termux

```sh
curl -fsSL https://raw.githubusercontent.com/w0ven/po0fw/main/install-linux.sh | PO0FW_TOKENS="pgnfw_你的token" sh
```

- Linux（root + systemd）：安装至 `/usr/local/bin/po0fw` 并注册 `po0fw.timer`（每 10 分钟）
- macOS / 非 root 普通用户：安装至 `~/.local/bin/po0fw`（配置写于 `~/.config/po0fw/po0fw.conf`）并写入 crontab
- Termux：安装至 `$PREFIX/bin/po0fw`，自动装 cronie 并写 crontab（需 `sv-enable crond`）

### Windows

管理员 PowerShell：

```powershell
irm https://raw.githubusercontent.com/w0ven/po0fw/main/windows/install-windows.ps1 -OutFile i.ps1
powershell -ExecutionPolicy Bypass -File i.ps1 -Tokens "pgnfw_你的token"
```

- 注册静默计划任务（`wscript` 无黑框启动）：每 10 分钟 + 网络连接事件（EventID 10000，含 3 秒路由就绪延迟）双触发

## 用法

```sh
po0fw                          # 检查并按需加白（读取配置文件）
po0fw status                   # 只读查看白名单状态（GET 端点，绝不写入或挤占坑位）
po0fw pgnfw_xxx,pgnfw_yyy@0    # 临时指定 token；@0 = 固定 0 号槽位
po0fw --help                   # 查看命令行帮助
```

多 token：`pgnfw_aaa,pgnfw_bbb`；固定槽位：`pgnfw_aaa@0`（常驻不被淘汰，换槽前先在面板删旧槽）。

## 配置

| 位置 | 说明 |
|---|---|
| `/etc/po0fw.conf` | `PO0FW_TOKENS="pgnfw_xxx"`（Linux root / OpenWrt） |
| `~/.config/po0fw/po0fw.conf` | `PO0FW_TOKENS="pgnfw_xxx"`（macOS / 非 root 用户） |
| `%ProgramData%\po0fw\po0fw.conf` | Windows，支持纯 token 串或 `PO0FW_TOKENS="..."` |
| 环境变量 `PO0FW_TOKENS` | 优先级高于配置文件，低于命令行参数 |

## FAQ

**走代理会把代理 IP 加白吗？** 加白请求直连官方 IP `124.221.69.228`，普通域名分流代理不会劫持它；仅 TUN/透明代理全局接管时需加一条 `IP-CIDR,124.221.69.228/32,DIRECT,no-resolve`。

**IPv6？** po0 防火墙按 IPv4 `/24` 加白，脚本强制 IPv4 请求。

**白名单满了？** 服务端按写入时间 FIFO 淘汰，被挤出的设备最迟 10 分钟自动补回；家宽等核心出口建议加 `@0` 钉固定槽位。

## License

[MIT](LICENSE)
