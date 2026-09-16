# AGENTS.md — 在本仓库工作前必读

## 屏幕录制权限与重建：实测行为不一致，按「失败就补」处理

这个 app 是 ad-hoc 签名（`codesign -dv` 显示 `TeamIdentifier=not set`），TCC 对它的识别依赖二进制的
代码哈希。**重建之后权限是否还有效，实测是不一致的：**

| 观察 | 结果 |
| --- | --- |
| 某次重建替换安装后 | 整屏和窗口模式截图**都正常**，没碰系统设置 |
| 另一次重建替换安装后 | 截图**失败**，报缺少权限 |
| 同一台机器、同样的操作 | **两次结果不同** |

所以不要预设任何一种结论 —— **以实际截图结果为准**，失败再补。这是 ad-hoc 的固有表现，
想要稳定就给 app 一个固定身份（见下「自签名证书」）。

**不要相信预检值。** `status` 里的 `permissionPreflight` 是 `CGPreflightScreenCaptureAccess()` 的结果，
它在进程内被缓存：一个进程被回答过「没有权限」之后会一直这么回答，即使权限本身有效。看 `screenCapture` 字段：

| `screenCapture` | 含义 |
| --- | --- |
| `working` | 最近一次截图成功了 —— **这就是结论** |
| `denied` | 最近一次截图因权限被拒 |
| `unknown` | 还没截过图 |

**截图报「缺少屏幕录制权限」时的处理顺序：**

```bash
BIN=~/Applications/PHONE-CATCH-SCREEN.app/Contents/MacOS/screenbeam

# 1. 先重启一次 —— 新进程会重新读权限，有时这样就够了
"$BIN" restart && sleep 5 && "$BIN" status

# 2. 仍然失败：清掉那条陈旧记录
tccutil reset ScreenCapture com.sarainoq.screenbeam

# 3. 重启，让守护进程重新登记自己并弹出授权对话框，点「允许」
"$BIN" restart

# 4. 再重启一次让新授权生效，然后验证
"$BIN" restart && sleep 5 && "$BIN" status
```

`tccutil reset` 就是之前要手动去系统设置点减号那一步的命令行版本，不需要 sudo。

## 为什么安装脚本不自己去申请权限

| 启动方式 | 请求算在谁头上 | 结果 |
| --- | --- | --- |
| 直接执行 `.../Contents/MacOS/screenbeam perm --request` | **调用者的终端** | 终端早就有屏幕录制权限，所以命令**假装成功**（打印「已授权」），但 app 根本没进列表 |
| `open -a PHONE-CATCH-SCREEN.app --args perm --request` | app 自己 | 身份对了，**但** LaunchServices 启动的 app 和 LaunchAgent 是同一个程序，两者抢同一个进程，那个实例退出后 agent 掉线。**别用这个。** |
| `launchctl` 启动的守护进程内部申请 | app 自己 | ✅ 身份正确，且不与 agent 冲突 |

**推论：不要相信「从终端跑这个二进制说已授权」这个信号** —— 它继承终端的权限。可信的是
launchd 启动的守护进程，因为它不继承任何终端权限。

---

## 自签名证书（建议做，能根治上面这条）

给 app 一个固定身份后，TCC 记录不再随重建变化，上表那种「这次行下次不行」就消失了。
`scripts/build.sh` 会自动检测并使用任何可用的签名身份。

创建方式（Keychain Access → 证书助理 → 创建证书，类型选「代码签名」），或让 Claude 用
`openssl` + `security import` 做 —— 后者需要你手动跑一次 `security set-key-partition-list`
（要输入你的登录密码，Claude 不应代持）。

---

## 其他容易踩的

- **`swift test` 在这台机器上用不了**：XCTest 和 swift-testing 都需要完整 Xcode，这里只有
  Command Line Tools。测试用例编译在库里，用 `screenbeam selftest` 跑（当前 101 项）。
- **改代码前先看 `CLEANUP.md`**：里面列了本项目在这台机器上创建了什么、哪些不能删。
- **不要删 `~/Library/Application Support/PHONE-CATCH-SCREEN/devices.json`**：里面是已配对手机的
  凭据哈希。删了对方就得重新配对。
- **不要用 `--config` 跑测试**而不清理：虽然 `devices.json` 现在跟随配置文件所在目录，
  但用真实配置跑测试仍然会写真实状态。
- **`screenbeam` 不在 PATH**：完整路径是 `~/Applications/PHONE-CATCH-SCREEN.app/Contents/MacOS/screenbeam`。
- **调 LLM 的代码不要凭记忆写**：用 `claude-api` skill 核对请求形状（模型 ID、`max_tokens`、
  thinking、refusal 处理都在变）。`Sources/ScreenBeamCore/LLM/LLMClient.swift` 里的形状是核对过的。
- **不要用这台机器上的 `ANTHROPIC_*` 环境变量做测试**：那是 Claude Code 会话自己的凭据和本地代理，
  不是给这个 app 用的。
