# ScreenBeam

在 Mac 后台常驻，随时把当前屏幕截下来，用手机浏览器打开就能看。

没有客户端要装，没有账号要注册，不经过任何第三方服务器 —— 截图从你的 Mac 直接流到你的手机。

```
        ┌──────────────── Mac (后台常驻，无 Dock 图标) ────────────────┐
        │                                                             │
        │  ScreenCaptureKit ──▶ JPEG 编码 ──▶ 内存环形缓冲(最近 N 张)  │
        │        ▲                                  │                 │
        │        │                                  ▼                 │
        │   ┌────┴─────┐                     ┌──────────────┐         │
        │   │ BeamEngine│──── SSE 推送 ─────▶│  HTTP 服务    │         │
        │   │ 定时/手动 │                     │ 127.0.0.1 或 │         │
        │   └────┬─────┘                     │ 0.0.0.0:8787 │         │
        │        │                            └──────┬───────┘         │
        │        ▼                                   │                 │
        │   推送渠道 (可选)                   配对 ────┼──── 设备令牌     │
        │   Bark / ntfy / Telegram / 飞书 / Webhook    │                 │
        └────────────────────────────────────────────┼─────────────────┘
                                                     │ 局域网 / Tailscale
                                                     ▼
                                          ┌──────────────────────┐
                                          │  手机 Safari / Chrome │
                                          │  配对后实时查看、      │
                                          │  可远程截屏与切换模式  │
                                          └──────────────────────┘
```

---

## 它解决什么问题

想离开电脑的时候，用手机看一眼 Mac 上跑到哪了。市面上的方案要么得装客户端（Sidecar、Duet），要么走第三方服务器（各种截图云），要么是完整的远程桌面（重，且会把整个桌面暴露出去）。

这个工具只做一件事：**让你在手机上看到 Mac 屏幕，并且能主动触发一次截图**。

三种用法，按需选：

| 用法 | 需要什么 | 适合场景 |
| --- | --- | --- |
| 手机浏览器看 | 同一局域网 | 在家/办公室，最常见 |
| 推送通知 | Bark / ntfy / Telegram 等 | 想在手机上收到提醒 |
| 外网访问 | Tailscale 或 Cloudflare Tunnel | 不在同一网络 |

---

## 环境要求

- macOS 14 (Sonoma) 或更高 —— 用到 ScreenCaptureKit 的单帧截图 API `SCScreenshotManager`
- Swift 6 工具链。**只需要 Command Line Tools，不需要完整 Xcode**
- 首次运行需要授予「屏幕录制」权限

---

## 快速开始

```bash
cd ai4bagu
./scripts/install.sh          # 构建 .app → 安装 → 注册后台服务 → 申请权限
```

然后在弹出的对话框里允许，或手动到 **系统设置 → 隐私与安全性 → 屏幕录制** 勾选 PHONE·CATCH·SCREEN。授权后服务会自动重启生效。

```bash
screenbeam pair               # 生成 6 位配对码 + 二维码
```

手机扫这个二维码（或手动打开地址、输入码），就配对完成了。之后手机浏览器可以直接：

- 实时看到 Mac 屏幕（画面一变手机上就更新）
- 点 **截屏** 让 Mac 现在截一张
- 点 **连续** 让 Mac 开始每 10 秒自动截一张
- 在 **整屏 / 窗口** 之间切换取景范围
- 点 **解除配对** 撤销自己的访问

> `screenbeam` 装在哪？`~/Applications/PHONE·CATCH·SCREEN.app/Contents/MacOS/screenbeam`。
> `./scripts/install.sh` 不会把它放进 PATH，上面命令里的 `screenbeam` 需要你按这个路径调用，
> 或者自己加一个软链：`ln -s ~/Applications/PHONE-CATCH-SCREEN.app/Contents/MacOS/screenbeam /usr/local/bin/screenbeam`

---

## 配对是怎么工作的

不用共享密码，而是走一次性的配对码。三条设计约束：

**配对码只在这里用一次。** Mac 生成一个 6 位数字，5 分钟内有效，**兑换成功即销毁**。所以一个泄漏的旧配对码没有任何价值。

**6 位数字必须防爆破。** 一百万种组合，如果能在局域网上随便猜，几分钟就穷尽了。所以：单次有效 + 5 分钟过期 + 每个来源地址最多错 5 次（用完了这个来源就被拒，真手机在别的地址仍有自己的额度）+ 全局错误超过 50 次直接把码作废，谁都用不了。6 位数字的爆破窗口被压到 5 次尝试。

**配对码放在 URL 的 fragment 里。** 二维码编码的是 `http://192.168.1.5:8787/#pair=482913` —— 浏览器从不把 `#` 之后的内容发给服务器，所以配对码不会出现在任何请求日志或代理记录里。

配对成功后手机拿到一个 **设备令牌**，存在浏览器的 `localStorage` 里：

| | 主令牌（config.json） | 设备令牌（配对产生） |
| --- | --- | --- |
| 谁持有 | Mac 上的 CLI | 每台配对的手机 |
| 能看图、截屏、切模式、开关连续截图 | ✅ | ✅ |
| 能读主令牌 / 列出设备 / 撤销设备 / 重载配置 | ✅ | ❌ |
| 存在哪里 | 明文在 config.json | **只存 SHA-256 哈希**在 devices.json |

两个关键点：

- **设备令牌在 Mac 上只存哈希。** `devices.json` 泄漏了也拿不到能用的凭证 —— 服务端能验证你出示的令牌，但无法反推出它。
- **主令牌永远不会发到手机上。** 查看页的 HTML 里不含任何令牌；`/api/status` 也只在主令牌请求时才返回含主令牌的 `viewerURL`（已配对的手机请求它拿不到这个字段）。否则配对的手机只要读一次状态就提权了。

管理命令：

```bash
screenbeam devices                        # 列出已配对设备
screenbeam devices --revoke d-1a2b3c4d    # 撤销某台设备
```

设备令牌一旦撤销立即失效。手机端也可以自己点「解除配对」。

---

## 关键前提：为什么必须打包成 .app

这一节值得单独讲，它是整个项目里最容易踩坑的地方。

macOS 的屏幕录制权限（TCC）**不是绑定到程序名字上，而是绑定到代码身份上**。直接 `swift build` 出来的裸二进制没有稳定的代码身份，于是：

- 系统会把权限记在"谁启动了它"头上 —— 也就是终端
- 每次重新编译，二进制变了，权限就失效了

所以这个项目构建时做两件事：

1. 组装一个真正的 `.app`，`Info.plist` 里写死 `CFBundleIdentifier = com.sarainoq.screenbeam`
2. 对它签名（有证书就用证书，没有就 ad-hoc）

**两个必须知道的后果：**

- **授权后必须重启进程才生效。** macOS 不会把新授予的屏幕录制权限应用到正在运行的进程上。这个项目自动处理了：服务检测到权限从无变有时会以非零码退出，`launchd` 的 `KeepAlive` 立刻把它拉起来，新进程就带着权限了。
- **ad-hoc 签名下，每次重新构建都要重新授权。** ad-hoc 签名的指定要求就是二进制的哈希，重编译即变化，系统视其为另一个程序。如果你有 Apple 开发者证书，`scripts/build.sh` 会自动检测并使用，就不会有这个问题。

调试时想绕过这些？在终端里跑 `.build/debug/screenbeam` 会**继承终端已有的屏幕录制权限**（因为 TCC 把权限记在终端头上）。开发时方便，但这也正说明裸二进制不可靠。

---

## 命令参考

```
screenbeam <命令> [选项]
```

### 日常

| 命令 | 说明 |
| --- | --- |
| `run` | 前台运行后台服务（调试用，Ctrl-C 退出） |
| `shot` | 立即截一张 |
| `status` | 查看运行状态 |
| `url` | 显示管理入口、网络地址与二维码 |
| `logs --follow` | 实时看日志 |

### 配对与设备

| 命令 | 说明 |
| --- | --- |
| `pair` | 生成配对码 + 二维码，手机扫码即可连接 |
| `devices` | 列出已配对设备 |
| `devices --revoke <id>` | 解除某台设备的配对 |

### 安装与进程管理

| 命令 | 说明 |
| --- | --- |
| `install` | 安装 .app、注册 LaunchAgent、申请权限 |
| `uninstall` | 卸载（配置与日志保留） |
| `start` / `stop` / `restart` | 控制后台服务 |

### 其他

| 命令 | 说明 |
| --- | --- |
| `perm` | 查看权限；`--request` 申请并打开系统设置，`--wait` 阻塞等待授权 |
| `config` | 查看配置；`--edit` 编辑，`--path` 打印路径，`--init` 重建默认配置 |
| `selftest` | 运行内置自检（见下文） |
| `version` / `help` | |

### 通用选项

| 选项 | 说明 |
| --- | --- |
| `--config <路径>` | 使用指定的配置文件 |
| `--port` / `--host` / `--token` | 临时覆盖配置。**覆盖项对进程粘性生效**，`/api/reload` 不会把它们冲掉 |
| `--json` | `shot` / `status` 输出 JSON |

### shot 专用

```bash
screenbeam shot                          # 截一张，打印信息
screenbeam shot --out ~/Desktop/         # 存到目录，文件名用截图 ID
screenbeam shot --out shot.jpg           # 存到指定文件
screenbeam shot --out - > shot.jpg       # 写到标准输出
screenbeam shot --push                   # 截完顺手推送到手机
```

后台服务没在跑的时候，`shot` 会在本进程内直接截图 —— 所以绑个快捷键（Raycast / Alfred / skhd）调用 `screenbeam shot --push` 是完全可行的。

---

## 手机端使用

### 局域网

1. Mac 和手机连同一个 Wi-Fi
2. `screenbeam url`，用手机相机扫二维码，或者手动输入地址
3. 页面会自动实时更新 —— 每次 Mac 端截图，手机上立刻出现

页面上的按钮：

| 按钮 | 作用 |
| --- | --- |
| **截屏** | 让 Mac 现在截一张（手机上直接触发） |
| **连续:开/关** | 让 Mac 每 10 秒自动截一张（画面没变会跳过，不刷屏） |
| **整屏 / 窗口** | 切换取景范围。**窗口 = 只截最前台那个窗口**，分享时不会带上整个桌面 |
| **填充 / 适应** | 切换图片缩放方式 |
| **全屏** | 隐藏页面框架，只看图 |
| **问 AI** | 打开问答面板，就当前这张截图向模型提问（见下） |
| **保存** | 把当前这张图下载到手机（存到「文件 → 下载」；长按图片可直接存到相册） |
| **解除配对** | 撤销这台手机的访问权 |

页面通过 SSE（Server-Sent Events）接收更新。如果网络环境会把 SSE 缓冲掉（部分公司代理会），页面会自动退化成每 3 秒轮询一次。

### 问 AI：让模型看这张截图

点 **问 AI** 打开底部面板，输入问题，模型会拿到**当前显示的这张截图**作为上下文来回答。可以连续追问，历史会一起带上。

- **图片只带当前这张。** 追问时不会重复回放历史里的图片，否则每一轮都会重复计费。换一张新截图会自动清空对话 —— 之前的回答是针对另一张图的。
- **API 就在面板下方配置**：提供商、Base URL、模型、API Key。填完勾选「启用」并保存。
- **Key 保存在 Mac 上**（`config.json`），不会发回手机：读取接口只返回「是否已配置」，面板里的 Key 输入框永远是空的，留空表示不修改。

支持两种接口形状：

| 提供商 | 说明 |
| --- | --- |
| **Anthropic** | Messages API，默认模型 `claude-opus-5` |
| **OpenAI 兼容** | chat/completions 形状。覆盖 OpenAI，以及 DeepSeek、Moonshot、通义、智谱、SiliconFlow、Ollama 等一切兼容端点 —— 改 Base URL 和模型名即可 |

**模型必须支持图片输入**，否则接口会报错。纯文本模型不能用。

> ⚠️ 当前版本是**一次性返回**，没有流式输出 —— 模型思考期间面板上会显示「思考中」，等模型返回完整答案。视觉模型通常几秒到几十秒。

### 定时截图

编辑配置把 `watch.enabled` 改成 `true`，服务会按 `intervalSeconds` 定时截图。默认开了 `onlyOnChange`，画面没变化就不重复截图，避免刷屏。

```json
"watch": {
  "enabled": true,
  "intervalSeconds": 10,
  "onlyOnChange": true,
  "changeThreshold": 0.02,
  "pushOnCapture": false
}
```

也可以从手机或命令行临时开关：`curl -X POST ".../api/watch/toggle?token=<token>"`。

### 外网访问

不打算自己实现打洞和 TLS。推荐两种做法：

- **Tailscale**（推荐）：装上之后 Mac 会得到一个 `100.x.y.z` 地址，手机装同样的客户端，直接访问 `http://100.x.y.z:8787/?token=...`。地址也可以写进配置的 `server.publicBaseURL`，这样推送通知里的链接在外面也能打开。
- **Cloudflare Tunnel**：`cloudflared tunnel --url http://127.0.0.1:8787`，把拿到的公网域名填进 `server.publicBaseURL`。

⚠️ 无论哪种，**只要暴露到公网就请务必使用一个强 token**，并考虑把 `server.port` 换掉。这个服务给任何人一个 token 就能看到你的屏幕。

---

## 推送渠道

编辑 `screenbeam config --edit`，把对应渠道的 `enabled` 改成 `true` 并填上凭据，然后 `screenbeam restart`（或 `curl -X POST .../api/reload`）。

各渠道能力不同，这里如实说明：

| 渠道 | 能否直接发图 | 说明 |
| --- | --- | --- |
| **Telegram** | ✅ 上传图片本体 | 唯一完全不依赖局域网/公网的渠道，人在外面就用它 |
| **飞书**（应用模式） | ✅ 上传图片本体 | 需要 app_id + app_secret + chat_id |
| **飞书**（Webhook 模式） | ❌ 只发卡片+链接 | 自定义机器人拿不到 `img_key`，只能发跳转按钮 |
| **Bark** | ⚠️ 有条件 | Bark 的 `image` 字段是让 **Bark 服务器去拉取** 那个 URL，所以只有公网可达地址才有用 |
| **ntfy** | ⚠️ 有条件 | 同上，`Attach` 头由 ntfy 服务器拉取 |
| **Webhook** | 自定义 | 见下文 |

**为什么 Bark / ntfy 默认走链接？** 因为你的图片地址是 `http://192.168.x.x:8787/...`，Bark 的服务器根本访问不到。所以这两个渠道主要靠"点击通知 → 打开查看页"这条路径，而查看页在局域网里是能用的。如果你配了 `server.publicBaseURL`（Tailscale / 隧道），代码会自动把图片地址一起带上。

### 配置示例

```jsonc
"channels": [
  // Telegram：唯一能把图片本体送出去的渠道
  { "kind": "telegram", "enabled": true, "botToken": "123456:ABC...", "chatId": "987654321" },

  // Bark
  { "kind": "bark", "enabled": true, "deviceKey": "你的Bark密钥",
    "server": "https://api.day.app", "sound": "birdsong", "attachImage": false },

  // ntfy
  { "kind": "ntfy", "enabled": true, "server": "https://ntfy.sh",
    "topic": "你的私有topic", "authToken": "" },

  // 飞书：只填 webhook → 卡片模式；三个都填 → 直接发图
  { "kind": "feishu", "enabled": true,
    "webhook": "https://open.feishu.cn/open-apis/bot/v2/hook/xxx",
    "botToken": "cli_xxx", "authToken": "应用密钥", "chatId": "oc_xxx" },

  // 通用 Webhook：Slack / Discord / n8n / 自建都行
  { "kind": "webhook", "enabled": true, "url": "https://hooks.slack.com/services/xxx",
    "bodyTemplate": "{\"text\":\"{{text}}\",\"image\":\"{{image_url}}\"}" }
]
```

Webhook 模板里可用的占位符：`{{text}}` `{{image_url}}` `{{viewer_url}}` `{{source}}` `{{host}}` `{{time}}` `{{image_base64}}`。

`{{image_base64}}` 会把图片以 data URI 内联进去 —— 只在模板里真的用到时才计算，因为 base64 会让体积涨三分之一。

每次截图都会推送吗？不是。默认只在 `watch.pushOnCapture` 为 true 时推送定时截图；手动截图默认不推送。想改就调 `notify.onManualCapture`。

---

## 配置文件

`~/Library/Application Support/PHONE-CATCH-SCREEN/config.json`，首次运行自动生成。

```jsonc
{
  "server": {
    "host": "127.0.0.1",        // 默认只绑本机；要让手机连上改成 "0.0.0.0"
    "port": 8787,
    "token": "自动生成的32位十六进制",
    "publicBaseURL": ""         // 有域名/隧道时填写，用于生成推送里的链接
  },
  "capture": {
    "mode": "display",          // display = 整个屏幕；window = 只截最前台窗口
    "displayIndex": 0,          // 多显示器时的序号
    "format": "jpeg",           // jpeg | png
    "quality": 0.75,            // JPEG 质量 0~1
    "maxLongEdge": 1600,        // 长边缩放到该像素数，0 = 不缩放
    "showCursor": true
  },
  "watch": {
    "enabled": false,
    "intervalSeconds": 10,
    "onlyOnChange": true,
    "changeThreshold": 0.02,    // 画面差异超过该比例才算"变了"
    "pushOnCapture": false
  },
  "history": {
    "keepInMemory": 24,         // 内存里保留最近多少张
    "saveDirectory": null,      // 设成路径可额外落盘，例如 "~/Pictures/ScreenBeam"
    "retentionMinutes": 120
  },
  "notify": {
    "onManualCapture": false,
    "caption": "PHONE·CATCH·SCREEN · {host} · {time}",
    "channels": [ /* 见上文 */ ]
  },
  "llm": {                      // 手机端「问 AI」面板里也能改
    "enabled": false,
    "provider": "anthropic",    // anthropic | openai（OpenAI 兼容）
    "baseURL": "https://api.anthropic.com",
    "apiKey": "",               // 只写不读：读取接口永不返回它
    "model": "claude-opus-5",   // 必须支持图片输入
    "maxTokens": 16000,         // 别设太小，思考也会占用这个额度
    "effort": "low",            // Anthropic 专用：low|medium|high|xhigh|max
    "systemPrompt": "……",       // 默认已针对「看截图回答问题」调过
    "timeoutSeconds": 120,
    "useFallbacks": true        // Anthropic 专用：被安全策略拒绝时自动转其他模型
  },
  "logging": {
    "level": "normal"           // quiet | normal | debug（开发用）
  }
}
```

**容错设计**：配置是给人手改的，所以缺字段、多字段、类型写错都不会导致服务起不来 —— 一律回退到默认值。

`caption` 可用占位符：`{host}` `{time}` `{date}` `{source}` `{width}` `{height}` `{url}`。

关于 `llm` 的几个坑：
- **`useFallbacks` 会发一个 beta 头**（`server-side-fallback-2026-07-01`）。如果你用的中转/代理不认这个头，请求会直接失败 —— 把它设成 `false` 即可。
- **`effort` 只有较新的 Anthropic 模型支持**。换成老模型时报错的话，把它设成 `null`（或删掉这一行）。
- **在手机上切换 provider 会自动改 Base URL**（切到对应服务的默认地址），但**不会**动模型名 —— 模型得你自己填对，因为只有你知道要用哪个。
- **`apiKey` 明文存在这个文件里**，权限是 `0600`。它只写不读：读取接口永远不会把它发回手机。

关于 `logging.level`：

| 级别 | 记什么 | 用途 |
| --- | --- | --- |
| `quiet` | 只有警告和错误 | |
| `normal`（默认） | 启动、权限、配对、错误 —— **不记每次截图** | 日常使用 |
| `debug` | 全部，包括每次截图、查看端连接、AI 调用 | 开发排查 |

开发时不用改配置：`SCREENBEAM_LOG=debug screenbeam run` 会覆盖配置里的级别。

**为什么 `normal` 下那些记录是真的不存在**：`os_log` 的 debug 级消息默认不落盘（只在有调试器或 `log stream` 附着时才有）。所以降级到 `debug` 不是「藏起来」，是根本不写。日志文件里没有，统一日志里也没有。

### 隐私模式：只截当前窗口

```jsonc
"capture": { "mode": "window" }
```

截图前会找最前台应用的最前面那个窗口（跳过提示框、阴影这类非普通窗口），只截它。想分享一个窗口又不想带上整个桌面时用这个。

---

## HTTP API

凭证通过 `?token=xxx` 或 `X-Auth-Token` 头传递，可以是**主令牌**或**设备令牌**。带 🔑 的接口只有主令牌能用。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/healthz` | 存活探测，**无需凭证** |
| GET | `/` | 手机查看页，**无需凭证**（页面内含配对界面，必须配对前就能打开） |
| POST | `/api/pair` | 用配对码换设备令牌，**无需凭证**（配对码本身即凭证） |
| GET | `/api/status` | 运行状态。主令牌才返回 `viewerURL` |
| GET | `/api/latest` | 最新一张的元信息 |
| GET | `/api/frames?limit=30` | 最近若干张的元信息列表 |
| GET | `/api/frame/<id>.<ext>` | 图片本体。`<id>` 可以用 `latest` 作别名 |
| GET | `/api/events` | SSE 事件流（`hello` / `shot` / `watch` / `settings` / `permission` / `devices`） |
| GET/POST | `/api/shot` | 立刻截一张 |
| POST | `/api/watch/start\|stop\|toggle` | 开关定时截图 |
| POST | `/api/capture/mode?mode=display\|window` | 切换整屏 / 当前窗口（会写回配置文件） |
| POST | `/api/push?recapture=1` | 推送最新一张 |
| POST | `/api/unpair` | 设备自己解除配对 |
| GET | `/api/llm/config` | 读取 AI 设置。**永不返回 API Key**，只返回 `hasKey` |
| POST | `/api/llm/config` | 修改 AI 设置。`apiKey` 只写不读，留空表示不修改 |
| POST | `/api/llm/ask` | `{question, shotId?, history?}` → 就当前截图提问 |
| POST | `/api/pair/code` | 🔑 生成新的配对码 |
| GET | `/api/devices` | 🔑 列出已配对设备（不含令牌，也不含哈希） |
| POST | `/api/devices/revoke?id=<id>` | 🔑 撤销设备 |
| POST | `/api/reload` | 🔑 重新读取配置文件 |

`/api/frame/latest.jpg` 这个别名很好用 —— 地址固定不变，每次取的都是最新一张，可以直接喂给 iOS 快捷指令、桌面小组件、或者 nginx 反代。

```bash
# 复制到剪贴板
screenbeam shot --out - > /tmp/s.png && open /tmp/s.png
```

---

## 自检

```bash
screenbeam selftest              # 跑全部 50 项
screenbeam selftest --verbose    # 列出每一项
screenbeam selftest --filter 二维码
```

**为什么是内置命令而不是 `swift test`？** 因为 XCTest 和 swift-testing 都需要完整 Xcode，而本项目面向只装了 Command Line Tools 的机器 —— 测试目标在那台机器上根本跑不起来。所以测试用例直接编译进库，跟着二进制一起发布，任何一次构建都能验证。

覆盖的是几处"出错也不报错"的地方：

- **二维码渲染** —— 渲染出来的 ASCII 会被重新解析成位图、交给系统 `CIDetector` 解码，断言解出来的就是原始 URL。另外单独断言定位图案的极性，因为**反色的二维码相机往往照样能扫**，只靠解码测试抓不到。
- **HTTP 请求解析** —— 逐字节投递、请求头跨包、请求体未收全、畸形请求行等。
- **画面变化检测** —— 确认光标闪烁级别的小变化不会触发阈值。
- **配置容错** —— 缺字段 / 类型写错 / 枚举非法都要回退到默认值而不是崩。
- **推送文本转义** —— 说明文字里的引号和换行不能让 webhook 的 JSON 变得非法。

---

## 排错

### 手机上打不开

1. `screenbeam status` 看服务是否在跑
2. 确认 `server.host` 是 `0.0.0.0` 而不是 `127.0.0.1` —— 后者只允许本机访问（这是有意的严格限制，不仅是绑定地址，服务端也会拒绝外部来源）
3. Mac 和手机是不是真的同一个 Wi-Fi。有些路由器开了「AP 隔离」，会阻止设备互访
4. macOS 防火墙：系统设置 → 网络 → 防火墙，允许 ScreenBeam 接受传入连接

### 截图报「缺少屏幕录制权限」

```bash
screenbeam perm              # 看当前状态
screenbeam perm --request    # 申请并打开系统设置
screenbeam restart           # 授权后重启服务让它生效
```

系统对话框一个 bundle 只弹一次。已经被拒绝过的话，`--request` 不会再弹，只能去系统设置里手动勾。

### 端口被占用

```
错误：HTTP 服务绑定失败：0.0.0.0:8787 — ...
```

换个端口：`screenbeam run --port 8899`，或改配置里的 `server.port`。也可以用 `lsof -nP -iTCP:8787` 看是谁占着。

### curl 访问本机地址返回 502

检查环境里有没有设代理：

```bash
env | grep -i proxy
```

如果设了 `http_proxy`，curl 会把 `127.0.0.1` 的请求也发给代理，代理连不上就回 502。用 `curl --noproxy '*'` 绕过，或临时 `export no_proxy='*'`。

（浏览器和手机不受影响，这纯粹是 curl 的行为。）

### 重新构建后权限又没了

ad-hoc 签名的固有问题，见上文「关键前提」。治本办法是弄一个 Apple 开发者证书 —— `scripts/build.sh` 会自动检测并使用。

### 查看日志

```bash
screenbeam logs               # 最近 40 行错误输出
screenbeam logs --follow      # 实时
screenbeam logs --stdout      # 看标准输出
```

日志文件在 `~/Library/Logs/ScreenBeam/`。

---

## 安全说明

### 先分清防的是什么

这个工具能防的是**网络上的别人**和**意外泄漏**。它**防不了**以你的身份运行的程序 —— 那是 macOS 的设计，不是这个项目的疏漏，见下面「平台边界」。

### 默认不对外暴露

- **`server.host` 默认 `127.0.0.1`**，只绑本机。要手机连上必须显式改成 `0.0.0.0`，而且启动时和 `screenbeam url` 都会明确提示「服务已对局域网开放」。
- **`server.host = 127.0.0.1` 时是强制的**，不只是绑定地址。服务会检查连接来源，非本机来源直接拒绝 —— 就算绑定出了问题也拦得住。

### 凭证

- **两套凭证。** 主令牌（config.json，CLI 用）和设备令牌（配对产生，每台手机一个）。主令牌能管理访问权限，设备令牌不能。
- **设备令牌只存哈希。** `devices.json` 权限 `0600`，里面是 SHA-256，不是令牌本身 —— **明文在手机上，不在 Mac 上**。所以即使这份文件被读走也拿不到可用的东西。
- **主令牌不进手机。** 查看页 HTML 不含任何令牌；`/api/status` 只在主令牌请求时返回含主令牌的 `viewerURL`。
- **配对码单次有效、5 分钟过期、每来源限 5 次错误。** 6 位数字的爆破窗口被压到 5 次尝试。配对码本身也不再写进日志。
- **令牌比较是常量时间的**，不给出时序侧信道。

### 记录

- **日志默认不记「什么时候截了图」。** `logging.level` 默认 `normal`，只记启动、权限、配对和错误；每次截图、查看端连接这类例行活动降级到 `debug`，而 `os_log` 的 debug 级消息默认不落盘 —— 所以它们是真的不存在，不是被藏起来。
- **统一日志里消息内容是 `.private`。** `log show --predicate 'subsystem == "com.sarainoq.screenbeam"'` 任何进程都能跑，但只能看到时间戳和进程名，内容显示为 `<private>`。完整明文留在你自己那个 `0600` 的日志文件里。
- **文件和目录权限收紧。** 配置、凭据 `0600`，日志 `0600`，目录 `0700`。

### 其他

- **没有 HTTPS。** 局域网内的被动嗅探需要主动 MITM（现代 Wi-Fi 有链路层加密），但如果是不受控的网络（咖啡馆、酒店），或者同网段有不信任的设备，请用 Tailscale 而不是直接把端口开在局域网上。
- **图片不缓存。** 所有响应都带 `Cache-Control: no-store`。
- **查看页不引用任何外部资源** —— 没有 CDN、没有统计、没有第三方 JS。一个能看到你屏幕的页面，不该同时加载别人的脚本。

### 平台边界：防不了什么

**macOS 对「同一个用户下的两个进程」之间不存在应用层边界。** 沙盒化的 app 有真正的隔离，但截屏工具**必须**是非沙盒的。

实测过（本机，macOS 15）：

| 尝试 | 结果 |
| --- | --- |
| 令牌存进 Keychain，另一个程序去读 | **读到了**，无提示 |
| 令牌存进 Keychain 并显式指定只信任本程序的 ACL，另一个程序去读 | **还是读到了** |

`SecAccessCreate` / `SecTrustedApplicationCreateFromPath` 自 10.10 起被标记废弃，实际拦截能力已被移除。**所以本项目没有用 Keychain 存令牌** —— 它不构成边界，用了只是把复杂度换成了「看起来安全」。

**结论**：一个以你的身份运行的程序，能读你的配置文件、日志、剪贴板、以及你正在看的一切。这一层要靠系统层面的做法（不装来路不明的软件、可疑的东西放低权限账户里跑、别关 SIP 和 Gatekeeper），不是这个工具能解决的。

### 一个取舍

设备令牌存在浏览器 `localStorage` 里。任何能在那台手机上执行 JS 的东西都能读走它。个人自用是合理取舍；要和别人共用设备，用完点「解除配对」。

截图本身可能包含密码、聊天记录、邮件。分享访问权就等于分享这些。


---

## 代码导览

```
Sources/ScreenBeamCore/
  Capture/
    ScreenRecordingPermission.swift   TCC 权限探测/申请/等待
    ScreenCapturer.swift              ScreenCaptureKit 单帧截图 + 前台窗口定位
    ImageEncoder.swift                缩放 + JPEG/PNG 编码
    ChangeDetector.swift              32×32 灰度缩略图差分
  Pairing/
    SecureToken.swift                 CSPRNG 令牌/配对码生成、SHA-256、常量时间比较
    DeviceStore.swift                 已配对设备，只存哈希，权限 0600
    PairingSession.swift              配对码生命周期 + 防爆破
  Net/
    HTTPServer.swift                  NWListener 上的 HTTP/1.1 服务
    HTTPResponder.swift               单连接响应/分块流/多路关闭回调
    HTTPMessage.swift                 增量式请求解析 + 响应序列化
    EventBus.swift                    SSE 广播 + 心跳
    WebViewer.swift                   手机端页面（自包含，无外部依赖）
    TerminalQRCode.swift              CoreImage 生成 + 半块字符渲染
    NetInfo.swift                     网卡地址枚举
  Notify/                             各推送渠道，统一 Notifier 协议
  Engine/
    BeamEngine.swift                  编排：截图 / 存储 / 定时 / 推送 / 权限监管 / 配对
    Router.swift                      路由 + 双凭证鉴权
  Store/ShotStore.swift               有界环形缓冲 + 可选落盘
  Config/BeamConfig.swift             Codable 配置，容错解码
  SelfTest/                           内置测试用例
Sources/screenbeam/                   CLI 入口、命令、安装器、LaunchAgent
Resources/Info.plist                  bundle 模板
scripts/                              build / install / uninstall
```

几个值得留意的实现选择：

- **HTTP 服务是手写的，没有用 SwiftNIO。** 需求很小（一个页面、几个 JSON 接口、一个事件流），手写让依赖为零、行为完全可审计 —— 这对一个能看到屏幕的进程很重要。代价是只支持 HTTP/1.1 的一个子集：每个连接一个请求、不实现 keep-alive、不支持分块上传。
- **事件用 SSE 而不是 WebSocket。** 单向推送用 SSE 足够，浏览器原生支持，断线自动重连，实现量小一个数量级。
- **截图串行化。** 手机触发的截图和定时器触发的截图会抢同一套 ScreenCaptureKit 资源，用一个自制的异步互斥（`AsyncMutex`）排队。Swift 的 `actor` 在这里不够 —— actor 方法里的 `await` 是可重入的，两次截图还是会重叠。
- **图片存的是编码后的字节而不是 `CGImage`。** 缓冲区会被 HTTP 连接线程读取，`CGImage` 在这个场景里拷来拷去不划算。
- **配对码比对也是常量时间的**，和令牌一致 —— 6 位数字空间小，不给出任何额外的可利用信息。
- **前端不用像素字体，用像素化的几何。** 硬边直角、块状字符、等宽数字、扫描线叠加、反色高亮。真正的像素字体覆盖不了 CJK，手机上中文会糊。所以字体链是分开的：**数字与拉丁文走等宽并收紧字距，中文回落到 PingFang 这类可读字体**。

---

## 已知限制

- 只截图，不录音、不录视频（定时截图的连续帧勉强算个幻灯片）
- 窗口模式只支持「当前最前台窗口」，没有窗口选择器
- 不支持多显示器拼接，一次只截一个显示器
- 没有菜单栏图标 —— 它就是个纯粹的背景服务，没有 UI
- 没有 HTTPS，外网访问请走 Tailscale / 隧道
- 权限只有一个共享 token，没有多用户概念

---

## 参考过的开源项目

动手前看过的一些实现，供进一步参考：

- [Weylus](https://github.com/H-M-H/Weylus) —— 用「本地 Web 服务 + 浏览器访问」把屏幕投到平板，验证了这条链路；它的帧走 WebSocket + fMP4，本项目只需要静态帧所以用了更简单的 SSE
- [opendisplay](https://github.com/peetzweg/opendisplay) —— Sidecar 替代品，ScreenCaptureKit + VideoToolbox 投到 iPhone
- [Capso](https://github.com/lzhgus/Capso) / [Snapzy](https://github.com/duongductrong/Snapzy) —— Swift 6 + SwiftUI 的 macOS 截图工具，可参考窗口捕获与标注的完整实现
- [screencapturekit-rs](https://github.com/doom-fish/screencapturekit-rs) —— ScreenCaptureKit 的 FFI 绑定，API 表面梳理得比较清楚

这些项目里没有做「后台静默截图 + 推送到手机」的，所以这块是空白，本项目自己写。

---

## 卸载

```bash
./scripts/uninstall.sh
```

会停掉服务、移除 `~/Applications/PHONE-CATCH-SCREEN.app` 和 LaunchAgent。配置和日志保留在：

```
~/Library/Application Support/ScreenBeam/
~/Library/Logs/ScreenBeam/
```

最后记得去 **系统设置 → 隐私与安全性 → 屏幕录制** 手动删掉 ScreenBeam 那条记录。
