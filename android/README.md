# 安卓自动加白

安卓主流代理客户端（Clash Meta / mihomo、sing-box、Surfboard 等）通常**没有通用脚本引擎**。但 po0 加白只是一个直连 IP 的 POST 请求，用自动化 App 实现简单可靠，且**不依赖特定代理客户端**。

> 提示：你也可以在 [<https://po0fw.uuuz.de/>](https://po0fw.uuuz.de/) 粘贴 token，自动生成带槽位或多台机器的完整请求地址。

加白请求（把 token 换成你自己的）：

```
POST https://124.221.69.228/api/firewall/pgnfw_你的token/add
```

## 方案一：MacroDroid（推荐，免 root）

[MacroDroid](https://play.google.com/store/apps/details?id=com.arlosoft.macrodroid) 免费版支持 5 个宏，足够用。

建 2 个宏：

**宏 1 · 网络切换即时加白**
- 触发器：`连接性` → `网络连接变化`（Wi-Fi 连接 / 移动数据连接 都勾上）
- 动作：`网络` → `HTTP 请求`
  - 方法 `POST`，URL 填上面的加白地址
  - 其他留默认
- 约束：无

**宏 2 · 每 15 分钟兜底**
- 触发器：`日期/时间` → `定期触发`，间隔 15 分钟
- 动作：同上的 HTTP POST
- 建议加约束：`网络已连接`（避免断网时空跑）

> 多台 po0 机器：在同一个宏里加多个 HTTP 请求动作，每个填不同 token 的 URL。
> 固定槽位：URL 末尾加 `?slot=0`（注意是查询参数 `?slot=0`，不要写成 `@0/add`）。

装好后给 MacroDroid 关掉电池优化（App 会引导），否则后台定时可能被杀。

## 方案二：HTTP Shortcuts（极简开源）

[HTTP Shortcuts](https://play.google.com/store/apps/details?id=ch.rmy.android.http_shortcuts)：

1. 新建快捷方式 → 方法 `POST` → URL 填加白地址
2. 设置 → 定时执行 → 每 15 分钟
3. 可再配合桌面小部件一键手动加白

## 方案三：Termux（命令行）

见仓库根目录 [install-linux.sh](../install-linux.sh)，自动识别 Termux 环境：

```sh
pkg install -y curl
curl -fsSL https://raw.githubusercontent.com/w0ven/po0fw/main/install-linux.sh | PO0FW_TOKENS="pgnfw_你的token" sh
sv-enable crond
```

## 方案四：社群内置加白客户端（po0-clash）

热心网友维护的 [po0-clash](https://github.com/yuuuki-creation/po0-clash)（基于 FlClash）已在客户端内置自动加白逻辑，适合希望在同一个 App 里管理代理与白名单的用户（使用教程见 [wiki.uuuz.de](https://wiki.uuuz.de/guide/clients/po0-clash)，Android 首次启用后需重启一次 VPN）。

## 建议

如果你家里有软路由且手机主要在家用 —— **直接在软路由装**（见 [openwrt/](../openwrt/)），手机连家里 Wi-Fi 时天然被覆盖，只有出门用蜂窝时才需要手机端加白。
