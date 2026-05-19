# BATCH-09: 备份加密强化（弱算法 + 解密 fail-fast + GCM 路径）+ replace_rules 主线程串行化

**Stage**: P0 + P1 (混合：F-W1A-001 是 P0 的弱算法主题；与同文件 P1 解密 fail-fast 强耦合，合批避免回归同文件两次)
**Slug**: `backup-aes-and-replace-rules-perf`
**Effort**: M (≤500 行)
**Depends on**: BATCH-06 (zeroize/secrecy 已进 workspace)

## 1. 范围

4 条独立但都涉及 `core-storage::legado_aes` / `core-storage::backup_dao` / `bridge::api::apply_replace_rules` 加密 / 性能短板：备份用 AES-128/ECB + MD5 弱算法（P0）、解密无认证（AES-GCM 路径）、zip-bomb 单文件大小、replace_rules 全局 Mutex 阻塞主线程。F-W1A-001 是 P0 但与 F-W1A-003 修同一文件强耦合（按 PRD 冲突解决规则允许提前进同批）。

## 2. 包含的 findings

- [F-W1A-001] 备份加密用 AES-128/ECB + MD5 派生 key 弱算法 — `core/core-storage/src/legado_aes.rs:33-131` (P0)
- [F-W1A-003] 备份解密无认证（无 HMAC / GCM tag），filter 路径可绕过 — `core/core-storage/src/legado_aes.rs:91-102` (P1，强耦合：同文件 + 同主题)
- [F-W1A-012] backup zip 解压无单文件大小限制，zip-bomb 可 OOM — `core/core-storage/src/backup_dao.rs:187-203` (P1)
- [F-W1A-019] apply_replace_rules 全局 Mutex 阻塞主线程 — `core/bridge/src/api.rs:1066-1109` (P1)

## 3. 影响文件

- `core/core-storage/src/legado_aes.rs:33-131` — F-W1A-001：(1) 对外文档 / UI 文案明确"备份密码不是加密强度保护，仅 Legado 互兼容"；(2) 引入额外 AES-GCM + Argon2id 派生的"强加密备份"选项，旧格式仅作 fallback 互兼容；(3) 严格审查所有"已加密"措辞避免误导用户
- `core/core-storage/src/legado_aes.rs:91-102` — F-W1A-003：解密成功后强制 JSON parse，失败即视为密文损坏；与新 GCM 路径配合
- `core/core-storage/src/backup_dao.rs:187-203` — 在 `read_to_string` 前 check `entry.size()` (压缩前) 与 `entry.compressed_size()`，超过 50MB 单文件 / 500MB 总量拒绝；或改流式解析 `serde_json::from_reader`
- `core/bridge/src/api.rs:1066-1109` — 把 `get_or_load_rules` 内的 SQL 调用移到 lock 外（先释放 lock 拿规则列表，再加锁更新缓存）；或用 `parking_lot::RwLock` 让多读者并发

## 4. 修复方向

- F-W1A-001：参照 master findings-rust-data.md 的 (1)+(2)+(3) 三步：文档 / 强加密路径 / 用语审查；不强行废弃旧路径以保证与 Legado 互兼容。
- F-W1A-003：fail-fast 是短期；新路径强化方案见 F-W1A-001。
- F-W1A-012：单文件 50MB / 总 500MB 阈值；流式解析为优先方案。
- F-W1A-019：抽出 hot path 计算到 lock 外；用 `parking_lot::RwLock` 让多读者并发。

## 5. 测试策略

- Rust unit test：错密码 + 篡改 ciphertext 时 decrypt 返回 Err（fail-fast）而非空字符串
- Rust unit test：构造 60MB 单文件 zip 后 import_backup_zip 返回错误
- Rust unit test / benchmark：1000 条 replace_rules 并发 apply 不卡主线程（多 thread bench）

## 6. 验收

- [ ] master finding F-W1A-001/003/012/019 全部消解
- [ ] zip-bomb 测试用例（单文件 + 总量）触发拒绝
- [ ] apply_replace_rules 加 thread profile 后无 main reactor stall

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md", "reason": "本批次涉及的 wave 1A findings"}
{"file": "core/core-storage/src/legado_aes.rs", "reason": "解密 fail-fast"}
{"file": "core/core-storage/src/backup_dao.rs", "reason": "zip-bomb 防护"}
{"file": "core/bridge/src/api.rs", "reason": "apply_replace_rules + ReplaceRulesCache 优化"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "解压上限 spec"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题边界"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md", "reason": "Wave 1A 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-09-backup-aes-and-replace-rules-perf.md", "reason": "本批次自身验收清单"}
```
