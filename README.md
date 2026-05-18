# Legado Flutter

> 基于开源阅读应用 [Legado](https://github.com/gedoor/legado) 的 Flutter + Rust 重构版本

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter Version](https://img.shields.io/badge/Flutter-3.0+-blue.svg)](https://flutter.dev)
[![Rust Edition](https://img.shields.io/badge/Rust-2024-orange.svg)](https://www.rust-lang.org)

---

## 📖 项目简介

Legado Flutter 是对原 Android 应用 Legado（开源阅读）的完全重构，采用 **Flutter + Rust** 技术栈实现跨平台支持。

### 为什么重构？

- **跨平台**：原版仅支持 Android，重构后支持 Android、iOS、Windows、macOS、Linux
- **性能提升**：Rust 核心引擎提供更高性能和更好内存安全性
- **可维护性**：清晰的模块划分和现代化的技术栈
- **功能对等**：保持与原版功能对等，同时扩展新特性

### 参考项目

本项目重构过程中大量参考了以下两个 Legado 衍生项目，特别是在书源解析规则、阅读器交互、翻页动画几何、阅读进度存储等关键链路上对照其实现细节：

- **[LegadoTeam/Legado-Tauri](https://github.com/LegadoTeam/Legado-Tauri)** — Legado 的 Tauri (Rust + 前端) 重构版，启发了本项目的 Rust core 模块划分（core-net / core-parser / core-source / core-storage）与 FFI 桥接思路
- **[HapeLee/legado-with-MD3](https://github.com/HapeLee/legado-with-MD3)** — Legado 的 Material Design 3 fork，本项目的仿真翻页（5 段贝塞尔几何 + 4 段阴影）、章节窗口管理（`durChapterIndex` / `durChapterPos` 字符 offset 语义）、邻章预测量、替换规则 scope 子串匹配等实现 1:1 对照其 Kotlin 源码翻译为 Dart

仓库内 `.trellis/tasks/` 目录里多个任务的 PRD / research 都明确记录了对照来源（如 `SimulationPageDelegate.kt L188-L206 setDirection` 镜像逻辑、`ReadBook.kt L626-L635 loadContent` 预拉链路、`Book.kt L93-L107 durChapterPos` 字段语义等）。

### 技术架构

```
┌─────────────────────────────────────────┐
│           Flutter UI Layer               │
│    (书架/阅读器/搜索/书源管理/设置)        │
└──────────────────┬──────────────────────┘
                   │
         flutter_rust_bridge (FFI)
                   │
┌──────────────────▼──────────────────────┐
│          Rust Core Engine                │
│                                          │
│  ┌──────────┐ ┌──────────┐ ┌─────────┐ │
│  │ core-net │ │core-     │ │core-    │ │
│  │ 网络引擎  │ │parser    │ │storage  │ │
│  │          │ │ 格式解析  │ │ SQLite  │ │
│  └──────────┘ └──────────┘ └─────────┘ │
│                │                        │
│         ┌──────▼──────┐                 │
│         │ core-source │                 │
│         │ 书源规则引擎 │                 │
│         └─────────────┘                 │
└──────────────────────────────────────────┘
```

详见 [架构设计文档](docs/ARCHITECTURE.md)

---

## 🚀 快速开始

### 前置要求

- **Flutter**: >=3.0.0 ([安装指南](https://docs.flutter.dev/get-started/install))
- **Rust**: edition 2024 ([安装指南](https://www.rust-lang.org/tools/install))
- **flutter_rust_bridge_codegen**: ^2.0.0
  ```bash
  cargo install flutter_rust_bridge_codegen
  ```
- **Android NDK**: 28.2.13676358（Android 构建需要）

### 构建步骤

#### 1. 克隆项目
```bash
git clone https://github.com/lq-259/legado_flutter.git
cd legado_flutter
```

#### 2. 初始化 Rust 核心
```bash
cd core
cargo build --release
cd ..
```

#### 3. 生成 FFI 绑定（如修改了 Rust API）
```bash
cd core/bridge
flutter_rust_bridge_codegen generate
cd ../..
```

#### 4. 安装 Flutter 依赖
```bash
cd flutter_app
flutter pub get
cd ..
```

#### 5. 一键构建（推荐 / Android）

```bash
# Debug 构建 + 安装到设备
bash build_android_debug.sh

# Release 构建（输出到 dist/，含 SHA256 校验和）
bash build_android_release.sh
```

或手动：

```bash
# Android
cd flutter_app
flutter run

# iOS (需要 macOS)
flutter run -d ios

# 桌面平台
flutter run -d windows  # 或 macos / linux
```

---

## 📂 项目结构

```
legado_flutter/
├── core/                          # Rust 核心引擎 (cargo workspace)
│   ├── core-net/                 # 网络引擎 (HTTP / Cookie / 代理 / SSRF 防护)
│   ├── core-parser/              # 格式解析 (TXT / EPUB / UMD)
│   ├── core-storage/             # 存储引擎 (SQLite + DAOs)
│   ├── core-source/              # 书源规则引擎（JS evaluation / 替换规则 / scope 匹配）
│   └── bridge/                   # FRB FFI 桥接层
├── flutter_app/                   # Flutter 应用
│   ├── lib/
│   │   ├── core/                 # providers / api / router
│   │   ├── features/             # 功能模块（reader / bookshelf / search / source / settings ...）
│   │   └── src/rust/             # FRB 自动生成的 Dart 绑定
│   └── pubspec.yaml
├── docs/                          # 项目文档
├── build_android_debug.sh         # Android Debug 一键构建
├── build_android_release.sh       # Android Release 一键构建
└── README.md
```

---

## 🎯 当前进度

| 模块 | 状态 | 说明 |
|------|------|------|
| Rust core 引擎 | ✅ 可用 | net / parser / storage / source 全部就绪，264 cargo test 全绿 |
| Flutter UI | ✅ 可用 | 书架 / 阅读器 / 搜索 / 书源 / 设置 / TTS / WebDAV |
| 阅读器 | ✅ 可用 | 5 种翻页动画（仿真/覆盖/平移/淡入淡出/无动画）+ 滚动模式 |
| 阅读进度 | ✅ 可用 | 章节 + 章内字符 offset 级恢复（对齐 MD3 `durChapterPos`）|
| 搜索 | ✅ 可用 | 多书源并行 + 精确模式过滤 |
| 替换规则 | ✅ 可用 | 含 scope 子串匹配；regex 防 ReDoS |
| TTS / WebDAV | ✅ 可用 | TTS 朗读 + WebDAV 备份 |
| 书源 JS evaluation | ✅ 可用 | Rust 端实现，远程书源兼容 |
| 跨平台支持 | 🚧 部分 | Android 全功能可用；iOS / Desktop 未充分测试 |

215+ Flutter widget/unit test 全绿；0 issue analyze。

---

## 🤝 贡献指南

欢迎贡献！请参考以下流程：

1. Fork 本项目
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 提交 Pull Request

### 贡献方向

- 🐛 报告 Bug
- 💡 提出新功能建议
- 📝 完善文档
- 💻 提交代码（Rust/Flutter/文档）
- 🧪 编写测试用例

---

## 📄 开源协议

本项目采用 MIT 协议 - 详见 [LICENSE](LICENSE)

原 Legado 项目采用 AGPL-3.0，本重构项目采用 MIT 以便更广泛的使用。

参考项目分别遵循其各自协议：
- [LegadoTeam/Legado-Tauri](https://github.com/LegadoTeam/Legado-Tauri)：见上游 LICENSE
- [HapeLee/legado-with-MD3](https://github.com/HapeLee/legado-with-MD3)：GPL-3.0（继承 Legado 上游）

---

## 🙏 致谢

- **[Legado (gedoor/legado)](https://github.com/gedoor/legado)** — 原项目作者 gedoor 及贡献者，提供了完整的阅读器架构与书源生态
- **[LegadoTeam/Legado-Tauri](https://github.com/LegadoTeam/Legado-Tauri)** — Tauri 重构启发了 Rust core 模块划分思路
- **[HapeLee/legado-with-MD3](https://github.com/HapeLee/legado-with-MD3)** — MD3 fork，本项目的翻页动画几何 / 进度存储语义 / 邻章管理 1:1 对照其 Kotlin 实现
- [Flutter](https://flutter.dev) — UI 框架
- [Rust](https://www.rust-lang.org) — 核心引擎语言
- [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) — FFI 桥接方案

---

## 📧 联系方式

- 项目 Issues: [GitHub Issues](https://github.com/lq-259/legado_flutter/issues)
- Releases: [GitHub Releases](https://github.com/lq-259/legado_flutter/releases)

---

**注意**: 本项目与原 Legado 无官方关联，是由社区驱动的重构项目。
