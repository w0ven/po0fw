# iOS / macOS 自动加白

## 方案一：代理客户端脚本模块（推荐）

如果你在用 **Surge / Loon / Stash / Quantumult X / Shadowrocket / Egern**，可直接使用本仓库内置的六合一模块，支持面板状态展示、固定槽位 `📌` 标记、蜂窝 `📶` 标记、`network-changed` 切网即时触发与每 10 分钟 cron 兜底：

👉 **一键安装页：<https://po0fw.uuuz.de/>**（切到「iOS / Mac」标签页即可一键导入）

| 客户端 | 模块文件 | token 配置方式 |
|---|---|---|
| Surge | [`surge/po0-firewall-whitelist.sgmodule`](../surge/po0-firewall-whitelist.sgmodule) | 模块参数 `tokens`（多台机器用英文逗号 `,` 分割） |
| Loon | [`loon/po0-firewall-whitelist.plugin`](../loon/po0-firewall-whitelist.plugin) | 插件设置 `API tokens`（多台机器用英文逗号 `,` 分割） |
| Stash | [`stash/po0-firewall-whitelist.stoverride`](../stash/po0-firewall-whitelist.stoverride) | 覆写内两处 `argument: tokens=` 后补全 |
| Shadowrocket | [`shadowrocket/po0-firewall-whitelist.srmodule`](../shadowrocket/po0-firewall-whitelist.srmodule) | 长按模块 → 编辑纯文本，替换两行 `argument=tokens=` 后的占位（多台机器用 `\|` 分割） |
| Egern | [`egern/po0-firewall-whitelist.yaml`](../egern/po0-firewall-whitelist.yaml) | 模块参数 `tokens`（多台机器用英文逗号 `,` 分割） |
| Quantumult X | [`quantumultx/po0-firewall-whitelist.snippet`](../quantumultx/po0-firewall-whitelist.snippet) | 复制进本地 `[task_local]`，用 BoxJs 为 `po0fw_tokens` 写入 token |

- **固定槽位**：在 token 后加 `@槽位号`（`0`–`4`），如 `pgnfw_xxx@0`，常驻白名单不参与淘汰（建议仅给家宽等固定出口钉槽位，手机流动网络留空自愈即可）。
- 模块早期思路借鉴自群友 [reallinzc/po0fw](https://github.com/reallinzc/po0fw)，感谢原作者分享。

## 方案二：系统快捷指令（无需任何代理 App）

po0 加白只是一个 HTTP POST 请求，iOS / macOS 自带的「快捷指令」即可实现：

### 1. 建快捷指令

1. 打开「快捷指令」App → 新建快捷指令
2. 添加操作：`获取 URL 内容`
   - URL：`https://124.221.69.228/api/firewall/pgnfw_你的token/add`
   - 展开选项：方法选 **POST**
3. 命名为 `po0加白`，完成

点一下试跑一次，返回 JSON 里能看到 `whitelist` 包含当前网段即为成功。

### 2. 自动化触发

「自动化」标签 → 新建个人自动化：

- **连接 Wi-Fi 时**：触发条件选「Wi-Fi」→ 任意网络 → 立即运行（关掉「运行前询问」）→ 选择 `po0加白`
- 可选再建一条「打开常用 App 时」或「连接电源时」作为补充触发

> iOS 快捷指令没有严格的「每 10 分钟」后台定时；Wi-Fi 切换触发已覆盖回家/到公司/连热点等主要换 IP 场景。蜂窝场景频繁换 IP 的重度用户建议使用方案一的代理客户端模块。

### 多机器 / 固定槽位

- **多台机器**：在快捷指令里依次添加多个「获取 URL 内容」操作，各填一台机器的 token
- **固定槽位**：URL 末尾加 `?slot=0`（如 `https://124.221.69.228/api/firewall/pgnfw_你的token/add?slot=0`）
