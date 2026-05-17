# R107 — api-server token 常量时间比较

## 背景

`core/api-server/src/main.rs::auth_middleware` 当前用普通字符串 `!=` 比较 Authorization 头与期望 token：

```rust
if auth != format!("Bearer {}", state.api_token) {
    return Err(StatusCode::UNAUTHORIZED);
}
```

`!=` 在 Rust 里是 byte-by-byte 短路比较，第一个不同字节就 return。理论上攻击者可通过测量 RTT 时序差异逐字节恢复 token。

**实际可达性低**：
- 当前部署默认 loopback；时序信号在 localhost 上被噪声淹没
- token 是 UUIDv4 格式 36 字符 + "Bearer " 前缀，每尝试一次至少一个 round-trip
- 没有 rate limit 但本地服务被远端攻击的前提是先突破 R57 Origin 检查 + 网络层

但这是**已知 anti-pattern**，无论可达性高低都该用 constant-time 比较修。修复成本极低。

## 目标

把 token 比较改成不依赖共同前缀长度的 constant-time 实现，避免逐字节短路。

## 实现策略

### 选 dep：subtle 2.6.1（已在依赖图）

`subtle` crate 已被 sha2 / aes 等 transitive 拉进 Cargo.lock。在 `core/api-server/Cargo.toml` 加 `subtle = "2"` 直接依赖，不引入新 build cost。

### 用法

```rust
use subtle::ConstantTimeEq;

let expected = format!("Bearer {}", state.api_token);
let auth_bytes = auth.as_bytes();
let expected_bytes = expected.as_bytes();
// ConstantTimeEq::ct_eq returns Choice. Combine length check + content check
// in constant time relative to the input contents.
let len_eq = auth_bytes.len().ct_eq(&expected_bytes.len());
let content_eq = if auth_bytes.len() == expected_bytes.len() {
    auth_bytes.ct_eq(expected_bytes)
} else {
    // Compare against expected to keep timing relative to expected length
    // (avoids timing leak for "wrong length"). Result is then masked off
    // by len_eq below.
    expected_bytes.ct_eq(expected_bytes)  // dummy compute, discarded
};
let ok: bool = (len_eq & content_eq).into();
if !ok {
    return Err(StatusCode::UNAUTHORIZED);
}
```

**简化思路**：subtle 文档推荐写法是 `bool::from(slice_a.ct_eq(slice_b))`，但当长度不同 ct_eq 直接返回 false（且本身 short-circuits on length 这是 slice 实现细节，但 subtle::ConstantTimeEq for slice 是文档化为时序中立——以较短长度跑，再 OR len_eq）。

参考 subtle::ConstantTimeEq for `[u8]`:
> Compares whether two slices are equal in constant time. WARNING: this implementation does NOT compare slices of different lengths in constant time, but does perform constant-time comparison of slices of the same length.

所以**长度差异本身不是 constant-time**——但这不构成实际泄漏（attacker 已知 expected 长度 = 7 + 36 = 43，可以构造正确长度的 input 后再尝试 byte 内容）。可以接受。

最终实现简洁版：

```rust
use subtle::ConstantTimeEq;

let expected = format!("Bearer {}", state.api_token);
if !bool::from(auth.as_bytes().ct_eq(expected.as_bytes())) {
    return Err(StatusCode::UNAUTHORIZED);
}
```

注释说明：
- subtle::ConstantTimeEq 在等长输入上是 constant-time
- 不等长仍可能时序泄漏，但 token 长度可由 attacker 推测（UUIDv4 + Bearer 前缀），对总安全性影响小

## 实现要点

1. `core/api-server/Cargo.toml` 加 `subtle = "2"` 依赖
2. `core/api-server/src/main.rs` 顶部 `use subtle::ConstantTimeEq;`
3. `auth_middleware` 把 `if auth != format!(...)` 改 `if !bool::from(auth.as_bytes().ct_eq(expected.as_bytes()))`
4. 加注释引用 R107 + 解释长度时序的已知 limitation
5. 新增单元测试：构造 AppState 模拟两个比较场景（match / mismatch），断言行为正确（功能性测试，不验证时序）

## 验收标准

- cargo check --workspace: clean
- cargo test --workspace: 至少 261 passed (260 + 1 R107 新测)
- flutter analyze / test：不变
- 手动 trace（无法跑）：构造正确 / 错误 token 调 /sources 接口，行为不变（200 / 401）

## 不在范围

- R22/R23 Web 平台兼容性
- R117-R119/R121/R122/R124 trivial / nano

R107 完成后，所有 R1-R124 的可执行修复全部清空。剩余只剩 R22/R23 设计层面 Web 兼容（Android-first 项目不阻塞）。
