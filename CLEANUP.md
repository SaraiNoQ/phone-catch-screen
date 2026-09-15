# 开发产物清单 / Cleanup inventory

这份文件记录 **本项目在这台机器上创建了什么**，以便开发结束后清理。
写下来的目的是把「本项目产生的」和「本来就在的」分开 —— 删错东西的代价远高于留一点垃圾。

`scripts/dev-clean.sh` 实现了下面的清理，默认只做演练（dry-run），加 `--yes` 才真的删。

---

## A. 本项目创建，可以删

| 路径 | 大小 | 说明 |
| --- | --- | --- |
| `<repo>/.build/` | ~499 MB | SwiftPM 构建缓存。删掉后下次 `swift build` 会重新编译（约 1–2 分钟）。已被 `.gitignore` 排除，不会进仓库 |
| `<repo>/dist/` | ~2.5 MB | `scripts/build.sh` 组装出的 `PHONE-CATCH-SCREEN.app`。随时可重新生成 |
| `~/Library/Application Support/PHONE-CATCH-SCREEN/` | 小 | 运行时配置 `config.json` 与配对凭据 `devices.json`。**这里存着访问令牌**，如果不再使用建议删掉 |
| `~/Library/Logs/PHONE-CATCH-SCREEN/` | 小 | 后台服务的 `out.log` / `err.log` |
| `~/Applications/PHONE-CATCH-SCREEN.app` | ~1 MB | **仅当执行过 `screenbeam install`**。用 `./scripts/uninstall.sh` 删除，不要手删 |
| `~/Library/LaunchAgents/com.sarainoq.screenbeam.plist` | 小 | **仅当执行过 `install`**。同上，由 `uninstall.sh` 处理 |

## B. 共享状态，**不要删**

| 路径 | 说明 |
| --- | --- |
| `~/Library/Caches/org.swift.swiftpm/` | SwiftPM 的全局缓存，所有 Swift 项目共用。只有 52 KB，删它没有收益，却可能影响别的项目 |
| `~/Library/org.swift.swiftpm/` | 同上（SwiftPM 的全局配置目录） |
| `~/.swiftpm/` | 同上 |
| `/Library/Developer/CommandLineTools/` | 系统工具链。**绝对不要动** |

这三处都不是本项目创建的，本项目也从未向其中写入过项目特定的内容。

## C. 无法用脚本清理的

- **系统设置 → 隐私与安全性 → 屏幕录制 里的应用条目。** 卸载和删除文件都不会自动移除这条记录，macOS 不允许程序这么做。执行完清理后需要手动在这里点减号删除。
  如果先删了文件再去看，条目可能仍在但显示为失效 —— 手动移除即可。

## D. 一个结构上的说明

本仓库位于 `~/Documents/dialog/` 内部，而 `dialog` 本身也是一个 git 仓库（无提交）。
`ai4bagu/` 有自己的 `.git`，是**独立仓库**，与 `dialog` 无关 —— 所有的 `git` 操作都在 `ai4bagu/` 内部进行。

清理本项目时**不要删除或修改 `~/Documents/dialog/` 下的任何其他内容**。`dev-clean.sh` 只按绝对路径操作上表 A 中的条目，不会递归到父目录。

---

## 一次性清理

```bash
./scripts/dev-clean.sh            # 演练：只列出将要删除的内容
./scripts/dev-clean.sh --yes      # 真的删
```

脚本会先调用 `screenbeam uninstall`（如果已安装）停掉后台服务，再删除 A 中的路径。
它不会碰 B 中的任何内容，也不会碰仓库以外的文件。
