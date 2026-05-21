//! Legado 规则的 JS 标记检测 helper（`is_js_rule` / `is_blocking_rule`）。
//!
//! 实际 JS bridge / runtime 在 [`super::js_runtime`]；本模块仅做规则字符串
//! 形态识别。`is_blocking_rule` 被 [`crate::parser::BookSourceParser::run_rule_first`]
//! 用作 `tokio::task::block_in_place` 的 gate。

/// 检测规则是否为 @js: 或 js: 类型
pub fn is_js_rule(rule: &str) -> bool {
    let trimmed = rule.trim();
    trimmed.starts_with("@js:") || trimmed.starts_with("js:") || trimmed.starts_with("@js\n")
}

/// 检测规则在执行时是否会阻塞当前线程（master findings F-W1B-038）。
///
/// 当前判定为"会阻塞"的规则形态：
/// - `@js:` / `js:` / `@js\n` 前缀（`is_js_rule` 命中）—— 走 QuickJS
///   eval，可能调 `java.ajax` / `java.post` 等同步 HTTP，5s ~ 30s 不等
/// - 内联 `<js>...</js>` —— 同 JS 路径，在 `legado::rule` 由
///   `contains_inline_js` 识别后走 `execute_inline_js_rule`
///
/// 命中此判定的规则在 tokio context 中应被 `block_in_place` 包装，避免
/// 在 reactor 工作线程上同步阻塞拖累 starve 同 reactor 上的其它 task。
/// 纯 CSS / XPath / JSONPath / Regex 规则是 µs 级，不必走 blocking 路径。
pub fn is_blocking_rule(rule: &str) -> bool {
    is_js_rule(rule) || rule.contains("<js>")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// F-W1B-038：`is_blocking_rule` 必须识别 4 种 JS 标记形态。
    #[test]
    fn test_is_blocking_rule_detects_js_markers() {
        // @js: 前缀
        assert!(is_blocking_rule("@js:result"));
        // js: 前缀
        assert!(is_blocking_rule("js:return result"));
        // @js\n 多行
        assert!(is_blocking_rule("@js\nreturn result"));
        // <js>...</js> 内联
        assert!(is_blocking_rule(".item@text<js>result.toUpperCase()</js>"));
        // 纯 CSS / XPath / JSONPath / Regex 不命中
        assert!(!is_blocking_rule(".container > a@href"));
        assert!(!is_blocking_rule("//div[@class='x']"));
        assert!(!is_blocking_rule("$.items[0].name"));
        assert!(!is_blocking_rule("##\\d+##\\$0"));
    }
}
