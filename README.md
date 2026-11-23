# anti-meeting

**简体中文** | [English](README.en.md)

> A **macOS-only** local meeting recorder, dual-track speaker timeline generator, and structured Markdown meeting notes plugin (MCP App + Skill + Native Swift Recorder) for **Google Antigravity**.

> [!IMPORTANT]
> **仅支持 macOS（macOS Only）**
> 本项目**仅支持 macOS，不支持 Windows 和 Linux**。底层音频采集、进程守护与原子文件操作深度依赖 macOS 系统能力：
> - 系统音频与麦克风双轨采集基于 **macOS Core Audio Process Tap**、**AVFoundation** 与 **Swift 6.2**；
> - 原生文件锁与原子交换模块基于 macOS 系统调用（`renamex_np`、`openat`、`flock`）及 Xcode 工具链（`cc`、`swiftc`、`codesign`）。

---

## 环境要求（Requirements）

- **操作系统**：macOS 26.0 或更高版本（对应 [recorder-macos/Package.swift](recorder-macos/Package.swift) 与 [bundle-app.sh](recorder-macos/scripts/bundle-app.sh) 中的最低系统版本要求）
- **编译工具链**：Xcode Command Line Tools（含 Swift 6.2 与 `cc` / `codesign`）
- **运行时**：Node.js 22+
- **宿主客户端**：Google Antigravity（支持插件、MCP Apps 侧边栏与 Skills）

---

## 核心特性

- **双轨 / 单轨高质量录制**：
  - **双轨模式（`dual`）**：同时采集全局系统音频（远端参会人）与本地麦克风（我方），兼容 Zoom、飞书、腾讯会议、浏览器会议等，并生成混音轨（`mix_*.m4a`）、我方轨（`mic_*.m4a`）、对方轨（`remote_*.m4a`）及说话人时间线（`timelines/chunk_*.json`）。
  - **仅麦克风模式（`mic`）**：适用于线下讨论或个人语音笔记。
- **说话人时间线与统计**：结合分轨能量活动自动标注「我方 / 对方 / 重叠」，并在会议详情页展示发言时长分布。
- **后台独立守护与容错封包**：`MeetingRecorder.app` 在后台独立运行，不打断你在 Antigravity 中切换会话；支持 5 分钟滚动切片、设备热切换检测、音频缺口（`gaps`）记录与合盖休眠前的安全封包。
- **独立会话断点续转**：支持在侧边栏一键开启新独立会话调用 `meeting-notes` 技能；短会议按片顺序转写并实时持久化断点进度，超过 4 个切片的长会议自动分组并发子 Agent 转写、主 Agent 串行汇总。
- **完整 GFM Markdown 纪要展示**：侧边栏内置 XSS 安全的 GitHub 风格 Markdown 渲染器，支持 Alerts 提示框、行动项表格、任务清单、代码块、标题与深浅色主题自适应。
- **原音频留存策略与 100% 本地隐私**：支持「永久保留（手动清理）」「生成纪要后自动清理」「保留 7 天」三种策略；所有录音与转写结果默认保存在本机，不上传任何第三方录音云服务。

---

## 快速安装（Quick Start）

> 请在 **macOS** 终端中执行以下命令完成源码编译与本地插件安装：

```bash
git clone https://github.com/nolinsun/anti-meeting.git
cd anti-meeting
npm install

# 可选（强烈推荐）：创建本地代码签名证书 "Antigravity Meeting Local"
# 可避免每次重新编译后 macOS TCC 重复弹出麦克风/系统录音授权
bash recorder-macos/scripts/setup-local-cert.sh

# 编译 UI、原生 N-API 模块、MCP Server 和 MeetingRecorder.app
# 并原子安装到 ~/.gemini/config/plugins/anti-meeting
npm run install:plugin
```

安装完成后，在 Google Antigravity 右侧边栏 **「+」菜单** 中打开 **anti-meeting**，或直接对 Agent 说：

- `打开 anti-meeting 侧边栏并开始录制语音`
- `整理最近一场会议并生成结构化纪要和待办事项`

---

## macOS 权限配置

首次使用录制功能时，需要在 macOS **系统设置 → 隐私与安全性** 中为 `MeetingRecorder` 开启以下权限：

1. **麦克风**：在「隐私与安全性 → 麦克风」中勾选 `MeetingRecorder`（所有模式均需开启）。
2. **仅系统音频录制**（双轨模式必需）：在「隐私与安全性 → 录屏与系统录音 → 仅系统音频录制（System Audio Recording Only）」中勾选 `MeetingRecorder`。

> [!TIP]
> 你可以在插件侧边栏的「音频权限与设备」区域直接点击 **检测音频权限**、**隐私设置** 或 **重启并重检** 来完成权限自检。若重签或重编后权限未生效，可在系统设置中先关闭开关再重新开启，并点击侧边栏「重启并重检」。

---

## 项目结构

```text
anti-meeting/
├── recorder-macos/            # macOS Swift 音频采集守护进程 (MeetingRecorder.app)
│   ├── Package.swift          # Swift 6.2 / macOS 26.0+ 包配置
│   ├── Sources/MeetingRecorder/
│   └── scripts/               # 本地代码签名证书创建与 .app 打包脚本
├── mcp-server/                # MCP Server 与 macOS 原生安全文件 I/O 模块
│   ├── native/                # safe_openat.c + swift_u64.swift (openat/flock/renamex_np)
│   └── src/                   # MCP 工具、守护进程客户端、断点与留存管理
├── ui/                        # MCP App 侧边栏前端 (单文件打包至 plugin/ui/app.html)
│   ├── src/                   # app.ts、markdown.ts (GFM 渲染器)、styles.css
│   └── scripts/               # build-ui.mjs 与 test-markdown.mjs
├── plugin/                    # Antigravity 插件清单、Skill 与构建产物出口
│   ├── plugin.json            # 插件元信息
│   ├── mcp_config.json        # MCP Server 启动配置
│   ├── assets/logo.svg        # 插件图标
│   └── skills/meeting-notes/  # 会议转写与结构化纪要生成 Skill
├── scripts/
│   └── install-plugin.sh      # 全量构建并原子安装到 ~/.gemini/config/plugins/anti-meeting
└── package.json
```

---

## 开发与校验命令

```bash
# TypeScript 类型检查
npm run typecheck

# 运行 Markdown 渲染器单元测试与样例回归测试
node ui/scripts/test-markdown.mjs

# 仅重建前端单文件 HTML 包 (plugin/ui/app.html)
npm run build:ui

# 全量构建（UI + 原生 Node 模块 + MCP Server + MeetingRecorder.app）
npm run build

# 使用 Antigravity CLI 校验插件结构
agy plugin validate ./plugin
```

---

## 隐私与许可（Privacy & License）

- **本地数据目录**：在 Antigravity 插件环境下，所有录音切片、说话人时间线、逐字稿与会议纪要均保存在本机 `~/.gemini/antigravity/plugin_data/anti-meeting/`（独立运行 MCP Server 且未传 `--data-dir` 时默认保存在 `~/Library/Application Support/AntiMeeting/`）。
- **开源协议**：本项目基于 [MIT License](LICENSE) 开源。
