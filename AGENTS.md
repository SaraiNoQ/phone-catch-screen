# AGENTS.md — 在本仓库工作前必读

## 每次重新构建后，必须走完这三步

这个 app 是 **ad-hoc 签名**（没有 Apple 开发者证书），`codesign -dv` 会显示 `TeamIdentifier=not set`。
这意味着 **TCC 只能靠二进制的 CDHash 认出「你是谁」**。每次 `scripts/build.sh` 重新编译，CDHash 就变了，
系统设置里那条屏幕录制授权指向的二进制**已经不存在了**。

**症状：开关是开着的，但截图报「缺少屏幕录制权限」。** 这是最容易误判的一类故障 ——
不会报错、不会提示记录失效，你会以为是代码坏了。

三步走：

```bash
# 1. 手动：系统设置 → 隐私与安全性 → 屏幕录制
#    选中 PHONE-CATCH-SCREEN，点列表下方的 − 删掉这条记录
#    （脚本做不了，macOS 不允许程序改这个列表）

# 2. 重启服务 —— 它会在系统设置里重新登记自己并弹出授权对话框，点「允许」
~/Applications/PHONE-CATCH-SCREEN.app/Contents/MacOS/screenbeam restart

# 3. 再重启一次，让新授权对这个新进程生效
#    （第 2 步那个进程在启动时就把「未授权」缓存下来了，它自己感知不到变化）
~/Applications/PHONE-CATCH-SCREEN.app/Contents/MacOS/screenbeam restart
```

验证：

```bash
~/Applications/PHONE-CATCH-SCREEN.app/Contents/MacOS/screenbeam status
```

「屏幕录制」显示 **已授权** 才算通过。若仍是「未授权」，回到第 1 步确认记录删干净了。

> 也可以省掉第 2 步的对话框：删掉记录后直接 restart，然后**手动**在系统设置里把
> PHONE-CATCH-SCREEN 勾上（这时列表里已经有它了），再执行第 3 步。

完整流程：

```bash
./scripts/install.sh      # 构建 + 安装 + 注册服务
# 然后手动做上面第 1 步，再 restart 两次
```

---

## 为什么第 2 步用 `restart`，而不是 `open -a` 或直接跑二进制

TCC 把授权记在**责任进程**（responsible process）头上，三种启动方式结果完全不同：

| 启动方式 | 请求算在谁头上 | 结果 |
| --- | --- | --- |
| 直接执行 `.../Contents/MacOS/screenbeam perm --request` | **调用者的终端** | 终端早就有屏幕录制权限了，所以命令**假装成功**（打印「已授权」），但 app 根本没进列表、也没弹对话框 |
| `open -a PHONE-CATCH-SCREEN.app --args perm --request` | app 自己 | 身份对了，**但** LaunchServices 启动的这个 app 和 LaunchAgent 是同一个程序 —— 两者抢同一个进程，那个实例退出后 agent 就掉线了。**别用这个。** |
| `launchctl` 启动的守护进程内部申请 | app 自己 | ✅ 身份正确，且不与 agent 冲突。所以走 `restart` |

**推论：不要相信「从终端跑这个二进制说已授权」这个信号。** 它会继承终端的权限。
唯一可信的判断是 **launchd 启动的守护进程**（`screenbeam status`），因为它不继承任何终端权限。

---

## 根治办法（强烈建议，能省掉上面全部三步）

建一张**自签名代码签名证书**放进登录钥匙串，给 app 一个稳定身份。CDHash 不再随重建变化，
授权一次长期有效。`scripts/build.sh` 会自动检测并使用任何可用的签名身份。

代价：会在登录钥匙串里多一张证书（随时可删）。仅当你要连续改这个项目时才值得建。

---

## 其他容易踩的

- **`swift test` 在这台机器上用不了**：XCTest 和 swift-testing 都需要完整 Xcode，这里只有
  Command Line Tools。测试用例编译在库里，用 `screenbeam selftest` 跑。
- **改代码前先看 `CLEANUP.md`**：里面列了本项目在这台机器上创建了什么、哪些不能删。
- **不要删 `~/Library/Application Support/PHONE-CATCH-SCREEN/devices.json`**：里面是已配对手机的
  凭据哈希。删了对方就得重新配对。
- **`screenbeam` 不在 PATH**：完整路径是 `~/Applications/PHONE-CATCH-SCREEN.app/Contents/MacOS/screenbeam`。
- **调 LLM 的代码不要凭记忆写**：用 `claude-api` skill 核对请求形状（模型 ID、`max_tokens`、
  thinking、refusal 处理都在变）。`Sources/ScreenBeamCore/LLM/LLMClient.swift` 里的形状是核对过的，
  改动前先读那里的注释。
- **不要用这台机器上的 `ANTHROPIC_*` 环境变量做测试**：那是 Claude Code 会话自己的凭据和本地代理，
  不是给这个 app 用的。要验证真实调用，让用户自己填 API Key。
