# po0fw

po0 防火墙自动加白 —— PC（Linux / macOS / Windows）、安卓 Termux、软路由（OpenWrt / Kwrt）通用版。

> 灵感来自群友的 iOS 客户端脚本（Surge / Loon / Stash / QX / Shadowrocket / Egern），本项目把同样的加白逻辑带到桌面与路由器平台。

## 原理

- 每 10 分钟（+ 网络切换事件）向 po0 官方 **IP 直连端点**发起加白：
  `POST https://124.221.69.228/api/firewall/<token>/add`
- 服务端按请求来源 IP 自动识别 `/24` 网段并**幂等**加白（已在白名单则不占新坑、不推进 FIFO 淘汰）
- 客户端无需自行探测出口 IP，也**无需配置任何代理分流规则**（IP 直连不经 DNS/域名分流）
- 支持 `@槽位` 固定坑位；多台 po0 机器 token 用英文逗号分割

> 提示：若设备跑了 TUN 全局代理，建议加一条 `IP-CIDR,124.221.69.228/32,DIRECT,no-resolve` 保证加白请求直连。

Token 在 po0 控制台机器详情页「防火墙」卡片获取，形如 `pgnfw_...`。**token 即加白凭证，请勿公开分享。**

## 平台总览

| 平台 | 方案 | 触发方式 |
|---|---|---|
| Linux / macOS | 本仓库 shell 脚本 | systemd timer / cron 每 10 分钟 |
| OpenWrt / Kwrt 软路由 | 本仓库 shell 脚本 | cron + hotplug WAN 重连秒级触发 |
| Windows | 本仓库 PowerShell | 计划任务：10 分钟 + 网络事件 |
| 安卓 | [android/](android/)：MacroDroid / HTTP Shortcuts / Termux | 网络切换 + 定时 |
| iOS/Mac 代理客户端 | 本仓库脚本模块：Surge / Loon / Stash / QX / Shadowrocket / Egern（[一键安装页](https://po0fw.uuuz.de/)） | network-changed 即时 + 10 分钟 cron |
| iOS 无代理 App | [ios/](ios/)：快捷指令自动化 | Wi-Fi 切换触发 |

## iOS / Mac 代理客户端模块

Surge / Loon / Stash / Quantumult X / Shadowrocket / Egern 六客户端脚本模块（共享环境兼容层），带面板显示、蜂窝 📶 标记、network-changed 即时触发 + 每 10 分钟 cron 兜底：

👉 **一键安装页：<https://po0fw.uuuz.de/>**

| 客户端 | 载体 | token 配置 |
|---|---|---|
| Surge | `surge/po0-firewall-whitelist.sgmodule` | 模块参数 `tokens` |
| Loon | `loon/po0-firewall-whitelist.plugin` | 插件设置 `API tokens` |
| Stash | `stash/po0-firewall-whitelist.stoverride` | 覆写内 `argument: tokens=` |
| Quantumult X | `quantumultx/po0-firewall-whitelist.snippet` | BoxJs key `po0fw_tokens` 或脚本内 `INLINE_TOKENS` |
| Shadowrocket | `shadowrocket/po0-firewall-whitelist.srmodule` | 模块编辑参数（多 token 用 `\|` 分割） |
| Egern | `egern/po0-firewall-whitelist.yaml` | 模块参数 `tokens` |

> 模块部分借鉴自 [reallinzc/po0fw](https://github.com/reallinzc/po0fw)，感谢原作者。

## 安装

### Linux / macOS / 安卓 Termux

```sh
curl -sSL https://raw.githubusercontent.com/w0ven/po0fw/main/install-linux.sh | PO0FW_TOKENS="pgnfw_你的token" sh
```

- Linux(root)：装为 systemd timer（`po0fw.timer`，每 10 分钟）
- macOS / 非 root：写入 crontab
- Termux：自动装 cronie 并写 crontab（需 `sv-enable crond`）

### OpenWrt / Kwrt 软路由

```sh
curl -sSL https://raw.githubusercontent.com/w0ven/po0fw/main/openwrt/install-openwrt.sh -o /tmp/i.sh
PO0FW_TOKENS="pgnfw_你的token" sh /tmp/i.sh
```

- cron 每 10 分钟兜底 + `hotplug.d/iface` WAN 变化即时触发（PPPoE 重拨秒级加白）

### Windows

管理员 PowerShell：

```powershell
irm https://raw.githubusercontent.com/w0ven/po0fw/main/windows/install-windows.ps1 -OutFile i.ps1
powershell -ExecutionPolicy Bypass -File i.ps1 -Tokens "pgnfw_你的token"
```

- 注册计划任务：每 10 分钟 + 网络连接事件（EventID 10000）双触发

## 用法

```sh
po0fw                          # 检查并按需加白（读 /etc/po0fw.conf）
po0fw status                   # 只看白名单状态
po0fw pgnfw_xxx,pgnfw_yyy@0    # 临时指定 token；@0 = 固定 0 号槽位
```

多 token：`pgnfw_aaa,pgnfw_bbb`；固定槽位：`pgnfw_aaa@0`（常驻不被淘汰，换槽前先在面板删旧槽）。

## 配置

| 位置 | 说明 |
|---|---|
| `/etc/po0fw.conf` | `PO0FW_TOKENS="pgnfw_xxx"`（Linux/OpenWrt） |
| `%ProgramData%\po0fw\po0fw.conf` | Windows，纯 token 串 |
| 环境变量 `PO0FW_TOKENS` | 优先级最高（低于命令行参数） |

## FAQ

**走代理会把代理 IP 加白吗？** 加白请求直连官方 IP `124.221.69.228`，普通域名分流代理不会劫持它；仅 TUN/透明代理全局接管时需加一条 `IP-CIDR,124.221.69.228/32,DIRECT,no-resolve`。

**IPv6？** po0 防火墙按 IPv4 /24 加白，脚本强制 `-4`。

**白名单满了？** 服务端按写入时间 FIFO 淘汰，被挤出的设备最迟 10 分钟自动补回。

## License

MIT
