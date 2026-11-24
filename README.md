# Meeting Notes (`anti-meeting`)

**简体中文** | [English](README.en.md)

> 面向 **Google Antigravity** 的本地会议录制、双轨说话人时间线与结构化 Markdown 会议纪要插件（MCP App + Skill + Native Swift Recorder）。

> [!IMPORTANT]
> **音频录制仅支持 macOS 14.2+（macOS Only）**
> 本项目底层音频采集深度依赖 **macOS Core Audio Process Tap**、**AVFoundation** 与 **Swift**（`MeetingRecorder.app`）。在 Windows 或 Linux 上可安全启动 MCP Server 并浏览/搜索已有历史纪要与逐字稿，界面会提示「仅支持 macOS」，不会崩溃；**本地实时录音与原音采集需要 macOS 14.2+ 与 Xcode Command Line Tools**。

---

## 环境要求（Requirements）

- **操作系统（录音功能）**：macOS 14.2（Sonoma）或更高版本
- **编译工具链**：Xcode Command Line Tools（`xcode-select --install`，含 Swift 与 `cc` / `codesign`）
- **运行时**：Node.js 22+
- **宿主客户端**：Google Antigravity（支持插件、MCP Apps 侧边栏与 Skills）

---

## 核心特性

- **零预编译未签名二进制（Marketplace Ready / 方案 B）**：
  - 插件分发包（`npm run build:plugin`）仅包含前端单页 HTML（`plugin/ui/app.html`）、可执行 MCP Server（`plugin/scripts/meeting-mcp-server.mjs`）、Skill 与可读 Swift/C 源码（`plugin/sources/`），**不随包分发未签名 `.app` 或 `.node` 二进制**。
  - 首次在 macOS 侧边栏使用时，点击 **Initialize Local Recorder（初始化本机录音组件）**，插件会在 `${PLUGIN_DATA}/bin/` 中本机编译并签名 `MeetingRecorder.app`（及可选原生安全文件模块 `safe_openat.node`），彻底避免跨机 Gatekeeper 拦截与签名失效。
  - 内置纯 Node.js 安全降级实现，即使未编译 `safe_openat.node` 或运行在非 macOS 环境也能安全启动与防符号链接读写。
- **双语切换与快捷管理**：
  - 顶栏提供 **EN / 中** 切换按钮（默认英文 `en`），偏好持久化保存在服务端 `settings.json`。
  - 录制页「最近录制（Recent Recordings）」列表中，每条记录的 **View Details（查看详情）** 后紧邻 **Delete（删除）** 按钮，需二次点击 **Confirm Delete（确认删除）** 后执行，防止误删。
- **双轨 / 单轨高质量录制与说话人时间线**：
  - **双轨模式（`dual`）**：同步采集全局系统音频（对方）与本地麦克风（我方），兼容 Zoom、Google Meet、Teams、飞书、腾讯会议及浏览器会议；生成混音（`mix_*.m4a`）、分轨（`mic_*.m4a`、`remote_*.m4a`）和说话人时间线（`timelines/chunk_*.json`）。
  - **仅麦克风模式（`mic`）**：适用于线下沟通或个人语音速记。
- **后台独立守护与断点续转**：
  - `MeetingRecorder.app` 独立常驻运行，支持 5 分钟滚动切片、音频设备切换自动重连与缺口（`gaps`）记录、合盖休眠安全封包。
  - 一键在新独立会话触发 `meeting-notes` 技能按片转写，超过 4 片自动启用只读子 Agent 分组并发转写并在主 Agent 串行校验汇总。
- **完整 GFM Markdown 渲染与原音频留存策略**：
  - 内置 XSS 安全的 GitHub 风格 Markdown 渲染器，支持 Alerts、行动项表格、任务清单、代码块与深浅色自适应。
  - 支持「永久保留（手动清理）」「生成纪要后自动清理」「保留 7 天」三种策略；所有数据默认保存在本机，不上传任何第三方录音云。

---

## 快速安装（Quick Start）

> 在 **macOS 14.2+** 终端中执行以下命令安装插件（插件目录默认为 `~/.gemini/config/plugins/meeting-notes`，Manifest `name` 为 `meeting-notes`，显示名 `Meeting Notes`）：

```bash
git clone https://github.com/nolinsun/anti-meeting.git
cd anti-meeting
npm install

# 可选（推荐）：创建本机代码签名证书 "Local Meeting Recorder"
# 可帮助 macOS TCC 在重建或升级后尽量保留麦克风/系统录音权限
bash recorder-macos/scripts/setup-local-cert.sh

# 方式 A：标准开发安装（本机全量编译 UI、MCP Server、原生扩展与 MeetingRecorder.app，并原子安装）
npm run install:plugin

# 方式 B：纯粹按 Marketplace / 方案 B 打包安装（不预置 plugin/bin 二进制，由侧边栏首次点击本机编译）
bash scripts/install-plugin.sh --option-b
```

安装完成后，在 Google Antigravity 右侧边栏 **「+」菜单** 或全局面板打开 **Meeting Notes**，或直接对 Agent 说：

- `Open the Meeting Notes side pane and start recording a meeting`
- `整理最近一场会议并生成结构化纪要和待办事项`

---

## macOS 权限配置

首次录制前，请在 macOS **系统设置 → 隐私与安全性** 中为 `MeetingRecorder` 开启：

1. **麦克风**（双轨与仅麦克风模式均必需）。
2. **录屏与系统录音 → 仅系统音频录制（System Audio Recording Only）**（双轨模式必需）。

> [!TIP]
> 侧边栏「Audio Permissions & Devices / 音频权限与设备」面板提供权限检测、隐私设置直达与「重启并重检」按钮。由于无开发者签名切换为 `io.github.nolinsun.meeting-recorder` 或首次本机编译时，如之前曾为旧包授权过，建议按提示重新开启开关并点击「Restart & Recheck」。

---

## 项目结构

```text
anti-meeting/
├── recorder-macos/            # macOS Swift 音频采集守护进程源码 (macOS 14.2+)
│   ├── Package.swift          # Swift Package 清单 (.macOS("14.2"))
│   ├── Sources/MeetingRecorder/
│   └── scripts/               # "Local Meeting Recorder" 本地签名证书与 .app 打包脚本
├── mcp-server/                # MCP Server 与原生安全文件 I/O 模块（含纯 Node 降级）
│   ├── native/                # safe_openat.c + swift_u64.swift
│   ├── scripts/               # test-native-fallback.mjs 单元测试
│   └── src/                   # config / native / runtimeSetup / daemon / store / index
├── ui/                        # MCP App 前端（单文件打包至 plugin/ui/app.html）
│   ├── src/                   # app.ts、i18n.ts (EN/中)、markdown.ts、styles.css
│   └── scripts/               # build-ui.mjs 与 test-markdown.mjs
├── plugin/                    # Antigravity 插件 Manifest、Skill、可执行脚本与随附源码
│   ├── plugin.json            # name: "meeting-notes", displayName: "Meeting Notes", v0.4.0
│   ├── mcp_config.json        # 启动 ${PLUGIN_ROOT}/scripts/meeting-mcp-server.mjs
│   ├── README.md              # Marketplace 英文说明文档
│   ├── assets/logo.svg        # 插件图标
│   ├── skills/meeting-notes/  # 会议转写与结构化纪要生成 Skill
│   ├── scripts/               # (构建产物) meeting-mcp-server.mjs
│   ├── sources/               # (构建产物) 随包同步的 recorder-macos/ 与 native/ 源码
│   └── ui/app.html            # (构建产物) 单文件 UI HTML
├── scripts/
│   ├── sync-plugin-sources.mjs# 同步可编译源码至 plugin/sources/
│   └── install-plugin.sh      # 原子安装至 ~/.gemini/config/plugins/meeting-notes（支持 --dest / --option-b）
└── package.json
```

---

## 开发与校验命令

```bash
# TypeScript 类型检查
npm run typecheck

# 运行 Markdown 渲染器与纯 Node 安全降级测试
npm test

# 仅生成无二进制的 Marketplace/方案 B 插件包 (UI + scripts/ + sources/)
npm run build:plugin

# 全量构建（包含本机 safe_openat.node 与 MeetingRecorder.app）
npm run build

# 使用 Antigravity CLI 严格校验插件结构
agy plugin validate ./plugin --strict
```

---

## 隐私与许可（Privacy & License）

- **本地数据目录**：在 Antigravity 插件环境下，所有录音、时间线、逐字稿与会议纪要保存在 `${PLUGIN_DATA}`（如新安装 `~/.gemini/antigravity/plugin_data/meeting-notes/`；通过 `--dest ~/.gemini/config/plugins/anti-meeting` 原地升级的旧版保留在 `~/.gemini/antigravity/plugin_data/anti-meeting/`；独立启动默认 `~/Library/Application Support/MeetingNotes/`）。
- **开源协议**：本项目基于 [MIT License](LICENSE) 开源。
