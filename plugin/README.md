# anti-meeting

> [!IMPORTANT]
> **仅支持 macOS（macOS Only）**
> 本插件依赖 macOS 原生音频接口（Core Audio Process Tap / AVFoundation）与 Swift 守护进程 `MeetingRecorder.app`，**不支持 Windows 或 Linux**。
> 请从源码仓库执行 `npm run install:plugin` 在本机完成编译与安装（勿直接跨机器复制未签名二进制）。

## 功能简介

**anti-meeting** 是面向 Google Antigravity 的本地会议录制与纪要生成插件：

- 支持 **双轨录制**（全局系统音频 + 麦克风，兼容 Zoom / 飞书 / 腾讯会议 / 浏览器等）与 **仅麦克风** 两种模式；
- 在后台独立运行，不打断 Antigravity 会话切换；
- 内置 `meeting-notes` 技能，支持按切片断点转写、结合 `timelines/*.json` 区分「我方 / 对方」、并在侧边栏以完整 GitHub 风格 Markdown 展示逐字稿与会议纪要。

## 使用前准备（macOS）

1. 环境要求：macOS 26.0+、Node.js 22+、Xcode Command Line Tools（含 Swift 6.2）。
2. 在「系统设置 → 隐私与安全性」中为 `MeetingRecorder` 开启：
   - **麦克风**权限；
   - **录屏与系统录音 → 仅系统音频录制**权限（使用双轨录制时必需）。

## 常用提示词

- `打开 anti-meeting 侧边栏并开始录制语音`
- `整理最近一场会议并生成结构化纪要和待办事项`
- `搜索历史会议中关于预算或接口方案的讨论`
