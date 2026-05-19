# 全量审查修复路线图

## Goal

基于上一个任务（archive/2026-05/05-19-full-codebase-review）产出的 **320 条 finding（10 P0 + 122 P1 + 127 P2 + 61 P3）**，制定一份覆盖全部 **P0 + P1 共 132 条**的可执行修复路线图：

- 按"风险分级（P0 先 → P1 后）"组织批次，每批 1 个独立子任务
- 每个子任务包含：明确范围、所含 finding id、影响文件、依赖前置、预估工作量、提前 curate 好的 `implement.jsonl` / `check.jsonl`
- 路线图本身**只产出文档**，不创建子任务（避免一次性建 N 个空任务污染 active list）；用户照路线图按需 `task.py create --parent` 启动具体批次

P2 / P3 不在本路线图范围（留给后续"零碎清理"独立任务）。

## Why

- 132 条 P0/P1 一次性修不完，且不同条目的修复成本差异极大（5 行 vs 2000 行）；没有路线图，挑哪条先改、哪些一起改全靠每次决策，容易陷入"一会改 Rust 一会改 Dart 一会改 Android"的碎片节奏
- master report 已经做了"主题汇总（10 个）"和"推荐第一批修复（8 条）"，但缺一份**完整覆盖**的批次划分——只看推荐的 8 条解决不了剩下 124 条的优先级
- 提前 curate 好每批的 jsonl，将来开子任务可以直接 `task.py start` 进 implement，不用再 brainstorm

## Scope

### 范围（in scope）

```
.trellis/tasks/05-20-fix-roadmap/
  ├── prd.md          (本文档：路线图 PRD + 决策)
  └── plan/
      ├── roadmap.md          (主路线图：按 P0/P1 分级、批次列表)
      ├── batches/
      │   ├── BATCH-01-<slug>.md   (每个批次一份独立文档：scope / findings / files / jsonl 草稿 / 验收)
      │   ├── BATCH-02-<slug>.md
      │   └── ...
      └── dependencies.md     (跨批次依赖图：哪些必须先做、哪些可并行)
```

### 不在范围（out of scope）

- **创建实际子任务** — 本任务只产出文档，`task.py create --parent` 留给用户按需触发
- **修复任何代码** — 0 业务代码改动
- **P2 / P3 的修复规划** — 留给独立的 "cleanup-batch-N" 任务
- **测试套件设计** — 各修复子任务自带测试约束，本路线图不提前规划测试策略
- **调整 review 报告** — 上一个任务已归档，路线图只引用不修改其 findings

## 路线图组织策略

### Decision: 按风险分级（P0 先 → P1 后）

**与"按主题分批"相比**：
- ✅ 简单可执行：一眼看出"这批做什么级别"
- ✅ P0 一次性清零，安全方面不留尾巴
- ⚠️ 同主题的 P0 + P1 可能被拆到不同批次（例如"凭据存储主题"的 F-W2B-001 是 P0、F-W1A-020 是 P1，路线图允许同批合并以避免来回改同一文件）

**冲突解决规则**: 当 P1 与 P0 修复路径**强耦合**（修同一文件 / 共享基础设施）时，**允许**该 P1 提前进入 P0 批次；非耦合的 P1 一律推到 P1 阶段。这一例外通过"批次合并"显式标注，不破坏分级原则。

### 批次粒度（每批的硬约束）

- **范围**: 1 个批次 = 1 个修复子任务 = 1 次独立 commit（或紧密相关的小 commit 序列）
- **大小上限**: ≤ 10 个 finding / ≤ 800 行 diff（净增减），超出强制拆分
- **大小下限**: ≥ 2 个 finding（单条 P0/P1 trivial 改动可与同主题其他条目合批）
- **跨语言隔离**: Rust 与 Dart 不混批（FFI 契约修改例外，必须显式标注）

### 优先级总分配

| 阶段 | 范围 | 批次估计 | 工作量等级 |
|---|---|---|---|
| **P0 阶段** | 10 P0 + 强耦合的 P1（约 5-15 条） | 6-8 批 | high |
| **P1 阶段** | 余下 ~110 P1 | 12-16 批 | medium |
| **合计** | 全部 132 P0/P1 | 18-24 批 | — |

## 路线图文档结构（plan/ 子目录）

### `plan/roadmap.md`

主入口文档，包含：

1. **批次总览表** — 编号 / slug / 阶段(P0/P1) / 范围简介 / finding 数 / 工作量 (S/M/L) / 依赖前置批次
2. **执行顺序图** — ASCII / mermaid 显示批次依赖（哪些可并行、哪些必须串行）
3. **风险与里程碑** — 完成 P0 阶段是个里程碑；完成 P1 阶段又是一个；中间可以暂停
4. **如何启动一个批次** — 一键命令模板：
   ```bash
   python3 ./.trellis/scripts/task.py create "<批次标题>" \
     --slug <slug> --parent .trellis/tasks/archive/2026-05/05-19-full-codebase-review
   # 然后把 plan/batches/BATCH-XX.md 中的 jsonl 草稿粘进去
   python3 ./.trellis/scripts/task.py start .trellis/tasks/<新建任务路径>
   ```

### `plan/batches/BATCH-NN-<slug>.md`（每批一份）

每份文档包含 8 个 section（紧凑模板）：

```markdown
# BATCH-NN: <批次标题>

**Stage**: P0 / P1
**Slug**: <kebab-case>
**Effort**: S (≤200 行) / M (≤500 行) / L (≤800 行)
**Depends on**: BATCH-XX, BATCH-YY (or "none")

## 1. 范围
<1-2 句概述>

## 2. 包含的 findings
- [F-WXX-NNN] <一句话> — `file:line`
- ...

## 3. 影响文件
- `path/to/file.dart` — <什么改动>
- ...

## 4. 修复方向
<2-4 句技术路径，复用 master report 的"建议"段落即可，不深挖>

## 5. 测试策略
- <unit / widget / integration / 手动验证>

## 6. 验收
- [ ] 所有 finding 在新代码中已不存在 / 已被 spec 解释为接受
- [ ] lint / type-check / 现有测试套件全绿
- [ ] 必要的新测试用例通过

## 7. implement.jsonl 草稿
\`\`\`jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-XXX.md", "reason": "本批次涉及的 wave findings 文件"}
{"file": "<spec path>", "reason": "..."}
\`\`\`

## 8. check.jsonl 草稿
\`\`\`jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report，验证 finding 主题边界"}
{"file": "<spec path>", "reason": "..."}
\`\`\`
```

### `plan/dependencies.md`

跨批次依赖关系：
- **基础设施依赖**（`secure-credentials-via-keystore` 必须先做，凭据相关 P1 才能用）
- **重构依赖**（`reader-state-machine-controller` 必须先做，reader 相关 P1 才能干净切入）
- **不可并行的资源冲突**（同时改 Cargo workspace 必冲突）

## Requirements

- [ ] `plan/roadmap.md` 存在，含批次总览表 + 执行顺序图 + 启动命令模板
- [ ] `plan/batches/BATCH-NN-*.md` 总数 = 18-24 份（落地后修订）；**每条 P0/P1 finding 都被某个批次包含**（覆盖度审计：grep 核对）
- [ ] `plan/dependencies.md` 存在，至少标注 3 条跨批次依赖
- [ ] 每份 BATCH 文档的 8 个 section 都有内容（不能 placeholder 留空）
- [ ] implement.jsonl / check.jsonl 草稿均为合法 JSONL（每行 `{"file":..., "reason":...}`），路径在仓库内真实存在（除明显的"将来生成的 spec 文件"）
- [ ] 0 业务代码改动（`git status` 仅 `.trellis/tasks/05-20-fix-roadmap/` 新增）

## Acceptance Criteria

- [ ] 132 P0/P1 findings 100% 覆盖（用 awk 脚本核对：每个 batch 文档列出的 finding id 取并集 = master P0+P1 索引）
- [ ] 每批 finding 数 ≥ 2 且 ≤ 10
- [ ] 每批 effort 标记一致（标 S 实际 800 行不算 S）
- [ ] roadmap.md 给出"如果只做前 5 批会得到什么收益"的小结，方便部分启动

## Definition of Done

- 路线图自洽：依赖图无环、批次间无重复 finding、未覆盖 finding 列表为空
- 用户读完 `roadmap.md` 能在 5 分钟内决定"明天先做哪批"
- 所有 BATCH 文档的 jsonl 草稿可直接 copy 到子任务无需改写

## Out of Scope（再次强调）

- 创建任何修复子任务（路线图只是文档）
- 修代码 / 写新测试 / 跑 build
- P2 / P3 finding 的批次规划
- 第三方依赖的深度安全审计

## Technical Approach

### 执行步骤（实现阶段）

1. **读 master report** — 解析 P0+P1 索引（132 条）+ 主题汇总（10 个）+ 已有的 8 条第一批修复推荐
2. **强耦合检测** — 对每条 P0，查找其涉及文件是否同时出现在某条 P1（同主题且同文件 = 强耦合，候选合批）
3. **生成批次划分**：
   - P0 阶段：以 10 条 P0 为种子，按"主题 + 文件耦合"聚合，吸收强耦合 P1
   - P1 阶段：余下 P1 按主题归类，控制每批 ≤10 条 / ≤800 行
4. **依赖识别** — 标记基础设施先决批次（如 keystore wrapper / cargo workspace cleanup / reader controller）
5. **批次文档生成** — 每批一份，套用模板
6. **覆盖度审计** — `awk` 脚本对每个 BATCH-XX.md 提取 `[F-W\w-\d+]`，并集对照 master P0+P1 列表
7. **依赖图渲染** — 写入 `plan/dependencies.md`

### 工具

- `Read` master findings.md + 5 个 wave 文件
- `Grep` / `awk` 做 finding id 提取与覆盖度审计
- `Write` 生成 plan/* 文档
- 不跑 `cargo` / `flutter` / 测试

### 沙袋（避免发散）

- 每批不超过 10 条 finding 是硬约束
- BATCH 文档每段长度上限：用 master report 的"建议"句子原文 + 1-2 句补充，不重新分析
- 如果发现某条 finding 的修复方向上一份报告写得不够清晰，**记录到"路线图复盘"段落**，不在本任务内改报告

## Decision (ADR-lite)

**Context**: 132 条 P0/P1 需要规划修复顺序，怎么组织决定了未来 3-6 个月的修复节奏。

**Decision**:
1. **按风险分级**（用户选 #2）— P0 先全部修完再进 P1，符合"先止血再康复"直觉
2. **覆盖范围 P0 + P1**（用户确认）— P2/P3 留给独立 cleanup 任务
3. **jsonl 草稿提前列好**（用户确认）— 子任务一键 start，不重复 brainstorm
4. **路线图只产文档不开任务** — 避免一次建 20+ 空任务，active list 失去信号
5. **强耦合 P1 允许进 P0 批次** — 修同文件不来回改的实务考虑高于纯粹分级
6. **批次粒度 2-10 条 finding / ≤800 行** — 单 PR 可审核范围

**Consequences**:
- ✅ 用户可任意时间挑批次启动，路线图给出依赖关系免选错
- ✅ 子任务粒度统一可比较，便于估时
- ✅ 132 条 100% 覆盖，无遗漏
- ⚠️ 同主题跨批次：例如"JS 沙箱"主题既有 P0（4 条）又有 P1（5+条），按风险分级会被拆到 P0 阶段和 P1 阶段；强耦合规则允许部分回收，但不一定全部
- ⚠️ 路线图本身可能"过期"：如果某条 P1 在执行另一批时被顺手解决，路线图不会自动更新——开子任务时由 sub-agent 自己 re-verify

## Technical Notes

- 上一任务的 master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md`
- 5 个 wave findings 也在同一目录
- 路径变更注意：上一任务已 archive，所有引用应使用 archive 路径
- 当前 active task：仅本任务（其他都是 planning 长期挂着）
