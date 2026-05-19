# 全量审查修复路线图（roadmap.md）

> **基础**：上一个任务 `archive/2026-05/05-19-full-codebase-review` 产出 320 条 finding（10 P0 + 122 P1 + 127 P2 + 61 P3）。本路线图覆盖全部 **132 条 P0+P1**，按风险分级组织成 23 个批次。
>
> **不创建子任务**：本路线图只是文档；用户照着挑批次按 [§5 启动一个批次](#5-如何启动一个批次) 的命令模板触发。
>
> **路径变化**：上一任务已 archive，所有 finding 文件引用 `.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/`。

## 1. 批次总览表

| NN | Slug | Stage | 范围简介 | findings 数 | Effort | Depends on |
|---|---|---|---|---|---|---|
| 01 | cleanup-stale-jnilibs | P0 | 删 3 ABI stale .so + 修 release 脚本顺序 | 3 | S | none |
| 02 | harden-android-build-and-manifest | P0 | allowBackup + release keystore + R8 | 4 | M | BATCH-01 |
| 03 | secure-credentials-via-keystore | P0 | Android Keystore + WebDAV / 备份密码 + token 日志 | 5 | M | BATCH-02 |
| 04 | harden-js-sandbox-core | P0 | SSRF / 内存 / 文件桥 / queryTtf / chunked / JS bridge | 6 | L | none |
| 05 | tighten-webview-and-qr-boundaries | P0 | WebView policy / QR / RSS WebView 三处加固 | 6 | M | none |
| 06 | cargo-workspace-deps-cleanup | P1 | `[workspace.dependencies]` + zeroize/secrecy + 反向依赖 + lock | 4 | M | none |
| 07 | sqlite-transactions-raii | **P0+P1** | Tx RAII + 跨 dao 一致性 + FRB explore async（含唯一一条孤立 P0 F-W1A-002） | 9 | L | BATCH-06 |
| 08 | dao-sql-dedup-and-cleanup | P1 | SQL 列常量 + dao 死代码 + upsert 风格统一 | 9 | M | BATCH-07 |
| 09 | backup-aes-and-replace-rules-perf | **P0+P1** | 备份 AES 弱算法 / GCM 路径 / zip-bomb / replace_rules Mutex（含 1 条 P0） | 4 | M | BATCH-06 |
| 10 | js-sandbox-extra-security | P1 | zip-slip / shared vars / template eval / DoS / HTTPS / JS 注入 | 6 | M | BATCH-04 |
| 11 | js-runtime-correctness-fixes | P1 | java.put 跨阶段 / JSON.stringify / 键序 / _resolveUrl / time_format | 5 | M | BATCH-04 |
| 12 | parser-correctness-and-regex-cache | P1 | apply_format_js / image regex / Empty / 多页 toc / queue / unwrap | 6 | M | none |
| 13 | quickjs-runtime-pool | P1 | Runtime per-thread 复用（5 处 new Runtime） | 5 | M | BATCH-11 |
| 14 | parser-rule-perf-misc | P1 | search per-item / css 重复 parse / RATE_LIMITER / font_mappings | 4 | M | BATCH-13 |
| 15 | unify-rule-engine | P1 | 双规则系统去一 + 重复 dispatcher + helper 散落 | 6 | M | BATCH-14 |
| 16 | legado-url-and-import-cleanup | P1 | clean_legado_url / 模板 / spawn_blocking / RSS BOM / JSONPath | 5 | M | BATCH-15 |
| 17 | core-net-cookie-webdav | P1 | cookie dedup / save flush / WebDavClient build | 3 | S | none |
| 18 | flutter-dead-code-and-io-abstract | P1 | core/api 死代码 + transport 占位 + settings IO + fontSize 单源 + bookshelf 菜单 + path util | 6 | M | none |
| 19 | reader-state-machine-controller | P1 | ReaderController 拆 + rebuild 链解耦 + 进度恢复对称 | 8 | L | BATCH-18 |
| 20 | settings-testability-cleanup | P1 | API client 注入 + global mutable 清扫 + PlatformInt64 抽象 | 7 | M | BATCH-18 |
| 21 | rss-search-reactivity-perf | P1 | RSS detail / list reactivity / SSE throttle / future cancel | 7 | M | BATCH-20 |
| 22 | bookshelf-and-listmanage-cleanup | P1 | bookshelf KeepAlive / TabBarView / list scaffold 复用 | 5 | M | BATCH-18 |
| 23 | cross-layer-ffi-error-log | P1 | FFI 强类型样板 + BridgeError + Log + apply_replace_rules cache + pinning | 9 | L | BATCH-06, BATCH-19 |

**合计**：23 批，132 findings（10 P0 + 122 P1）

## 2. 执行顺序图

```text
P0 阶段（5 批，可并行）
  BATCH-01 ──▶ BATCH-02 ──▶ BATCH-03            (Android 构建链路 + 凭据)
  BATCH-04                                       (JS 沙箱基础硬化, 独立)
  BATCH-05                                       (WebView/QR/RSS 边界, 独立)

P1 阶段（18 批，部分依赖 P0）
  BATCH-06 ──▶ BATCH-07 ──▶ BATCH-08            (Cargo workspace + Rust 数据层)
       └────▶ BATCH-09                          (备份加密 [含 1 P0 F-W1A-001])
       └─────────────────────────────────▶ BATCH-23

  BATCH-04 (P0) ──▶ BATCH-10                    (JS 沙箱补充安全)
                ──▶ BATCH-11 ──▶ BATCH-13 ──▶ BATCH-14 ──▶ BATCH-15 ──▶ BATCH-16
                                  (Runtime pool)  (perf misc)  (rule unify)  (url/import)

  BATCH-12                                       (parser correctness, 独立)
  BATCH-17                                       (core-net cookie/webdav, 独立)
  BATCH-18 ──▶ BATCH-19 ──▶ BATCH-23             (Flutter dead code → reader controller → FFI)
       ├────▶ BATCH-20 ──▶ BATCH-21              (settings → rss/search reactivity)
       └────▶ BATCH-22                           (bookshelf/list scaffold)
```

完整跨批次依赖图见 [`dependencies.md`](./dependencies.md)。

## 3. 主题反查表（master 10 主题 → 涉及 BATCH 编号）

便于"想集中清主题 X"时倒查：

| # | 主题 | 涉及 BATCH | 备注 |
|---|---|---|---|
| 1 | JS 沙箱跑 untrusted 远程书源代码 | 04, 10, 11, 13 | P0 基础硬化在 04；补充安全 / 正确性 / Runtime pool 分散在 10/11/13 |
| 2 | 凭据 / 密钥 / 备份密码 明文存储 | 02, 03, 09 | Android backup 关；Keystore；AES 强化 |
| 3 | SQLite 事务 / 并发 / 错误处理一致性 | 07 | 单批集中（含 RAII / WAL / silently rewrite / FRB explore async） |
| 4 | 重复 SQL / 重复实现 / 死代码 | 08, 15, 18 | Rust dao 在 08；rule_engine 在 15；Flutter 死代码 18 |
| 5 | WebView / JS 边界缺安全 gating | 04, 05 | JS bridge capability gate 在 04；WebView/QR/RSS policy 在 05 |
| 6 | Reader 状态机 / 渲染性能问题 | 19 | 单批集中 |
| 7 | FFI 契约：JSON-string + 无类型校验 | 23 | 5-10 条热路径迁移样板 |
| 8 | 错误信息 / 日志 跨层不一致 | 23 | BridgeError + Dart Log 类 |
| 9 | Cargo workspace 依赖治理 | 06 | 单批集中 |
| 10 | Reader / Bookshelf / Settings 测试钩子污染生产 API | 20 | 单批集中（API client 注入 + global mutable 清扫） |

## 4. 风险与里程碑

### 里程碑 M1: P0 阶段完成（BATCH-01..05 + BATCH-07 + BATCH-09 中的 F-W1A-001 + F-W1A-002）

- ✅ 仓库无 stale 二进制、release 流程严格、release 用独立 keystore + R8 + allowBackup=false
- ✅ 凭据保险柜上线，WebDAV / 备份密码不再明文写盘
- ✅ JS 沙箱基础三道闸：SSRF / 内存上限 / 文件桥 capability
- ✅ WebView / QR / RSS 三处远端 untrusted 内容入口收紧
- ✅ FRB explore 不再 block_on
- ✅ 备份加密弱算法主题已上"强加密备份"路径
- ⚠️ 后续 P1 阶段进入"质量改造"阶段，不再有"安全血流不止"的紧迫性

### 里程碑 M2: P1 阶段完成（BATCH-06, 08, 10..23 余下批次）

- ✅ 132 P0+P1 全部清零；后续仅留 P2/P3 归档
- ✅ Rust 端事务 / dao / runtime / parser / rule / cookie 健康
- ✅ Flutter 端死代码 / 状态机 / 反应式性能 / API client 抽象齐备
- ✅ 跨层 FFI 契约 / 错误码 / 日志 spec 落地

### 中间暂停点

- **完成 BATCH-01..05**（P0 阶段大头）后**可以暂停**，专注业务功能；此时安全血流已止，技术债仅剩"维护负担"层面
- **完成 BATCH-06..09**（Rust 数据层）后又一个暂停点；Rust 后端进入稳态
- **完成 BATCH-18..23**（Flutter 全模块）后是 P1 收尾

## 5. 如何启动一个批次

```bash
# 1. 创建子任务（用批次 slug + master review 任务作为 parent）
python3 ./.trellis/scripts/task.py create "<批次标题>" \
  --slug <slug> \
  --parent .trellis/tasks/archive/2026-05/05-19-full-codebase-review

# 2. 把 plan/batches/BATCH-NN-<slug>.md 的 § 7 (implement.jsonl 草稿) 与 § 8 (check.jsonl 草稿) 内容
#    分别复制到新建任务目录下的 implement.jsonl / check.jsonl 中

# 3. 启动 implement
python3 ./.trellis/scripts/task.py start .trellis/tasks/<新建任务路径>
```

**实务建议**：

- 启动前先 grep 一遍当前代码，**re-verify** finding 是否仍然存在（路线图可能"过期"——某条 P1 在执行另一批时被顺手解决）
- 若发现 finding 已被消解，在子任务的 prd.md 中显式标注"finding F-WXX-NNN: already resolved by batch BATCH-YY"
- 子任务的 prd.md 必须挂回 `BATCH-NN-<slug>.md` 的 § 1-6 作为基底，§ 7-8 仅供 implement.jsonl 用

## 6. 部分启动收益（"只做前 N 批会得到什么"）

### 只做前 5 批（BATCH-01..05，全部 P0 阶段无依赖）

- 修复 5 + 4 + 5 + 6 + 6 = **26 finding**（含 9 P0 + 17 P1 强耦合）
- ✅ release 流程合规：无 stale .so / R8 启用 / 独立 keystore / allowBackup=false
- ✅ 凭据全部走 Keystore，token 日志 sanitize
- ✅ JS 沙箱基础三道闸 + WebView/QR/RSS 三处远端入口加固
- ⚠️ 仍欠：FRB explore async（BATCH-07）、备份 AES 弱算法（BATCH-09 中 F-W1A-001）—— 这两条是 P0 但与 P1 强耦合合批，需要在 BATCH-06 (cargo deps) 之后做

### 只做前 9 批（BATCH-01..09）

- 修复 26 + 4 + 9 + 9 + 4 = **52 finding**（10 P0 全部 + 42 P1）
- ✅ P0 全部清零（10/10）
- ✅ Rust 数据层（事务 / dao / 列常量 / 死代码）健康
- ✅ Cargo workspace 依赖治理 + zeroize/secrecy 基础设施
- ⚠️ JS 沙箱补充安全 / Runtime pool / parser perf 仍未做；reader 状态机仍未拆

### 只做前 16 批（BATCH-01..16，Rust 端基本完工）

- 修复 52 + 6 + 5 + 6 + 5 + 4 + 6 + 5 = **89 finding**（10 P0 + 79 P1）
- ✅ Rust 端 P1 全部清零（包括 JS 沙箱、parser、rule、url/import）
- ✅ core-net cookie / WebDAV 也基本清完
- ⚠️ Flutter 端 P1 仍未动（死代码 / reader / settings / rss / bookshelf）；FFI 契约样板未做

### 全部完成（BATCH-01..23）

- ✅ 132 P0+P1 全部清零
- ✅ Rust + Flutter + 跨层 全维度治理完成
- 余下 P2/P3 留给独立 cleanup 任务

## 7. 覆盖度审计

| 项 | 数值 |
|---|---|
| Master P0+P1 finding 总数 | 132 |
| 各批次 finding 合计（取并集） | **132** |
| 重复出现 | **0** |
| 未覆盖 | **0** |
| 批次数 | **23** （在 18-24 区间内） |
| 每批 finding 数 | 3-9 （全部满足 ≥2 ≤10） |

通过命令复核：

```bash
# 提取所有批次的 finding id（取自每份 BATCH-NN.md 的 § 2 段）
for f in .trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-*.md; do
  awk '/^## 2\. 包含的 findings/,/^## 3\./' "$f" | grep -oE "\[F-W[0-9]+[A-Z]?-[0-9]+\]"
done | sort -u > /tmp/batch_findings.txt
wc -l /tmp/batch_findings.txt   # 应该是 132

# Master P0+P1 索引
awk '/^## 单条索引/,/^## 推荐第一批修复/' \
  .trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md \
  | grep -oE "\[F-W[0-9]+[A-Z]?-[0-9]+\]" | sort -u > /tmp/master_findings.txt
wc -l /tmp/master_findings.txt  # 应该是 132

diff /tmp/batch_findings.txt /tmp/master_findings.txt   # 应该没有差异
```

## 8. 路线图复盘（对上一份报告的反馈）

- 建议方向不够具体的条目（多为"评估能否"或"短期 / 长期"两段并列）：
  - F-W3-005 FFI 全表迁移：master 给方向 "挑 5-10 条热路径"，本路线图按此约束
  - F-W3-012 core-source 反向依赖：master 给方向 "评估能否抽 trait"，本路线图允许 BATCH-06 内显式延后
  - F-W1A-001 / F-W1A-003：短期 fail-fast / 长期 GCM 双轨——本路线图把"路线图本身"当作长期路径登记入 BATCH-09，不在 P0 一刀切
- 这些条目在子任务执行时由 sub-agent 重新读上下文做最终决策，路线图只给方向。
