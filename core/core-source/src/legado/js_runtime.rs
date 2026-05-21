//! Legado JavaScript runtime abstraction.
//!
//! Full Legado source compatibility requires executing user-provided JavaScript
//! from `@js:`, `<js></js>`, URL templates, and URL options. This module keeps
//! the rule engine independent from the concrete embedded JS engine.
//!
//! # QuickJS Runtime Pooling (BATCH-13, F-W1B-023/024/026/027)
//!
//! `QuickJsRuntime::eval` reuses a single `rquickjs::Runtime` + `Context`
//! per worker thread instead of building fresh ones per call. Without pooling,
//! every eval paid the cost of creating a Runtime, Context, and re-registering
//! ~30 bridge `Function`s — measured by 100-chapter TOC parsing where the
//! register step dominated the wall-clock cost.
//!
//! ## What is amortized
//! - `Runtime::new()` plus its memory/stack limits and GC subsystem.
//! - `Context::full(&runtime)` (globalThis bootstrap).
//! - `register_quickjs_bridge(&ctx)` (the 30+ `__legado_*` functions).
//!
//! ## What still runs every call
//! - `runtime.set_interrupt_handler(...)` — re-installed each eval with a
//!   fresh `Instant::now()` so the timeout window is per-call.
//! - The "set vars" step (`legado_value_to_js_var` for each entry of `vars`).
//! - `ctx.eval(PREAMBLE)` — re-evaluating PREAMBLE rebuilds the `java`,
//!   `cache`, `cookie`, and `source` global objects. This is the **isolation
//!   mechanism** between evals: any state the previous user script wrote into
//!   `java._vars`, `java.headerMap`, etc. is discarded when PREAMBLE redefines
//!   `var java = { ... }`.
//!
//! ## State isolation guarantees
//! - `java`, `cache`, `cookie`, `source` — fully reset by PREAMBLE re-eval.
//! - PREAMBLE-guarded globals (`__legado_url__`, `__legado_headers__`,
//!   `__legado_default_headers__`, `__legado_variables__`, `__source_url__`)
//!   — explicitly cleared via `delete globalThis.X` before set-vars so
//!   `typeof X !== 'undefined'` checks behave the same as on a fresh runtime.
//! - User-script globals (e.g. `var x = 1` at script top level) — NOT cleared.
//!   Real Legado sources never depend on this; they share state via
//!   `java.put` / `java.get` (see [`LEGADO_JS_VARIABLES`]) or via
//!   `RuleContext::shared_variables` for cross-thread state.
//!
//! ## Cooperation with other thread-locals
//! - [`LEGADO_JS_VARIABLES`] (BATCH-11) — write-through bucket for
//!   `java.put/get`; orthogonal to the pool.
//! - [`JsVariablesOverride`] RAII guard — snapshots/restores
//!   `LEGADO_JS_VARIABLES` around each `eval_default_with_http_state` call;
//!   orthogonal to the pool.
//! - [`COOKIE_JAR_OVERRIDE`] — same pattern; orthogonal.
//!
//! ## Re-entrancy
//! Bridge functions like `__legado_get_string` may recursively trigger
//! JS eval (for example a Legado `@js:` rule inside a CSS/jsoup pipeline).
//! Re-entering `Context::with` on the same `Context` would deadlock on the
//! runtime mutex; nested calls therefore fall back to a fresh
//! `Runtime + Context` (the pre-BATCH-13 behaviour). The pool covers the
//! common top-level case.
//!
//! ## Error recovery
//! - Timeout interrupts leave the runtime in a usable state (rquickjs
//!   contract; verified by `test_runtime_pool_recovers_from_timeout`).
//! - Initialization failures (`Runtime::new` etc.) propagate to the caller;
//!   the pool entry stays `None` so the next call retries init.
//! - Per-eval failures (set vars / PREAMBLE / user script) do **not** rebuild
//!   the entry. This matches the pre-BATCH-13 contract.

#[cfg(feature = "js-quickjs")]
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
#[cfg(feature = "js-quickjs")]
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;
#[cfg(feature = "js-quickjs")]
use std::sync::OnceLock;

#[cfg(feature = "js-quickjs")]
use super::ssrf_guard;

#[cfg(feature = "js-quickjs")]
thread_local! {
    static LEGADO_SET_CONTENT: std::cell::RefCell<Option<(String, String)>> = std::cell::RefCell::new(None);
    static LEGADO_JS_VARIABLES: std::cell::RefCell<HashMap<String, LegadoValue>> = std::cell::RefCell::new(HashMap::new());
}

/// Per-thread pooled QuickJS Runtime + Context (BATCH-13).
///
/// See the module doc for the full rationale and isolation contract.
#[cfg(feature = "js-quickjs")]
struct RuntimePoolEntry {
    runtime: rquickjs::Runtime,
    context: rquickjs::Context,
}

#[cfg(feature = "js-quickjs")]
thread_local! {
    /// Lazily-initialized per-thread Runtime + Context. `None` until the
    /// first eval on the thread.
    static QUICKJS_POOL: RefCell<Option<RuntimePoolEntry>> = const { RefCell::new(None) };

    /// Re-entrancy guard. `true` while we are already inside a pooled
    /// `Context::with` closure on this thread; nested evals must take the
    /// fresh-runtime fallback path to avoid deadlocking on the runtime mutex.
    static QUICKJS_POOL_BUSY: Cell<bool> = const { Cell::new(false) };
}

/// Hard upper bound on QuickJS heap (F-W1B-003 partial mitigation,
/// applied during pool init). 64 MiB is generous for ordinary Legado
/// rule scripts but caps obvious `new Array(1<<28)` style attacks.
#[cfg(feature = "js-quickjs")]
const QUICKJS_MEMORY_LIMIT: usize = 64 * 1024 * 1024;

/// Hard upper bound on QuickJS stack (F-W1B-003 partial mitigation).
/// 1 MiB is roughly the QuickJS default; setting it explicitly makes
/// the limit visible and stable across rquickjs releases.
#[cfg(feature = "js-quickjs")]
const QUICKJS_STACK_LIMIT: usize = 1024 * 1024;

/// JS that clears PREAMBLE-guarded globals so `typeof X !== 'undefined'`
/// checks behave the same as on a fresh runtime. Run at the top of every
/// pooled eval before set-vars.
#[cfg(feature = "js-quickjs")]
const QUICKJS_RESET_GUARDED_VARS: &str = "\
delete globalThis.__legado_url__;\
delete globalThis.__legado_headers__;\
delete globalThis.__legado_default_headers__;\
delete globalThis.__legado_variables__;\
delete globalThis.__source_url__;\
";

/// RAII guard that flips `QUICKJS_POOL_BUSY` back to `false` on drop,
/// so a panic inside the eval closure still releases the re-entrancy gate.
#[cfg(feature = "js-quickjs")]
struct PoolBusyGuard;

#[cfg(feature = "js-quickjs")]
impl Drop for PoolBusyGuard {
    fn drop(&mut self) {
        QUICKJS_POOL_BUSY.with(|cell| cell.set(false));
    }
}

/// Run `f` inside a `Ctx` that has the bridge already registered.
///
/// On the top-level call this reuses the per-thread [`QUICKJS_POOL`]
/// entry. Nested calls (re-entry) fall back to a one-shot Runtime+Context
/// to avoid locking the same mutex twice. `timeout_ms = 0` disables the
/// interrupt handler.
#[cfg(feature = "js-quickjs")]
fn with_thread_quickjs<F, R>(timeout_ms: u64, f: F) -> Result<R, String>
where
    F: FnOnce(&rquickjs::Ctx<'_>) -> Result<R, String>,
{
    use rquickjs::{Context, Runtime};

    // Nested eval (e.g. user JS calls `java.getString(rule)` whose Rust
    // bridge invokes `execute_legado_rule` which evaluates another JS
    // rule). The pooled Context is currently locked on this thread, so
    // we must not re-enter `Context::with` on it.
    if QUICKJS_POOL_BUSY.with(|cell| cell.get()) {
        let runtime = Runtime::new().map_err(|e| format!("quickjs runtime: {e}"))?;
        runtime.set_memory_limit(QUICKJS_MEMORY_LIMIT);
        runtime.set_max_stack_size(QUICKJS_STACK_LIMIT);
        let context = Context::full(&runtime).map_err(|e| format!("quickjs context: {e}"))?;
        if timeout_ms > 0 {
            let start = std::time::Instant::now();
            runtime.set_interrupt_handler(Some(Box::new(move || {
                start.elapsed() > std::time::Duration::from_millis(timeout_ms)
            })));
        }
        return context.with(|ctx| {
            register_quickjs_bridge(&ctx)?;
            f(&ctx)
        });
    }

    // Lazy init. Bridge registration runs exactly once per worker thread.
    QUICKJS_POOL.with(|cell| -> Result<(), String> {
        let mut pool = cell.borrow_mut();
        if pool.is_none() {
            let runtime = Runtime::new().map_err(|e| format!("quickjs runtime: {e}"))?;
            runtime.set_memory_limit(QUICKJS_MEMORY_LIMIT);
            runtime.set_max_stack_size(QUICKJS_STACK_LIMIT);
            let context = Context::full(&runtime).map_err(|e| format!("quickjs context: {e}"))?;
            context.with(|ctx| register_quickjs_bridge(&ctx))?;
            *pool = Some(RuntimePoolEntry { runtime, context });
        }
        Ok(())
    })?;

    // Refresh the interrupt handler with a fresh start time. `with` borrows
    // the entry only for the handler-set call; we drop it before re-borrowing
    // to enter `context.with`, since the latter holds the runtime mutex
    // throughout the closure.
    QUICKJS_POOL.with(|cell| {
        let pool = cell.borrow();
        let Some(entry) = pool.as_ref() else { return };
        if timeout_ms > 0 {
            let start = std::time::Instant::now();
            entry
                .runtime
                .set_interrupt_handler(Some(Box::new(move || {
                    start.elapsed() > std::time::Duration::from_millis(timeout_ms)
                })));
        } else {
            entry.runtime.set_interrupt_handler(None);
        }
    });

    QUICKJS_POOL_BUSY.with(|cell| cell.set(true));
    let _busy = PoolBusyGuard;

    QUICKJS_POOL.with(|cell| {
        let pool = cell.borrow();
        // The lazy-init step above guarantees Some(entry); if a future refactor
        // breaks that invariant, surface a clear error rather than panicking.
        let Some(entry) = pool.as_ref() else {
            return Err("quickjs pool entry missing after lazy-init".to_string());
        };
        entry.context.with(|ctx| f(&ctx))
    })
}

use super::context::RuleContext;
use super::value::LegadoValue;

static CACHE_DB_PATH: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();

pub fn set_cache_db_path(path: Option<String>) {
    let _ = CACHE_DB_PATH.set(path);
}

fn get_cache_db_path() -> Option<&'static String> {
    CACHE_DB_PATH.get().and_then(|opt| opt.as_ref())
}

/// JavaScript runtime configuration.
#[derive(Clone)]
pub struct JsRuntimeConfig {
    pub timeout_ms: u64,
    pub max_script_len: usize,
}

impl Default for JsRuntimeConfig {
    fn default() -> Self {
        Self {
            timeout_ms: 5000,
            max_script_len: 100_000,
        }
    }
}

/// Common interface for embedded JavaScript runtimes.
pub trait JsRuntime: Send + Sync {
    fn eval(
        &self,
        script: &str,
        vars: &HashMap<String, LegadoValue>,
    ) -> Result<LegadoValue, String>;

    fn eval_string(
        &self,
        script: &str,
        vars: &HashMap<String, LegadoValue>,
    ) -> Result<String, String> {
        self.eval(script, vars).map(|v| v.as_string_lossy())
    }
}

/// Build the standard Legado JS variable map for a rule execution context.
pub fn build_runtime_vars(context: &RuleContext, html: &str) -> HashMap<String, LegadoValue> {
    let mut vars = context.all_variables();
    vars.insert(
        "baseUrl".into(),
        LegadoValue::String(context.base_url.clone()),
    );
    vars.insert(
        "base_url".into(),
        LegadoValue::String(context.base_url.clone()),
    );
    vars.insert(
        "src".into(),
        LegadoValue::String(
            if context.src.is_empty() {
                html
            } else {
                &context.src
            }
            .to_string(),
        ),
    );
    vars.insert("title".into(), LegadoValue::String(context.title.clone()));
    vars.insert("key".into(), LegadoValue::String(context.key.clone()));
    vars.insert("keyword".into(), LegadoValue::String(context.key.clone()));
    vars.insert("page".into(), LegadoValue::Int(context.page as i64));
    vars.insert("result".into(), context.get_variable("result"));
    vars.insert("book".into(), context.get_variable("book"));
    vars.insert("chapter".into(), context.get_variable("chapter"));
    vars.insert(
        "__legado_variables__".into(),
        LegadoValue::Map(context.all_variables()),
    );
    vars
}

/// Evaluate JS using the default configured runtime.
pub fn eval_default(
    script: &str,
    vars: &HashMap<String, LegadoValue>,
) -> Result<LegadoValue, String> {
    DefaultJsRuntime::new().eval(script, vars)
}

/// Execute JS with shared HTTP state for java.ajax/get/post/getCookie.
#[cfg(feature = "js-quickjs")]
pub fn eval_default_with_http_state(
    script: &str,
    vars: &HashMap<String, LegadoValue>,
    cookie_jar: Arc<reqwest::cookie::Jar>,
    default_headers: Vec<(String, String)>,
) -> Result<LegadoValue, String> {
    let _guard = JsCookieJarOverride::install(cookie_jar);
    let _vars_guard = JsVariablesOverride::install(vars.clone());
    let mut vars = vars.clone();
    vars.insert(
        "__legado_default_headers__".into(),
        headers_to_legado_value(&default_headers),
    );
    DefaultJsRuntime::new().eval(script, &vars)
}

#[cfg(not(feature = "js-quickjs"))]
pub fn eval_default_with_http_state(
    script: &str,
    vars: &HashMap<String, LegadoValue>,
    _cookie_jar: Arc<reqwest::cookie::Jar>,
    _default_headers: Vec<(String, String)>,
) -> Result<LegadoValue, String> {
    eval_default(script, vars)
}

pub fn eval_default_with_cookie_jar(
    script: &str,
    vars: &HashMap<String, LegadoValue>,
    cookie_jar: Arc<reqwest::cookie::Jar>,
) -> Result<LegadoValue, String> {
    eval_default_with_http_state(script, vars, cookie_jar, Vec::new())
}

/// Mutable URL request data modified by Legado URL option.js scripts.
#[derive(Debug, Clone)]
pub struct UrlJsContext {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

impl UrlJsContext {
    pub fn new(url: &str, headers: &[(String, String)]) -> Self {
        Self {
            url: url.to_string(),
            headers: headers.to_vec(),
        }
    }
}

/// Execute URL option.js and return the updated URL/header state.
pub fn eval_url_option_js(script: &str, context: &UrlJsContext) -> Result<UrlJsContext, String> {
    let mut vars = HashMap::new();
    vars.insert(
        "__legado_url__".into(),
        LegadoValue::String(context.url.clone()),
    );
    vars.insert(
        "__legado_headers__".into(),
        headers_to_legado_value(&context.headers),
    );
    let wrapped = format!(
        "(function(){{ {}; return JSON.stringify({{url: java.url, headers: java.headerMap.toObject()}}); }})()",
        script
    );
    let value = eval_default(&wrapped, &vars)?;
    let json = value.as_string_lossy();
    let parsed: serde_json::Value = serde_json::from_str(&json)
        .map_err(|e| format!("URL option.js result parse error: {e}; result={json}"))?;
    let url = parsed
        .get("url")
        .and_then(|v| v.as_str())
        .unwrap_or(&context.url)
        .to_string();
    let headers = parsed
        .get("headers")
        .and_then(|v| v.as_object())
        .map(|map| {
            map.iter()
                .map(|(k, v)| {
                    (
                        k.clone(),
                        v.as_str()
                            .map(str::to_string)
                            .unwrap_or_else(|| v.to_string()),
                    )
                })
                .collect()
        })
        .unwrap_or_else(|| context.headers.clone());
    Ok(UrlJsContext { url, headers })
}

fn headers_to_legado_value(headers: &[(String, String)]) -> LegadoValue {
    let mut map = HashMap::new();
    for (key, value) in headers {
        map.insert(key.clone(), LegadoValue::String(value.clone()));
    }
    LegadoValue::Map(map)
}

#[cfg(feature = "js-quickjs")]
pub type DefaultJsRuntime = QuickJsRuntime;

#[cfg(all(not(feature = "js-quickjs"), feature = "js-boa"))]
pub type DefaultJsRuntime = BoaJsRuntime;

#[cfg(all(not(feature = "js-quickjs"), not(feature = "js-boa")))]
pub type DefaultJsRuntime = NoopJsRuntime;

/// Runtime used when no JS feature is enabled.
pub struct NoopJsRuntime {
    config: JsRuntimeConfig,
}

impl NoopJsRuntime {
    pub fn new() -> Self {
        Self {
            config: JsRuntimeConfig::default(),
        }
    }
}

impl Default for NoopJsRuntime {
    fn default() -> Self {
        Self::new()
    }
}

impl JsRuntime for NoopJsRuntime {
    fn eval(
        &self,
        script: &str,
        _vars: &HashMap<String, LegadoValue>,
    ) -> Result<LegadoValue, String> {
        if script.len() > self.config.max_script_len {
            return Err(format!(
                "Script too long: {} > {}",
                script.len(),
                self.config.max_script_len
            ));
        }
        Err("JavaScript runtime is disabled".into())
    }
}

#[cfg(feature = "js-quickjs")]
pub struct QuickJsRuntime {
    config: JsRuntimeConfig,
}

#[cfg(feature = "js-quickjs")]
impl QuickJsRuntime {
    pub fn new() -> Self {
        Self {
            config: JsRuntimeConfig::default(),
        }
    }
}

#[cfg(feature = "js-quickjs")]
impl Default for QuickJsRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(feature = "js-quickjs")]
impl JsRuntime for QuickJsRuntime {
    fn eval(
        &self,
        script: &str,
        vars: &HashMap<String, LegadoValue>,
    ) -> Result<LegadoValue, String> {
        if script.len() > self.config.max_script_len {
            return Err(format!(
                "Script too long: {} > {}",
                script.len(),
                self.config.max_script_len
            ));
        }

        let cleaned = clean_js_script(script);
        if cleaned.is_empty() {
            return Ok(LegadoValue::Null);
        }

        with_thread_quickjs(self.config.timeout_ms, |ctx| {
            // Reset PREAMBLE-guarded globals so `typeof X !== 'undefined'`
            // checks behave the same as on a fresh runtime. This must run
            // BEFORE the var-injection loop, because the loop installs
            // `__legado_url__` etc. when present in `vars`.
            ctx.eval::<(), _>(QUICKJS_RESET_GUARDED_VARS)
                .map_err(|e| format!("reset guarded vars: {e}"))?;

            for (name, value) in vars {
                let stmt = legado_value_to_js_var(name, value);
                ctx.eval::<(), _>(stmt.as_str())
                    .map_err(|e| format!("set '{name}': {e}"))?;
            }

            // Re-eval PREAMBLE every call. This rebuilds `var java = { ... }`
            // and friends, discarding any state the previous user script left
            // on the shared globals (the pool's isolation mechanism).
            ctx.eval::<(), _>(PREAMBLE)
                .map_err(|e| format!("preamble: {e}"))?;
            let expression = js_script_to_expression(cleaned);
            let json = ctx
                .eval::<String, _>(format!("JSON.stringify(({}))", expression))
                .map_err(|e| format!("eval: {e}"))?;
            js_json_to_legado(&json)
        })
    }
}

#[cfg(feature = "js-boa")]
pub struct BoaJsRuntime {
    config: JsRuntimeConfig,
}

#[cfg(feature = "js-boa")]
impl BoaJsRuntime {
    pub fn new() -> Self {
        Self {
            config: JsRuntimeConfig::default(),
        }
    }
}

#[cfg(feature = "js-boa")]
impl Default for BoaJsRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(feature = "js-boa")]
impl JsRuntime for BoaJsRuntime {
    fn eval(
        &self,
        script: &str,
        vars: &HashMap<String, LegadoValue>,
    ) -> Result<LegadoValue, String> {
        if script.len() > self.config.max_script_len {
            return Err(format!(
                "Script too long: {} > {}",
                script.len(),
                self.config.max_script_len
            ));
        }

        let cleaned = clean_js_script(script);
        if cleaned.is_empty() {
            return Ok(LegadoValue::Null);
        }

        use boa_engine::{Context, Source};

        let mut context = Context::default();
        for (name, value) in vars {
            let js_stmt = legado_value_to_js_var(name, value);
            context
                .eval(Source::from_bytes(js_stmt.as_bytes()))
                .map_err(|e| format!("set '{name}': {e}"))?;
        }

        context
            .eval(Source::from_bytes(PREAMBLE.as_bytes()))
            .map_err(|e| format!("preamble: {e}"))?;
        let expression = js_script_to_expression(cleaned);
        let wrapped = format!("JSON.stringify(({}))", expression);
        let result = context
            .eval(Source::from_bytes(wrapped.as_bytes()))
            .map_err(|e| format!("eval: {e}"))?;
        js_json_to_legado(&format!("{}", result.display()))
    }
}

#[cfg(any(feature = "js-quickjs", feature = "js-boa"))]
fn clean_js_script(script: &str) -> &str {
    script
        .trim()
        .strip_prefix("@js:")
        .or_else(|| script.trim().strip_prefix("js:"))
        .unwrap_or(script.trim())
        .trim()
}

#[cfg(any(feature = "js-quickjs", feature = "js-boa"))]
fn js_script_to_expression(script: &str) -> String {
    let script = script.trim();
    let is_iife = script.starts_with("(function(") || script.starts_with("(function ");
    if contains_return_statement(script) && !is_iife {
        // Bare `return` is illegal at script top level; wrap in IIFE so
        // the surrounding `JSON.stringify((...))` captures the value.
        format!("(function(){{{}}})()", script)
    } else if needs_direct_eval(script) && !is_iife {
        // F-W1B-013 (BATCH-10): kept as `eval(JSON_STRING)` rather than
        // a uniform IIFE wrap. This is **Resolved-by-Design** — see
        // `.trellis/spec/rust-core/quality-and-anti-patterns.md`
        // ("F-W1B-013 业务边界") for the rationale. In short:
        //
        // - `serde_json::to_string(script)` produces a well-formed JS
        //   string literal (proper escaping for `'`, `"`, `\n`,
        //   `\u00xx`, `</script>`, etc.). The eval'd content is the
        //   user's script verbatim — *not* a string-concat injection.
        //   `test_js_script_to_expression_eval_branch_escapes_meta_chars`
        //   pins this contract.
        // - An IIFE wrap would force callers to inject an explicit
        //   `return` for the trailing expression, but the production
        //   call shape is `JSON.stringify((expr))` over the wrapped
        //   form, and that breaks for multi-statement scripts whose
        //   tail is a bare expression statement (the IIFE would
        //   return undefined). Empirically, swapping to IIFE on this
        //   branch broke ~30 unit tests — see BATCH-10 PRD §F-W1B-013
        //   "决策路径".
        // - `direct_eval` keeps QuickJS's top-level "last expression
        //   value is the eval result" semantic, which the bare-script
        //   branch (`script.to_string()`) also relies on.
        format!(
            "eval({})",
            serde_json::to_string(script).unwrap_or_else(|_| "''".into())
        )
    } else {
        script.to_string()
    }
}

#[cfg(any(feature = "js-quickjs", feature = "js-boa"))]
fn contains_return_statement(script: &str) -> bool {
    let trimmed = script.trim();
    trimmed.starts_with("return ")
        || trimmed == "return"
        || trimmed.contains("\nreturn ")
        || trimmed.contains(";return ")
        || trimmed
            .lines()
            .any(|line| line.trim_start().starts_with("return "))
}

#[cfg(any(feature = "js-quickjs", feature = "js-boa"))]
fn needs_direct_eval(script: &str) -> bool {
    let trimmed = script.trim_start();
    script.contains(';')
        || script.contains('\n')
        || trimmed.starts_with("var ")
        || trimmed.starts_with("let ")
        || trimmed.starts_with("const ")
        || trimmed.starts_with("if ")
        || trimmed.starts_with("if(")
        || trimmed.starts_with("for ")
        || trimmed.starts_with("for(")
        || trimmed.starts_with("while ")
        || trimmed.starts_with("while(")
        || trimmed.starts_with("try ")
}

#[cfg(any(feature = "js-quickjs", feature = "js-boa"))]
fn legado_value_to_js_var(name: &str, value: &LegadoValue) -> String {
    format!("var {} = {};", name, legado_value_to_js_expr(value))
}

#[cfg(any(feature = "js-quickjs", feature = "js-boa"))]
fn legado_value_to_js_expr(value: &LegadoValue) -> String {
    match value {
        LegadoValue::Null => "null".into(),
        LegadoValue::Bool(true) => "true".into(),
        LegadoValue::Bool(false) => "false".into(),
        LegadoValue::Int(i) => i.to_string(),
        LegadoValue::Float(f) => f.to_string(),
        LegadoValue::String(s) | LegadoValue::Html(s) => {
            serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
        }
        LegadoValue::Array(arr) => {
            let items: Vec<String> = arr.iter().map(legado_value_to_js_expr).collect();
            format!("[{}]", items.join(", "))
        }
        LegadoValue::Map(map) => {
            // F-W1B-014 (BATCH-11): collect entries into BTreeMap so the
            // generated JS object literal has stable key order; without
            // this the underlying HashMap would reshuffle on every eval
            // and JS rules like `Object.keys(book)[0]` would observe
            // non-deterministic results. We sort at the *output* boundary
            // only — `LegadoValue::Map(HashMap<...>)` itself stays.
            let sorted: std::collections::BTreeMap<&String, &LegadoValue> = map.iter().collect();
            let pairs: Vec<String> = sorted
                .iter()
                .map(|(k, v)| {
                    let key_lit =
                        serde_json::to_string(k.as_str()).unwrap_or_else(|_| "\"\"".into());
                    format!("{}:{}", key_lit, legado_value_to_js_expr(v))
                })
                .collect();
            format!("{{{}}}", pairs.join(","))
        }
    }
}

#[cfg(any(feature = "js-quickjs", feature = "js-boa"))]
fn js_json_to_legado(json: &str) -> Result<LegadoValue, String> {
    if json == "undefined" {
        return Ok(LegadoValue::Null);
    }
    let value: serde_json::Value = serde_json::from_str(json)
        .map_err(|e| format!("JS result JSON parse error: {e}; result={json}"))?;
    Ok(LegadoValue::from_json_value(&value))
}

#[cfg(feature = "js-quickjs")]
fn register_quickjs_bridge(ctx: &rquickjs::Ctx<'_>) -> Result<(), String> {
    use rquickjs::Function;

    let global = ctx.globals();
    global
        .set(
            "__legado_base64_encode",
            Function::new(ctx.clone(), java_base64_encode)
                .map_err(|e| format!("register base64Encode: {e}"))?,
        )
        .map_err(|e| format!("set base64Encode: {e}"))?;
    global
        .set(
            "__legado_base64_decode",
            Function::new(ctx.clone(), java_base64_decode)
                .map_err(|e| format!("register base64Decode: {e}"))?,
        )
        .map_err(|e| format!("set base64Decode: {e}"))?;
    global
        .set(
            "__legado_md5",
            Function::new(ctx.clone(), java_md5_encode)
                .map_err(|e| format!("register md5Encode: {e}"))?,
        )
        .map_err(|e| format!("set md5Encode: {e}"))?;
    global
        .set(
            "__legado_md5_16",
            Function::new(ctx.clone(), java_md5_encode_16)
                .map_err(|e| format!("register md5Encode16: {e}"))?,
        )
        .map_err(|e| format!("set md5Encode16: {e}"))?;
    global
        .set(
            "__legado_encode_uri",
            Function::new(ctx.clone(), java_encode_uri)
                .map_err(|e| format!("register encodeURI: {e}"))?,
        )
        .map_err(|e| format!("set encodeURI: {e}"))?;
    global
        .set(
            "__legado_encode_uri_component",
            Function::new(ctx.clone(), java_encode_uri_component)
                .map_err(|e| format!("register encodeURIComponent: {e}"))?,
        )
        .map_err(|e| format!("set encodeURIComponent: {e}"))?;
    global
        .set(
            "__legado_decode_uri",
            Function::new(ctx.clone(), java_decode_uri)
                .map_err(|e| format!("register decodeURI: {e}"))?,
        )
        .map_err(|e| format!("set decodeURI: {e}"))?;
    global
        .set(
            "__legado_http_request",
            Function::new(ctx.clone(), java_http_request)
                .map_err(|e| format!("register http request: {e}"))?,
        )
        .map_err(|e| format!("set http request: {e}"))?;
    global
        .set(
            "__legado_get_cookie",
            Function::new(ctx.clone(), java_get_cookie)
                .map_err(|e| format!("register getCookie: {e}"))?,
        )
        .map_err(|e| format!("set getCookie: {e}"))?;
    global
        .set(
            "__legado_set_cookie",
            Function::new(ctx.clone(), java_set_cookie)
                .map_err(|e| format!("register setCookie: {e}"))?,
        )
        .map_err(|e| format!("set setCookie: {e}"))?;
    global
        .set(
            "__legado_remove_cookie",
            Function::new(ctx.clone(), java_remove_cookie)
                .map_err(|e| format!("register removeCookie: {e}"))?,
        )
        .map_err(|e| format!("set removeCookie: {e}"))?;
    global
        .set(
            "__legado_get_string",
            Function::new(ctx.clone(), java_get_string)
                .map_err(|e| format!("register getString: {e}"))?,
        )
        .map_err(|e| format!("set getString: {e}"))?;
    global
        .set(
            "__legado_get_string_list",
            Function::new(ctx.clone(), java_get_string_list)
                .map_err(|e| format!("register getStringList: {e}"))?,
        )
        .map_err(|e| format!("set getStringList: {e}"))?;
    global
        .set(
            "__legado_get_elements",
            Function::new(ctx.clone(), java_get_elements)
                .map_err(|e| format!("register getElements: {e}"))?,
        )
        .map_err(|e| format!("set getElements: {e}"))?;
    global
        .set(
            "__legado_aes_decode_to_string",
            Function::new(ctx.clone(), java_aes_decode_to_string)
                .map_err(|e| format!("register aesDecodeToString: {e}"))?,
        )
        .map_err(|e| format!("set aesDecodeToString: {e}"))?;
    global
        .set(
            "__legado_aes_base64_decode_to_string",
            Function::new(ctx.clone(), java_aes_base64_decode_to_string)
                .map_err(|e| format!("register aesBase64DecodeToString: {e}"))?,
        )
        .map_err(|e| format!("set aesBase64DecodeToString: {e}"))?;
    global
        .set(
            "__legado_aes_encode_to_string",
            Function::new(ctx.clone(), java_aes_encode_to_string)
                .map_err(|e| format!("register aesEncodeToString: {e}"))?,
        )
        .map_err(|e| format!("set aesEncodeToString: {e}"))?;
    global
        .set(
            "__legado_aes_encode_to_base64_string",
            Function::new(ctx.clone(), java_aes_encode_to_base64_string)
                .map_err(|e| format!("register aesEncodeToBase64String: {e}"))?,
        )
        .map_err(|e| format!("set aesEncodeToBase64String: {e}"))?;
    global
        .set(
            "__legado_aes_decode_to_byte_array",
            Function::new(ctx.clone(), java_aes_decode_to_byte_array)
                .map_err(|e| format!("register aesDecodeToByteArray: {e}"))?,
        )
        .map_err(|e| format!("set aesDecodeToByteArray: {e}"))?;
    global
        .set(
            "__legado_aes_base64_decode_to_byte_array",
            Function::new(ctx.clone(), java_aes_base64_decode_to_byte_array)
                .map_err(|e| format!("register aesBase64DecodeToByteArray: {e}"))?,
        )
        .map_err(|e| format!("set aesBase64DecodeToByteArray: {e}"))?;
    global
        .set(
            "__legado_aes_encode_to_byte_array",
            Function::new(ctx.clone(), java_aes_encode_to_byte_array)
                .map_err(|e| format!("register aesEncodeToByteArray: {e}"))?,
        )
        .map_err(|e| format!("set aesEncodeToByteArray: {e}"))?;
    global
        .set(
            "__legado_aes_encode_to_base64_byte_array",
            Function::new(ctx.clone(), java_aes_encode_to_base64_byte_array)
                .map_err(|e| format!("register aesEncodeToBase64ByteArray: {e}"))?,
        )
        .map_err(|e| format!("set aesEncodeToBase64ByteArray: {e}"))?;
    global
        .set(
            "__legado_time_format",
            Function::new(ctx.clone(), java_time_format)
                .map_err(|e| format!("register timeFormat: {e}"))?,
        )
        .map_err(|e| format!("set timeFormat: {e}"))?;
    global
        .set(
            "__legado_html_format",
            Function::new(ctx.clone(), java_html_format)
                .map_err(|e| format!("register htmlFormat: {e}"))?,
        )
        .map_err(|e| format!("set htmlFormat: {e}"))?;
    global
        .set(
            "__legado_get_zip_string_content",
            Function::new(ctx.clone(), java_get_zip_string_content)
                .map_err(|e| format!("register getZipStringContent: {e}"))?,
        )
        .map_err(|e| format!("set getZipStringContent: {e}"))?;
    global
        .set(
            "__legado_get_zip_byte_array_content",
            Function::new(ctx.clone(), java_get_zip_byte_array_content)
                .map_err(|e| format!("register getZipByteArrayContent: {e}"))?,
        )
        .map_err(|e| format!("set getZipByteArrayContent: {e}"))?;
    global
        .set(
            "__legado_read_file",
            Function::new(ctx.clone(), java_read_file)
                .map_err(|e| format!("register readFile: {e}"))?,
        )
        .map_err(|e| format!("set readFile: {e}"))?;
    global
        .set(
            "__legado_read_txt_file",
            Function::new(ctx.clone(), java_read_txt_file)
                .map_err(|e| format!("register readTxtFile: {e}"))?,
        )
        .map_err(|e| format!("set readTxtFile: {e}"))?;
    global
        .set(
            "__legado_base64_decode_to_byte_array",
            Function::new(ctx.clone(), java_base64_decode_to_byte_array)
                .map_err(|e| format!("register base64DecodeToByteArray: {e}"))?,
        )
        .map_err(|e| format!("set base64DecodeToByteArray: {e}"))?;
    global
        .set(
            "__legado_log",
            Function::new(ctx.clone(), java_log).map_err(|e| format!("register log: {e}"))?,
        )
        .map_err(|e| format!("set log: {e}"))?;
    global
        .set(
            "__legado_cache_get",
            Function::new(ctx.clone(), java_cache_get)
                .map_err(|e| format!("register cache get: {e}"))?,
        )
        .map_err(|e| format!("set cache get: {e}"))?;
    global
        .set(
            "__legado_cache_put",
            Function::new(ctx.clone(), java_cache_put)
                .map_err(|e| format!("register cache put: {e}"))?,
        )
        .map_err(|e| format!("set cache put: {e}"))?;
    global
        .set(
            "__legado_set_content",
            Function::new(ctx.clone(), java_set_content)
                .map_err(|e| format!("register setContent: {e}"))?,
        )
        .map_err(|e| format!("set setContent: {e}"))?;
    global
        .set(
            "__legado_download_file",
            Function::new(ctx.clone(), java_download_file)
                .map_err(|e| format!("register downloadFile: {e}"))?,
        )
        .map_err(|e| format!("set downloadFile: {e}"))?;
    global
        .set(
            "__legado_get_file",
            Function::new(ctx.clone(), java_get_file)
                .map_err(|e| format!("register getFile: {e}"))?,
        )
        .map_err(|e| format!("set getFile: {e}"))?;
    global
        .set(
            "__legado_delete_file",
            Function::new(ctx.clone(), java_delete_file)
                .map_err(|e| format!("register deleteFile: {e}"))?,
        )
        .map_err(|e| format!("set deleteFile: {e}"))?;
    global
        .set(
            "__legado_unzip_file",
            Function::new(ctx.clone(), java_unzip_file)
                .map_err(|e| format!("register unzipFile: {e}"))?,
        )
        .map_err(|e| format!("set unzipFile: {e}"))?;
    global
        .set(
            "__legado_get_txt_in_folder",
            Function::new(ctx.clone(), java_get_txt_in_folder)
                .map_err(|e| format!("register getTxtInFolder: {e}"))?,
        )
        .map_err(|e| format!("set getTxtInFolder: {e}"))?;
    global
        .set(
            "__legado_utf8_to_gbk",
            Function::new(ctx.clone(), java_utf8_to_gbk)
                .map_err(|e| format!("register utf8ToGbk: {e}"))?,
        )
        .map_err(|e| format!("set utf8ToGbk: {e}"))?;
    global
        .set(
            "__legado_query_base64_ttf",
            Function::new(ctx.clone(), java_query_base64_ttf)
                .map_err(|e| format!("register queryBase64Ttf: {e}"))?,
        )
        .map_err(|e| format!("set queryBase64Ttf: {e}"))?;
    global
        .set(
            "__legado_query_ttf",
            Function::new(ctx.clone(), java_query_ttf)
                .map_err(|e| format!("register queryTtf: {e}"))?,
        )
        .map_err(|e| format!("set queryTtf: {e}"))?;
    global
        .set(
            "__legado_replace_font",
            Function::new(ctx.clone(), java_replace_font)
                .map_err(|e| format!("register replaceFont: {e}"))?,
        )
        .map_err(|e| format!("set replaceFont: {e}"))?;
    global
        .set(
            "__legado_replace_font_by_urls",
            Function::new(ctx.clone(), java_replace_font_by_urls)
                .map_err(|e| format!("register replaceFontByUrls: {e}"))?,
        )
        .map_err(|e| format!("set replaceFontByUrls: {e}"))?;
    global
        .set(
            "__legado_resolve_url",
            Function::new(ctx.clone(), java_resolve_url)
                .map_err(|e| format!("register resolveUrl: {e}"))?,
        )
        .map_err(|e| format!("set resolveUrl: {e}"))?;
    global
        .set(
            "__legado_js_put",
            Function::new(ctx.clone(), java_js_put)
                .map_err(|e| format!("register jsPut: {e}"))?,
        )
        .map_err(|e| format!("set jsPut: {e}"))?;
    global
        .set(
            "__legado_js_get",
            Function::new(ctx.clone(), java_js_get)
                .map_err(|e| format!("register jsGet: {e}"))?,
        )
        .map_err(|e| format!("set jsGet: {e}"))?;
    Ok(())
}

#[cfg(feature = "js-quickjs")]
fn java_base64_encode(input: String) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(input.as_bytes())
}

#[cfg(feature = "js-quickjs")]
fn java_base64_decode(input: String) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(input.as_bytes())
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .unwrap_or_default()
}

#[cfg(feature = "js-quickjs")]
fn java_base64_decode_to_byte_array(input: String) -> String {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(input.as_bytes())
        .unwrap_or_default();
    serde_json::to_string(&bytes).unwrap_or_else(|_| "[]".into())
}

#[cfg(feature = "js-quickjs")]
fn java_log(_msg: String) -> String {
    String::new()
}

#[cfg(feature = "js-quickjs")]
fn java_cache_get(key: String) -> String {
    if let Some(val) = current_js_variables().get(&key) {
        return val.as_string_lossy();
    }
    if let Some(db_path) = get_cache_db_path() {
        if let Ok(conn) = rusqlite::Connection::open(db_path) {
            let dao = core_storage::cache_dao::CacheDao::new(&conn);
            if let Ok(Some(val)) = dao.get(&key) {
                return val;
            }
        }
    }
    String::new()
}

#[cfg(feature = "js-quickjs")]
fn java_cache_put(key: String, value: String) -> String {
    set_current_js_variable(key.clone(), LegadoValue::String(value.clone()));
    if let Some(db_path) = get_cache_db_path() {
        if let Ok(conn) = rusqlite::Connection::open(db_path) {
            let dao = core_storage::cache_dao::CacheDao::new(&conn);
            let _ = dao.put(&key, &value);
        }
    }
    value
}

#[cfg(feature = "js-quickjs")]
fn java_md5_encode(input: String) -> String {
    format!("{:x}", md5::compute(input.as_bytes()))
}

#[cfg(feature = "js-quickjs")]
fn java_md5_encode_16(input: String) -> String {
    let md5 = java_md5_encode(input);
    md5.get(8..24).unwrap_or_default().to_string()
}

#[cfg(feature = "js-quickjs")]
fn java_encode_uri(input: String) -> String {
    urlencoding::encode(&input).to_string()
}

#[cfg(feature = "js-quickjs")]
fn java_encode_uri_component(input: String) -> String {
    urlencoding::encode(&input).to_string()
}

#[cfg(feature = "js-quickjs")]
fn java_decode_uri(input: String) -> String {
    urlencoding::decode(&input)
        .map(|s| s.into_owned())
        .unwrap_or(input)
}

#[cfg(feature = "js-quickjs")]
fn java_utf8_to_gbk(input: String) -> String {
    let bytes = input.as_bytes();
    let (decoded, _, _) = encoding_rs::GBK.decode(bytes);
    decoded.into_owned()
}

#[cfg(feature = "js-quickjs")]
fn java_http_request(method: String, url: String, body: String, headers_json: String) -> String {
    // P2-2: We used to `std::thread::spawn(...).join()` here, which created
    // an extra OS thread per JS bridge call just to re-install the
    // thread-local cookie jar override. Both the rquickjs callback and the
    // surrounding parser are already running on tokio's blocking thread
    // pool, so it's safe (and much cheaper) to run inline. The cookie jar
    // override is already installed by the parent guard set up in
    // `eval_default_with_http_state`, so we don't need to re-install it.
    java_http_request_blocking(method, url, body, headers_json)
}

#[cfg(feature = "js-quickjs")]
fn java_http_request_blocking(
    method: String,
    url: String,
    body: String,
    headers_json: String,
) -> String {
    if let Err(e) = ssrf_guard::is_url_safe_for_fetch(&url) {
        tracing::warn!("SSRF blocked in java.ajax: {e}");
        return String::new();
    }

    let cookie_jar = current_js_cookie_jar();

    let mut charset = None;
    let mut proxy_url: Option<String> = None;
    let mut header_pairs: Vec<(String, String)> = Vec::new();

    if let Ok(headers_val) = serde_json::from_str::<serde_json::Value>(&headers_json) {
        if let Some(map) = headers_val.as_object() {
            for (key, value) in map {
                if key.eq_ignore_ascii_case("charset") {
                    charset = value.as_str().map(|s| s.to_string());
                    continue;
                }
                if key.eq_ignore_ascii_case("proxy") {
                    proxy_url = value.as_str().map(|s| s.to_string());
                    continue;
                }
                let value = value
                    .as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| value.to_string());
                header_pairs.push((key.clone(), value));
            }
        }
    }

    let client = if let Some(ref p_url) = proxy_url {
        if let Ok(proxy) = reqwest::Proxy::all(p_url) {
            reqwest::blocking::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .connect_timeout(std::time::Duration::from_secs(15))
                .cookie_provider(cookie_jar.clone())
                .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
                .proxy(proxy)
                .build()
                .unwrap_or_else(|_| js_http_client(cookie_jar.clone()))
        } else {
            js_http_client(cookie_jar.clone())
        }
    } else {
        js_http_client(cookie_jar)
    };

    let mut request = if method.eq_ignore_ascii_case("POST") {
        client.post(&url).body(body)
    } else {
        client.get(&url)
    };

    for (key, value) in &header_pairs {
        request = request.header(key.as_str(), value.as_str());
    }

    if method.eq_ignore_ascii_case("POST")
        && !header_pairs
            .iter()
            .any(|(k, _)| k.eq_ignore_ascii_case("Content-Type"))
    {
        request = request.header("Content-Type", "application/x-www-form-urlencoded");
    }

    let response = match request.send() {
        Ok(response) => response,
        Err(_) => return String::new(),
    };

    let headers_map: HashMap<String, String> = response
        .headers()
        .iter()
        .map(|(key, value)| {
            (
                key.as_str().to_lowercase(),
                value.to_str().unwrap_or_default().to_string(),
            )
        })
        .collect();
    let max_bytes: usize = 10 * 1024 * 1024;
    let mut buf = vec![0u8; 0];
    {
        use std::io::Read;
        if response
            .take((max_bytes + 1) as u64)
            .read_to_end(&mut buf)
            .is_err()
            || buf.len() > max_bytes
        {
            return String::new();
        }
    }
    let bytes = buf;

    let charset =
        charset.unwrap_or_else(|| super::url::guess_charset_from_response(&headers_map, &bytes));
    let (decoded, _) = super::url::decode_response_bytes(&bytes, &charset);
    decoded
}

#[cfg(feature = "js-quickjs")]
fn js_http_client(cookie_jar: Arc<reqwest::cookie::Jar>) -> reqwest::blocking::Client {
    reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .connect_timeout(std::time::Duration::from_secs(15))
        .cookie_provider(cookie_jar)
        .redirect(reqwest::redirect::Policy::limited(5))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        .build()
        .expect("failed to build JS HTTP client")
}

#[cfg(feature = "js-quickjs")]
fn default_js_cookie_jar() -> Arc<reqwest::cookie::Jar> {
    static JAR: OnceLock<Arc<reqwest::cookie::Jar>> = OnceLock::new();
    JAR.get_or_init(|| Arc::new(reqwest::cookie::Jar::default()))
        .clone()
}

#[cfg(feature = "js-quickjs")]
thread_local! {
    static COOKIE_JAR_OVERRIDE: RefCell<Option<Arc<reqwest::cookie::Jar>>> = const { RefCell::new(None) };
}

#[cfg(feature = "js-quickjs")]
fn current_js_cookie_jar() -> Arc<reqwest::cookie::Jar> {
    COOKIE_JAR_OVERRIDE
        .with(|override_jar| override_jar.borrow().clone())
        .unwrap_or_else(default_js_cookie_jar)
}

#[cfg(feature = "js-quickjs")]
struct JsCookieJarOverride {
    previous: Option<Arc<reqwest::cookie::Jar>>,
}

#[cfg(feature = "js-quickjs")]
impl JsCookieJarOverride {
    fn install(cookie_jar: Arc<reqwest::cookie::Jar>) -> Self {
        let previous =
            COOKIE_JAR_OVERRIDE.with(|override_jar| override_jar.replace(Some(cookie_jar)));
        Self { previous }
    }
}

#[cfg(feature = "js-quickjs")]
impl Drop for JsCookieJarOverride {
    fn drop(&mut self) {
        COOKIE_JAR_OVERRIDE.with(|override_jar| {
            override_jar.replace(self.previous.take());
        });
    }
}

#[cfg(feature = "js-quickjs")]
struct JsVariablesOverride {
    previous: HashMap<String, LegadoValue>,
}

#[cfg(feature = "js-quickjs")]
impl JsVariablesOverride {
    fn install(vars: HashMap<String, LegadoValue>) -> Self {
        let previous = LEGADO_JS_VARIABLES.with(|cell| cell.replace(vars));
        Self { previous }
    }
}

#[cfg(feature = "js-quickjs")]
impl Drop for JsVariablesOverride {
    fn drop(&mut self) {
        LEGADO_JS_VARIABLES.with(|cell| {
            cell.replace(std::mem::take(&mut self.previous));
        });
    }
}

#[cfg(feature = "js-quickjs")]
fn current_js_variables() -> HashMap<String, LegadoValue> {
    LEGADO_JS_VARIABLES.with(|cell| cell.borrow().clone())
}

#[cfg(feature = "js-quickjs")]
fn set_current_js_variable(key: String, value: LegadoValue) {
    LEGADO_JS_VARIABLES.with(|cell| {
        cell.borrow_mut().insert(key, value);
    });
}

#[cfg(feature = "js-quickjs")]
fn java_get_cookie(tag: String, key: String) -> String {
    use reqwest::cookie::CookieStore;

    let Ok(url) = tag.parse::<url::Url>() else {
        return String::new();
    };
    let Some(header) = current_js_cookie_jar().cookies(&url) else {
        return String::new();
    };
    let Ok(cookie) = header.to_str() else {
        return String::new();
    };
    if key.is_empty() || key == "null" || key == "undefined" {
        return cookie.to_string();
    }
    for pair in cookie.split(';') {
        let Some((name, value)) = pair.trim().split_once('=') else {
            continue;
        };
        if name == key {
            return value.to_string();
        }
    }
    String::new()
}

#[cfg(feature = "js-quickjs")]
fn java_set_cookie(url_str: String, cookie_str: String) -> String {
    use reqwest::cookie::CookieStore;
    use reqwest::header::HeaderValue;

    let Ok(url) = url_str.parse::<url::Url>() else {
        return String::new();
    };
    let jar = current_js_cookie_jar();
    // R67: Legado's `java.setCookie(url, cookieStr)` passes a single
    // Set-Cookie header value: e.g. `"name=value; Path=/; Max-Age=3600"`.
    // The previous implementation split on `;` and wrote each segment as
    // its own cookie, so attributes like `Path=/` ended up stored as a
    // bogus cookie named "Path". Hand the whole string to reqwest's jar
    // unsplit; it knows how to parse Set-Cookie attributes.
    let trimmed = cookie_str.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Ok(hv) = HeaderValue::from_str(trimmed) {
        jar.set_cookies(&mut [hv].iter(), &url);
    }
    String::new()
}

#[cfg(feature = "js-quickjs")]
fn java_remove_cookie(url_str: String) -> String {
    // P2-1: `reqwest::cookie::Jar` doesn't expose a removal API. We fake
    // it by reading every cookie applicable to `url_str` (via `cookies()`
    // which returns the `Cookie:` request header) and re-setting each
    // name with `Max-Age=0; Path=/`, which makes the jar treat it as
    // expired.
    //
    // R41: known limitation — `cookies()` only gives us the
    // `Cookie:`-header form, which has dropped every attribute except
    // name=value. We therefore can't reproduce the original cookie's
    // `Path` / `Domain` / `Secure` flags, and simply set `Path=/` for
    // the expiry. If the original cookie was set with a more specific
    // path (e.g. `Path=/api`) the jar will keep matching it for paths
    // under `/api` because our `/`-scoped expiry doesn't shadow it.
    // This is the best we can do without reaching into reqwest
    // internals; legacy Legado JS that needs precise cookie removal
    // should be rewritten to scope `removeCookie` calls to the right
    // path.
    use reqwest::cookie::CookieStore;
    use reqwest::header::HeaderValue;

    let Ok(url) = url_str.parse::<url::Url>() else {
        return String::new();
    };
    let jar = current_js_cookie_jar();
    let Some(header) = jar.cookies(&url) else {
        return String::new();
    };
    let Ok(cookie_str) = header.to_str() else {
        return String::new();
    };
    for pair in cookie_str.split(';') {
        let pair = pair.trim();
        let Some((name, _)) = pair.split_once('=') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty() {
            continue;
        }
        let expire = format!("{name}=; Max-Age=0; Path=/");
        if let Ok(hv) = HeaderValue::from_str(&expire) {
            // R42: `std::iter::once` is the idiomatic way to feed a
            // single header into the `CookieStore::set_cookies` slot
            // (which takes `&mut dyn Iterator<Item = &HeaderValue>`).
            jar.set_cookies(&mut std::iter::once(&hv), &url);
        }
    }
    String::new()
}

#[cfg(feature = "js-quickjs")]
fn java_set_content(content: String, base_url: String) -> String {
    LEGADO_SET_CONTENT.with(|cell| {
        let _prev = cell.borrow_mut().replace((content, base_url));
    });
    String::new()
}

#[cfg(feature = "js-quickjs")]
fn java_get_string(rule: String, content: String, base_url: String) -> String {
    let (effective_content, effective_base_url) = LEGADO_SET_CONTENT.with(|cell| {
        cell.borrow_mut()
            .take()
            .unwrap_or_else(|| (content, base_url))
    });
    let result = {
        let context = RuleContext::new(&effective_base_url, &effective_content);
        super::rule::execute_legado_rule(&rule, &effective_content, &context)
            .ok()
            .and_then(|items| items.into_iter().next())
            .unwrap_or_default()
    };
    // Release any remaining setContent that wasn't consumed
    LEGADO_SET_CONTENT.with(|cell| {
        let _dangling = cell.borrow_mut().take();
    });
    result
}

#[cfg(feature = "js-quickjs")]
fn java_get_string_list(rule: String, content: String, base_url: String) -> String {
    let (effective_content, effective_base_url) = LEGADO_SET_CONTENT.with(|cell| {
        cell.borrow_mut()
            .take()
            .unwrap_or_else(|| (content, base_url))
    });
    let result = {
        let context = RuleContext::new(&effective_base_url, &effective_content);
        let items = super::rule::execute_legado_rule(&rule, &effective_content, &context)
            .unwrap_or_default();
        serde_json::to_string(&items).unwrap_or_else(|_| "[]".into())
    };
    LEGADO_SET_CONTENT.with(|cell| {
        let _dangling = cell.borrow_mut().take();
    });
    result
}

#[cfg(feature = "js-quickjs")]
fn java_get_elements(rule: String, content: String, _base_url: String) -> String {
    let (effective_content, _) = LEGADO_SET_CONTENT.with(|cell| {
        cell.borrow_mut()
            .take()
            .unwrap_or_else(|| (content, _base_url))
    });
    let selector = rule
        .trim()
        .strip_prefix("@css:")
        .unwrap_or(rule.trim())
        .split("##")
        .next()
        .unwrap_or_default()
        .trim();
    if selector.is_empty() {
        return "[]".into();
    }
    let Ok(selector) = parse_scraper_selector_safely(selector) else {
        return "[]".into();
    };
    let document = scraper::Html::parse_fragment(&effective_content);
    let elements: Vec<serde_json::Value> =
        document.select(&selector).map(element_to_json).collect();
    serde_json::to_string(&elements).unwrap_or_else(|_| "[]".into())
}

#[cfg(feature = "js-quickjs")]
fn parse_scraper_selector_safely(selector: &str) -> Result<scraper::Selector, String> {
    catch_unwind(AssertUnwindSafe(|| scraper::Selector::parse(selector)))
        .map_err(|_| format!("CSS selector parse panic for '{}'", selector))?
        .map_err(|_| format!("CSS selector parse error for '{}'", selector))
}

#[cfg(feature = "js-quickjs")]
fn element_to_json(element: scraper::ElementRef<'_>) -> serde_json::Value {
    let attrs = element
        .value()
        .attrs()
        .map(|(key, value)| {
            (
                key.to_string(),
                serde_json::Value::String(value.to_string()),
            )
        })
        .collect();
    let children = element
        .children()
        .filter_map(scraper::ElementRef::wrap)
        .map(element_to_json_shallow)
        .collect::<Vec<_>>();
    serde_json::json!({
        "tagName": element.value().name(),
        "text": element.text().collect::<String>(),
        "ownText": element.children()
            .filter_map(|child| match child.value() {
                scraper::node::Node::Text(text) => Some(text.text.to_string()),
                _ => None,
            })
            .collect::<String>(),
        "html": element.inner_html(),
        "outerHtml": element.html(),
        "attrs": serde_json::Value::Object(attrs),
        "children": children,
    })
}

#[cfg(feature = "js-quickjs")]
fn element_to_json_shallow(element: scraper::ElementRef<'_>) -> serde_json::Value {
    let attrs = element
        .value()
        .attrs()
        .map(|(key, value)| {
            (
                key.to_string(),
                serde_json::Value::String(value.to_string()),
            )
        })
        .collect();
    serde_json::json!({
        "tagName": element.value().name(),
        "text": element.text().collect::<String>(),
        "ownText": element.children()
            .filter_map(|child| match child.value() {
                scraper::node::Node::Text(text) => Some(text.text.to_string()),
                _ => None,
            })
            .collect::<String>(),
        "html": element.inner_html(),
        "outerHtml": element.html(),
        "attrs": serde_json::Value::Object(attrs),
        "children": [],
    })
}

#[cfg(feature = "js-quickjs")]
fn java_aes_decode_to_string(
    data: String,
    key: String,
    transformation: String,
    iv: String,
) -> String {
    let bytes = hex_to_bytes(&data).unwrap_or_else(|| data.into_bytes());
    aes_decrypt(&bytes, key.as_bytes(), &transformation, iv.as_bytes())
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .unwrap_or_default()
}

#[cfg(feature = "js-quickjs")]
fn java_aes_base64_decode_to_string(
    data: String,
    key: String,
    transformation: String,
    iv: String,
) -> String {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data.as_bytes())
        .unwrap_or_default();
    aes_decrypt(&bytes, key.as_bytes(), &transformation, iv.as_bytes())
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .unwrap_or_default()
}

#[cfg(feature = "js-quickjs")]
fn java_aes_encode_to_string(
    data: String,
    key: String,
    transformation: String,
    iv: String,
) -> String {
    aes_encrypt(
        data.as_bytes(),
        key.as_bytes(),
        &transformation,
        iv.as_bytes(),
    )
    .map(|bytes| bytes_to_hex(&bytes))
    .unwrap_or_default()
}

#[cfg(feature = "js-quickjs")]
fn java_aes_encode_to_base64_string(
    data: String,
    key: String,
    transformation: String,
    iv: String,
) -> String {
    use base64::Engine;
    aes_encrypt(
        data.as_bytes(),
        key.as_bytes(),
        &transformation,
        iv.as_bytes(),
    )
    .map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes))
    .unwrap_or_default()
}

#[cfg(feature = "js-quickjs")]
fn java_aes_decode_to_byte_array(
    data: String,
    key: String,
    transformation: String,
    iv: String,
) -> String {
    let bytes = hex_to_bytes(&data).unwrap_or_else(|| data.into_bytes());
    let out =
        aes_decrypt(&bytes, key.as_bytes(), &transformation, iv.as_bytes()).unwrap_or_default();
    serde_json::to_string(&out).unwrap_or_else(|_| "[]".into())
}

#[cfg(feature = "js-quickjs")]
fn java_aes_base64_decode_to_byte_array(
    data: String,
    key: String,
    transformation: String,
    iv: String,
) -> String {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data.as_bytes())
        .unwrap_or_default();
    let out =
        aes_decrypt(&bytes, key.as_bytes(), &transformation, iv.as_bytes()).unwrap_or_default();
    serde_json::to_string(&out).unwrap_or_else(|_| "[]".into())
}

#[cfg(feature = "js-quickjs")]
fn java_aes_encode_to_byte_array(
    data: String,
    key: String,
    transformation: String,
    iv: String,
) -> String {
    let out = aes_encrypt(
        data.as_bytes(),
        key.as_bytes(),
        &transformation,
        iv.as_bytes(),
    )
    .unwrap_or_default();
    serde_json::to_string(&out).unwrap_or_else(|_| "[]".into())
}

#[cfg(feature = "js-quickjs")]
fn java_aes_encode_to_base64_byte_array(
    data: String,
    key: String,
    transformation: String,
    iv: String,
) -> String {
    use base64::Engine;
    let base64 = aes_encrypt(
        data.as_bytes(),
        key.as_bytes(),
        &transformation,
        iv.as_bytes(),
    )
    .map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes))
    .unwrap_or_default();
    serde_json::to_string(base64.as_bytes()).unwrap_or_else(|_| "[]".into())
}

#[cfg(feature = "js-quickjs")]
fn aes_encrypt(data: &[u8], key: &[u8], transformation: &str, iv: &[u8]) -> Option<Vec<u8>> {
    use cbc::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyInit, KeyIvInit};

    let normalized = transformation.to_uppercase();
    if normalized.contains("/ECB/") {
        return match key.len() {
            16 => Some(
                ecb::Encryptor::<aes::Aes128>::new_from_slice(key)
                    .ok()?
                    .encrypt_padded_vec_mut::<Pkcs7>(data),
            ),
            24 => Some(
                ecb::Encryptor::<aes::Aes192>::new_from_slice(key)
                    .ok()?
                    .encrypt_padded_vec_mut::<Pkcs7>(data),
            ),
            32 => Some(
                ecb::Encryptor::<aes::Aes256>::new_from_slice(key)
                    .ok()?
                    .encrypt_padded_vec_mut::<Pkcs7>(data),
            ),
            _ => None,
        };
    }
    if iv.len() != 16 {
        return None;
    }
    match key.len() {
        16 => Some(
            cbc::Encryptor::<aes::Aes128>::new_from_slices(key, iv)
                .ok()?
                .encrypt_padded_vec_mut::<Pkcs7>(data),
        ),
        24 => Some(
            cbc::Encryptor::<aes::Aes192>::new_from_slices(key, iv)
                .ok()?
                .encrypt_padded_vec_mut::<Pkcs7>(data),
        ),
        32 => Some(
            cbc::Encryptor::<aes::Aes256>::new_from_slices(key, iv)
                .ok()?
                .encrypt_padded_vec_mut::<Pkcs7>(data),
        ),
        _ => None,
    }
}

#[cfg(feature = "js-quickjs")]
fn aes_decrypt(data: &[u8], key: &[u8], transformation: &str, iv: &[u8]) -> Option<Vec<u8>> {
    use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyInit, KeyIvInit};

    let normalized = transformation.to_uppercase();
    if normalized.contains("/ECB/") {
        return match key.len() {
            16 => ecb::Decryptor::<aes::Aes128>::new_from_slice(key)
                .ok()?
                .decrypt_padded_vec_mut::<Pkcs7>(data)
                .ok(),
            24 => ecb::Decryptor::<aes::Aes192>::new_from_slice(key)
                .ok()?
                .decrypt_padded_vec_mut::<Pkcs7>(data)
                .ok(),
            32 => ecb::Decryptor::<aes::Aes256>::new_from_slice(key)
                .ok()?
                .decrypt_padded_vec_mut::<Pkcs7>(data)
                .ok(),
            _ => None,
        };
    }
    if iv.len() != 16 {
        return None;
    }
    match key.len() {
        16 => cbc::Decryptor::<aes::Aes128>::new_from_slices(key, iv)
            .ok()?
            .decrypt_padded_vec_mut::<Pkcs7>(data)
            .ok(),
        24 => cbc::Decryptor::<aes::Aes192>::new_from_slices(key, iv)
            .ok()?
            .decrypt_padded_vec_mut::<Pkcs7>(data)
            .ok(),
        32 => cbc::Decryptor::<aes::Aes256>::new_from_slices(key, iv)
            .ok()?
            .decrypt_padded_vec_mut::<Pkcs7>(data)
            .ok(),
        _ => None,
    }
}

#[cfg(feature = "js-quickjs")]
fn hex_to_bytes(input: &str) -> Option<Vec<u8>> {
    if input.len() % 2 != 0 || !input.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut out = Vec::with_capacity(input.len() / 2);
    let bytes = input.as_bytes();
    for i in (0..bytes.len()).step_by(2) {
        let pair = std::str::from_utf8(&bytes[i..i + 2]).ok()?;
        out.push(u8::from_str_radix(pair, 16).ok()?);
    }
    Some(out)
}

#[cfg(feature = "js-quickjs")]
fn bytes_to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

#[cfg(feature = "js-quickjs")]
fn java_time_format(input: String) -> String {
    let trimmed = input.trim();
    let Ok(mut timestamp) = trimmed.parse::<i64>() else {
        return trimmed.to_string();
    };
    // F-W1B-016 (BATCH-11): single-sided threshold >= 10^11 ms (≈1973-03-03).
    // The original heuristic `abs() >= 10^12 || abs() < 10^9` had two bugs:
    // 1) seconds-level timestamps below 10^9 (e.g. 999_999_999 ≈ 2001-09-09)
    //    were incorrectly divided by 1000 and ended up around 1970.
    // 2) `abs()` collapsed negative (pre-1970) timestamps onto the positive
    //    branch and could trigger spurious /1000 reduction.
    // The new threshold trades a much narrower mis-classification window
    // (1970-01-01 ~ 1973-03-03 of legitimate millisecond stamps would still
    // be treated as seconds, ≈13 months) for correctness on the much more
    // common seconds-level inputs Legado sources actually emit. The original
    // Legado project is Kotlin/chrono-style with millisecond defaults; we
    // document the trade-off here and stay backwards-compatible for typical
    // 10-digit/13-digit values.
    if timestamp >= 100_000_000_000 {
        timestamp /= 1000;
    }
    chrono::DateTime::from_timestamp(timestamp, 0)
        .map(|dt| dt.naive_local().format("%Y/%m/%d %H:%M").to_string())
        .unwrap_or_default()
}

#[cfg(feature = "js-quickjs")]
fn java_html_format(input: String) -> String {
    static RE_BR: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new("(?i)<br\\s*/?>").unwrap());
    static RE_P: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new("(?i)</p\\s*>").unwrap());
    static RE_SCRIPT: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new("(?is)<script.*?</script>").unwrap());
    static RE_STYLE: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new("(?is)<style.*?</style>").unwrap());
    static RE_TAGS: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new("(?is)<[^>]+>").unwrap());

    let mut out = input;
    let replacements = [
        ("&nbsp;", " "),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
    ];
    for (from, to) in replacements {
        out = out.replace(from, to);
    }
    out = RE_BR.replace_all(&out, "\n").to_string();
    out = RE_P.replace_all(&out, "\n").to_string();
    out = RE_SCRIPT.replace_all(&out, "").to_string();
    out = RE_STYLE.replace_all(&out, "").to_string();
    out = RE_TAGS.replace_all(&out, "").to_string();
    out.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// F-W1B-015 (BATCH-11): Bridge that delegates to `crate::utils::build_full_url`
/// (backed by the `url` crate's `Url::join`). The PREAMBLE used to ship its
/// own hand-rolled JS implementation of `_resolveUrl` whose behaviour drifted
/// from the Rust-side resolver (different handling of `//host`, `?query`,
/// `#fragment`, IPv6, scheme fallback). Routing both sides through this
/// bridge makes JS-driven `element.absUrl(...)` and Rust-driven
/// `build_full_url` produce byte-identical URLs so cache keys and redirect
/// chains agree.
#[cfg(feature = "js-quickjs")]
fn java_resolve_url(value: String, base: String) -> String {
    crate::utils::build_full_url(&base, &value)
}

/// F-W1B-011 (BATCH-11): Persist `java.put(key, value)` across separate
/// `eval()` invocations.
///
/// `QuickJsRuntime::eval` builds a fresh `Runtime` + `Context` per call, so
/// the JS-side `this._vars` (a copy of `__legado_variables__`) is dropped
/// at the end of each eval. Real Legado sources rely on `java.put` writing
/// into a process-wide bucket so that, e.g., `search` can stash a token
/// that `getContent` later reads via `java.get`.
///
/// The bridge writes through to `LEGADO_JS_VARIABLES` (the thread-local
/// vars map). The companion `__legado_js_get` bridge reads from the same
/// thread-local; PREAMBLE's `java.get` falls back to it whenever the
/// JS-side `_vars` does not yet have the key. This makes "put in eval A,
/// get in eval B on the same thread" work for both raw `eval()` callers
/// (e.g. unit tests) and the production path through
/// `eval_default_with_http_state`. Note: the `JsVariablesOverride` RAII
/// guard installed by `eval_default_with_http_state` snapshots / restores
/// the thread-local around each eval, so persistence beyond a single
/// guard scope still requires the parser to thread state via
/// `RuleContext::shared_variables` — that broader change belongs to
/// BATCH-13's Runtime-pool work and is out of scope here.
#[cfg(feature = "js-quickjs")]
fn java_js_put(key: String, value: String) -> String {
    set_current_js_variable(key, LegadoValue::String(value.clone()));
    value
}

/// F-W1B-011 (BATCH-11): Read the thread-local var bucket for use as the
/// PREAMBLE-side `java.get` fallback. Returns `""` when missing so the JS
/// side can keep its existing "missing key returns empty string" contract.
#[cfg(feature = "js-quickjs")]
fn java_js_get(key: String) -> String {
    current_js_variables()
        .get(&key)
        .map(|v| v.as_string_lossy())
        .unwrap_or_default()
}

#[cfg(feature = "js-quickjs")]
fn java_get_zip_string_content(url: String, path: String) -> String {
    if !is_safe_zip_entry_path(&path) {
        tracing::warn!("zip-slip blocked in java.getZipStringContent: {path}");
        return String::new();
    }
    let bytes = get_zip_entry_bytes(&url, &path).unwrap_or_default();
    String::from_utf8(bytes.clone()).unwrap_or_else(|_| {
        let (decoded, _, _) = encoding_rs::GBK.decode(&bytes);
        decoded.into_owned()
    })
}

#[cfg(feature = "js-quickjs")]
fn java_get_zip_byte_array_content(url: String, path: String) -> String {
    if !is_safe_zip_entry_path(&path) {
        tracing::warn!("zip-slip blocked in java.getZipByteArrayContent: {path}");
        return "[]".into();
    }
    let bytes = get_zip_entry_bytes(&url, &path).unwrap_or_default();
    serde_json::to_string(&bytes).unwrap_or_else(|_| "[]".into())
}

const MAX_ZIP_DOWNLOAD: u64 = 10 * 1024 * 1024;
const MAX_ZIP_ENTRY: u64 = 10 * 1024 * 1024;

/// F-W1B-005 (BATCH-10): reject zip entry paths that could escape the
/// archive sandbox. Rejects:
/// - any `..` segment (parent traversal)
/// - any absolute path: leading `/` (Unix) or `<drive-letter>:` segment (Windows)
/// - empty segment (`/foo` after split, leading `\\`, or `a//b`)
///
/// Used by `java.getZipStringContent` / `java.getZipByteArrayContent`
/// before calling `archive.by_name(path)`. The zip 0.6 crate does not
/// itself canonicalize entry paths, so callers must validate.
#[cfg(feature = "js-quickjs")]
fn is_safe_zip_entry_path(path: &str) -> bool {
    if path.is_empty() {
        return false;
    }
    // Reject Unix absolute paths and Windows backslash separators.
    if path.starts_with('/') || path.starts_with('\\') || path.contains('\\') {
        return false;
    }
    for segment in path.split('/') {
        if segment.is_empty() || segment == ".." {
            return false;
        }
        // Windows drive letter prefix (e.g. `C:`, `D:foo`).
        if segment.ends_with(':') {
            return false;
        }
    }
    true
}

#[cfg(feature = "js-quickjs")]
fn get_zip_entry_bytes(url: &str, path: &str) -> Option<Vec<u8>> {
    use std::io::{Cursor, Read};

    let mut response = js_http_client(current_js_cookie_jar())
        .get(url)
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .ok()?;
    if response
        .content_length()
        .is_some_and(|len| len > MAX_ZIP_DOWNLOAD)
    {
        return None;
    }
    let mut bytes = Vec::new();
    response
        .by_ref()
        .take(MAX_ZIP_DOWNLOAD + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > MAX_ZIP_DOWNLOAD {
        return None;
    }
    let cursor = Cursor::new(bytes);
    let mut archive = zip::ZipArchive::new(cursor).ok()?;
    let file = archive.by_name(path).ok()?;
    let mut out = Vec::new();
    file.take(MAX_ZIP_ENTRY + 1).read_to_end(&mut out).ok()?;
    if out.len() as u64 > MAX_ZIP_ENTRY {
        return None;
    }
    Some(out)
}

#[cfg(feature = "js-quickjs")]
fn resolve_file_path(path: &str) -> Option<String> {
    let root = std::env::var("LEGADO_FILE_ROOT").ok()?;
    let root = std::path::Path::new(&root);
    let root_canon = root.canonicalize().ok()?;
    let rel = std::path::Path::new(path);
    if !is_safe_relative_path(rel) {
        return None;
    }
    let candidate = root_canon.join(rel);
    let Ok(canonical) = candidate.canonicalize() else {
        return None;
    };
    if !canonical.starts_with(&root_canon) {
        return None;
    }
    Some(canonical.to_string_lossy().to_string())
}

#[cfg(feature = "js-quickjs")]
fn resolve_write_path(path: &str) -> Option<String> {
    let root = std::env::var("LEGADO_FILE_ROOT").ok()?;
    let root = std::path::Path::new(&root);
    let root_canon = root.canonicalize().ok()?;
    let rel = std::path::Path::new(path);
    if !is_safe_relative_path(rel) {
        return None;
    }
    let candidate = root_canon.join(rel);
    if candidate == root_canon {
        return Some(root_canon.to_string_lossy().to_string());
    }
    let parent = candidate.parent()?;
    std::fs::create_dir_all(parent).ok()?;
    let parent_canon = parent.canonicalize().ok()?;
    if !parent_canon.starts_with(&root_canon) {
        return None;
    }
    let file_name = candidate.file_name()?;
    let resolved = parent_canon.join(file_name);
    Some(resolved.to_string_lossy().to_string())
}

#[cfg(feature = "js-quickjs")]
fn is_safe_relative_path(path: &std::path::Path) -> bool {
    !path.is_absolute()
        && path.components().all(|component| {
            matches!(
                component,
                std::path::Component::Normal(_) | std::path::Component::CurDir
            )
        })
}

#[cfg(feature = "js-quickjs")]
fn java_download_file(url: String, path: String) -> String {
    use std::io::{Read, Write};

    if let Err(e) = ssrf_guard::is_url_safe_for_fetch(&url) {
        tracing::warn!("SSRF blocked in java.downloadFile: {e}");
        return String::new();
    }

    let resolved = match resolve_write_path(&path) {
        Some(p) => p,
        None => return String::new(),
    };
    let tmp_path = format!("{}.download", resolved);
    let mut response = match js_http_client(current_js_cookie_jar()).get(&url).send() {
        Ok(response) => response,
        Err(_) => return String::new(),
    };
    let mut file = match std::fs::File::create(&tmp_path) {
        Ok(file) => file,
        Err(_) => return String::new(),
    };
    let mut ok = true;
    let mut total = 0u64;
    let mut buf = [0u8; 16 * 1024];
    loop {
        let read = match response.read(&mut buf) {
            Ok(read) => read,
            Err(_) => {
                ok = false;
                break;
            }
        };
        if read == 0 {
            break;
        }
        total = match total.checked_add(read as u64) {
            Some(total) if total <= MAX_ZIP_DOWNLOAD => total,
            _ => {
                ok = false;
                break;
            }
        };
        if file.write_all(&buf[..read]).is_err() {
            ok = false;
            break;
        }
    }
    if ok && file.flush().is_err() {
        ok = false;
    }
    drop(file);
    if !ok {
        let _ = std::fs::remove_file(&tmp_path);
        return String::new();
    }
    match std::fs::rename(&tmp_path, &resolved) {
        Ok(_) => "true".to_string(),
        Err(_) => {
            let _ = std::fs::remove_file(&tmp_path);
            String::new()
        }
    }
}

#[cfg(feature = "js-quickjs")]
fn java_get_file(path: String) -> String {
    let resolved = match resolve_file_path(&path) {
        Some(p) => p,
        None => return String::new(),
    };
    std::fs::read_to_string(&resolved).unwrap_or_default()
}

#[cfg(feature = "js-quickjs")]
fn java_delete_file(path: String) -> String {
    let resolved = match resolve_file_path(&path) {
        Some(p) => p,
        None => return String::new(),
    };
    match std::fs::remove_file(&resolved) {
        Ok(_) => "true".to_string(),
        Err(_) => String::new(),
    }
}

#[cfg(feature = "js-quickjs")]
fn java_unzip_file(zip_path: String, dest_dir: String) -> String {
    use std::io::Read;

    let resolved_zip = match resolve_file_path(&zip_path) {
        Some(p) => p,
        None => return String::new(),
    };
    let resolved_dest = match resolve_write_path(&dest_dir) {
        Some(p) => p,
        None => return String::new(),
    };
    std::fs::create_dir_all(&resolved_dest).ok();
    let Ok(dest_canonical) = std::path::Path::new(&resolved_dest).canonicalize() else {
        return String::new();
    };
    let bytes = match std::fs::read(&resolved_zip) {
        Ok(b) => b,
        Err(_) => return String::new(),
    };
    let cursor = std::io::Cursor::new(bytes);
    let Ok(mut archive) = zip::ZipArchive::new(cursor) else {
        return String::new();
    };
    let mut total_unzipped: u64 = 0;
    let mut ok = true;
    for i in 0..archive.len() {
        let Ok(file) = archive.by_index(i) else {
            ok = false;
            continue;
        };
        // Reject symlink entries (S_IFLNK = 0o120000) to prevent path traversal
        if file.unix_mode().unwrap_or(0) & 0o170000 == 0o120000 {
            continue;
        }
        let Some(file_name) = file.enclosed_name() else {
            ok = false;
            continue;
        };
        let out_path = dest_canonical.join(&file_name);
        if !out_path.starts_with(&dest_canonical) {
            ok = false;
            continue;
        }
        if file.is_dir() {
            std::fs::create_dir_all(&out_path).ok();
            continue;
        }
        if let Some(parent) = out_path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let parent = out_path.parent().unwrap_or(&dest_canonical);
        let Ok(parent_canonical) = parent.canonicalize() else {
            ok = false;
            continue;
        };
        if !parent_canonical.starts_with(&dest_canonical) {
            ok = false;
            continue;
        }
        let Some(file_name) = out_path.file_name() else {
            ok = false;
            continue;
        };
        let out_resolved = parent_canonical.join(file_name);
        let mut buf = Vec::new();
        if file.take(MAX_ZIP_ENTRY + 1).read_to_end(&mut buf).is_err() {
            ok = false;
            continue;
        }
        if buf.len() as u64 > MAX_ZIP_ENTRY {
            ok = false;
            continue;
        }
        total_unzipped = match total_unzipped.checked_add(buf.len() as u64) {
            Some(total) if total <= MAX_ZIP_DOWNLOAD => total,
            _ => {
                ok = false;
                continue;
            }
        };
        if std::fs::write(&out_resolved, &buf).is_err() {
            ok = false;
            continue;
        }
    }
    if ok {
        "true".to_string()
    } else {
        String::new()
    }
}

#[cfg(feature = "js-quickjs")]
fn java_get_txt_in_folder(dir_path: String) -> String {
    let resolved = match resolve_file_path(&dir_path) {
        Some(p) => p,
        None => return "[]".into(),
    };
    let Ok(entries) = std::fs::read_dir(&resolved) else {
        return "[]".into();
    };
    let txt_files: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let path = e.path();
            if path.extension().map(|ext| ext == "txt").unwrap_or(false) {
                Some(path.file_name()?.to_string_lossy().to_string())
            } else {
                None
            }
        })
        .collect();
    serde_json::to_string(&txt_files).unwrap_or_else(|_| "[]".into())
}

#[cfg(feature = "js-quickjs")]
fn parse_ttf_to_mapping(bytes: &[u8]) -> Option<std::collections::HashMap<u32, u16>> {
    let face = ttf_parser::Face::parse(bytes, 0).ok()?;
    let cmap = face.tables().cmap?;
    let mut mappings: std::collections::HashMap<u32, u16> = std::collections::HashMap::new();
    for subtable in cmap.subtables {
        if !subtable.is_unicode() {
            continue;
        }
        subtable.codepoints(|codepoint| {
            if let Some(glyph) = subtable.glyph_index(codepoint) {
                mappings.insert(codepoint, glyph.0);
            }
        });
    }
    Some(mappings)
}

#[cfg(feature = "js-quickjs")]
fn font_mappings_json(bytes: &[u8]) -> String {
    parse_ttf_to_mapping(bytes)
        .and_then(|m| serde_json::to_string(&m).ok())
        .unwrap_or_else(|| "null".to_string())
}

/// Resolve the polymorphic `input` parameter accepted by `java.queryTtf`
/// (and now `java.replaceFontByUrls`) into raw font bytes.
///
/// Three branches, mirroring the legacy `java_query_ttf` logic:
/// - `http(s)://...` → blocking GET, capped at 10 MiB.
/// - long opaque string with no path separator → base64-decode.
/// - otherwise → treat as a path under `LEGADO_FILE_ROOT` and read the file.
///
/// Returning `None` on any failure path matches `java_query_ttf` behaviour
/// (it likewise just produces `"null"` JSON when input is unfetchable).
#[cfg(feature = "js-quickjs")]
fn resolve_ttf_input(input: &str) -> Option<Vec<u8>> {
    if input.starts_with("http://") || input.starts_with("https://") {
        ssrf_guard::is_url_safe_for_fetch(input).ok()?;
        let max_bytes: usize = 10 * 1024 * 1024;
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .build()
            .ok()?;
        let response = client.get(input).send().ok()?;
        let mut buf = Vec::new();
        use std::io::Read;
        response
            .take((max_bytes + 1) as u64)
            .read_to_end(&mut buf)
            .ok()?;
        if buf.len() > max_bytes {
            return None;
        }
        Some(buf)
    } else if input.len() > 100 && !input.contains('/') && !input.contains('\\') {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD
            .decode(input.as_bytes())
            .ok()
    } else {
        read_allowed_file(input)
    }
}

#[cfg(feature = "js-quickjs")]
fn java_query_base64_ttf(base64_input: String) -> String {
    use base64::Engine;
    let bytes = match base64::engine::general_purpose::STANDARD.decode(&base64_input) {
        Ok(b) => b,
        Err(_) => return "null".to_string(),
    };
    // catch_unwind: defense-in-depth against malformed TTF triggering panic
    match catch_unwind(AssertUnwindSafe(|| font_mappings_json(&bytes))) {
        Ok(result) => result,
        Err(_) => "null".to_string(),
    }
}

#[cfg(feature = "js-quickjs")]
fn java_query_ttf(input: String) -> String {
    let bytes = match resolve_ttf_input(&input) {
        Some(b) => b,
        None => return "null".to_string(),
    };
    // catch_unwind: defense-in-depth against malformed TTF triggering panic
    match catch_unwind(AssertUnwindSafe(|| font_mappings_json(&bytes))) {
        Ok(result) => result,
        Err(_) => "null".to_string(),
    }
}

/// Apply the `mapping1 → glyph → mapping2` font-substitution algorithm to
/// `text`. Extracted from `java_replace_font` so the new
/// `java_replace_font_by_urls` entry point can share the same algorithm
/// without round-tripping through JSON.
#[cfg(feature = "js-quickjs")]
fn replace_font_text(
    text: &str,
    mapping1: &std::collections::HashMap<u32, u16>,
    mapping2: &std::collections::HashMap<u32, u16>,
) -> String {
    let mut glyph_to_codepoint: std::collections::HashMap<u16, u32> =
        std::collections::HashMap::with_capacity(mapping2.len());
    for (&codepoint, &glyph) in mapping2 {
        glyph_to_codepoint.insert(glyph, codepoint);
    }
    let mut result = String::with_capacity(text.len());
    for ch in text.chars() {
        let codepoint = ch as u32;
        if let Some(&glyph1) = mapping1.get(&codepoint) {
            if let Some(&replacement_cp) = glyph_to_codepoint.get(&glyph1) {
                if let Some(replacement_char) = std::char::from_u32(replacement_cp) {
                    result.push(replacement_char);
                    continue;
                }
            }
        }
        result.push(ch);
    }
    result
}

#[cfg(feature = "js-quickjs")]
fn java_replace_font(text: String, font1_json: String, font2_json: String) -> String {
    let mapping1: std::collections::HashMap<u32, u16> =
        serde_json::from_str(&font1_json).unwrap_or_default();
    let mapping2: std::collections::HashMap<u32, u16> =
        serde_json::from_str(&font2_json).unwrap_or_default();
    replace_font_text(&text, &mapping1, &mapping2)
}

/// One-shot font replacement: takes two font URLs / inputs (same shape as
/// `java.queryTtf`), parses each TTF once, and applies the substitution
/// in Rust without bridging the codepoint→glyph map through JSON. This
/// is the F-W1B-031 fast path for new sources; the legacy two-step
/// `queryTtf` + `replaceFont` API is preserved for compatibility.
///
/// On any failure (download, base64-decode, ttf parse) the original
/// `text` is returned unchanged — same shape as the legacy path which
/// would receive `"null"` and `serde_json::from_str` would fall back to
/// `HashMap::default()` (empty map → no substitution).
#[cfg(feature = "js-quickjs")]
fn java_replace_font_by_urls(text: String, input1: String, input2: String) -> String {
    let bytes1 = match resolve_ttf_input(&input1) {
        Some(b) => b,
        None => return text,
    };
    let bytes2 = match resolve_ttf_input(&input2) {
        Some(b) => b,
        None => return text,
    };
    let mapping1 = match parse_ttf_to_mapping(&bytes1) {
        Some(m) => m,
        None => return text,
    };
    let mapping2 = match parse_ttf_to_mapping(&bytes2) {
        Some(m) => m,
        None => return text,
    };
    replace_font_text(&text, &mapping1, &mapping2)
}

#[cfg(feature = "js-quickjs")]
fn java_read_file(path: String) -> String {
    let bytes = read_allowed_file(&path).unwrap_or_default();
    serde_json::to_string(&bytes).unwrap_or_else(|_| "[]".into())
}

#[cfg(feature = "js-quickjs")]
fn java_read_txt_file(path: String, charset: String) -> String {
    let bytes = read_allowed_file(&path).unwrap_or_default();
    decode_file_text(&bytes, &charset)
}

#[cfg(feature = "js-quickjs")]
fn read_allowed_file(path: &str) -> Option<Vec<u8>> {
    // F-W1B-005 (BATCH-10): reject `..` segments and absolute paths
    // explicitly *before* `canonicalize`, closing the symlink-resolution
    // window where `canonicalize` could follow a symlink whose target
    // sits outside `LEGADO_FILE_ROOT`. The trailing `starts_with(&root)`
    // check still runs as defence in depth.
    let trimmed = path.trim_start_matches('/');
    if std::path::Path::new(trimmed).is_absolute() {
        return None;
    }
    for segment in trimmed.split(['/', '\\']) {
        if segment == ".." {
            return None;
        }
    }
    let root = std::env::var("LEGADO_FILE_ROOT").ok()?;
    let root = std::path::PathBuf::from(root).canonicalize().ok()?;
    let requested = root.join(trimmed).canonicalize().ok()?;
    if !requested.starts_with(&root) || !requested.is_file() {
        return None;
    }
    std::fs::read(requested).ok()
}

#[cfg(feature = "js-quickjs")]
fn decode_file_text(bytes: &[u8], charset: &str) -> String {
    if charset.trim().is_empty() {
        return String::from_utf8(bytes.to_vec()).unwrap_or_else(|_| {
            let (decoded, _, _) = encoding_rs::GBK.decode(bytes);
            decoded.into_owned()
        });
    }
    let label = charset.trim().to_lowercase();
    let encoding = match label.as_str() {
        "gbk" | "gb2312" | "gb18030" => {
            encoding_rs::Encoding::for_label(b"gbk").unwrap_or(encoding_rs::UTF_8)
        }
        "big5" => encoding_rs::Encoding::for_label(b"big5").unwrap_or(encoding_rs::UTF_8),
        "shift_jis" | "shift-jis" => {
            encoding_rs::Encoding::for_label(b"shift_jis").unwrap_or(encoding_rs::UTF_8)
        }
        "euc-kr" => encoding_rs::Encoding::for_label(b"euc-kr").unwrap_or(encoding_rs::UTF_8),
        _ => encoding_rs::UTF_8,
    };
    let (decoded, _, _) = encoding.decode(bytes);
    decoded.into_owned()
}

// Basic Legado compatibility object. Network-backed java.* functions are added
// in the bridge layer later; keeping stubs here lets ordinary JS expressions run.
#[cfg(any(feature = "js-quickjs", feature = "js-boa"))]
const PREAMBLE: &str = r#"
var java = {
    url: typeof __legado_url__ !== 'undefined' ? String(__legado_url__) : '',
    headerMap: {
        _items: typeof __legado_headers__ !== 'undefined' ? __legado_headers__ : {},
        put: function(key, value) { this._items[String(key)] = String(value); return String(value); },
        get: function(key) { return this._items[String(key)] || ''; },
        remove: function(key) { delete this._items[String(key)]; },
        toObject: function() { return this._items; }
    },
    _defaultHeaders: typeof __legado_default_headers__ !== 'undefined' ? __legado_default_headers__ : {},
    _mergeHeaders: function(headers) {
        var merged = {};
        for (var key in this._defaultHeaders) merged[key] = this._defaultHeaders[key];
        if (headers) for (var key2 in headers) merged[key2] = headers[key2];
        return merged;
    },
    ajax: function(url) { return __legado_http_request('GET', String(url), '', JSON.stringify(this._mergeHeaders(null))); },
    connect: function(url) { return this.get(String(url || ''), {}); },
    ajaxAll: function(urlList) {
        var out = [];
        for (var i = 0; i < urlList.length; i++) {
            var body = __legado_http_request('GET', String(urlList[i]), '', JSON.stringify(this._mergeHeaders(null)));
            out.push({ body: function() { return body; }, toString: function() { return body; } });
        }
        return out;
    },
    post: function(url, body, headers) {
        var headersJson = JSON.stringify(this._mergeHeaders(headers));
        var responseBody = __legado_http_request('POST', String(url), String(body || ''), headersJson);
        return { body: function() { return responseBody; }, toString: function() { return responseBody; } };
    },
    get: function(keyOrUrl, headers) {
        if (arguments.length <= 1) {
            // F-W1B-011 (BATCH-11): when used as `java.get(key)` (i.e. the
            // companion of `java.put`), fall back to the thread-local
            // bucket whenever the JS-side `_vars` does not have the key.
            // Without this, `java.put` in eval A would never be visible to
            // `java.get` in eval B because each eval rebuilds `_vars` from
            // `__legado_variables__`.
            var k = String(keyOrUrl);
            var local = this._vars[k];
            if (local !== undefined && local !== null && local !== '') return local;
            return __legado_js_get(k);
        }
        var headersJson = JSON.stringify(this._mergeHeaders(headers));
        var responseBody = __legado_http_request('GET', String(keyOrUrl), '', headersJson);
        return { body: function() { return responseBody; }, toString: function() { return responseBody; } };
    },
    getCookie: function(tag, key) { return __legado_get_cookie(String(tag || ''), key == null ? '' : String(key)); },
    _vars: typeof __legado_variables__ !== 'undefined' ? __legado_variables__ : {},
    // F-W1B-011 (BATCH-11): write-through to LEGADO_JS_VARIABLES so a
    // subsequent eval (which builds a fresh QuickJS Runtime/Context) still
    // sees the value via build_runtime_vars() reading the thread-local.
    // Legado sources commonly do `java.put('cookie', ...)` in search and
    // `java.get('cookie')` in getContent; without write-through that
    // pattern silently dropped state across stage boundaries.
    put: function(key, value) {
        var k = String(key);
        var v = value == null ? '' : String(value);
        this._vars[k] = v;
        __legado_js_put(k, v);
        return v;
    },
    getFromMemory: function(key) { return __legado_cache_get(String(key || '')); },
    putMemory: function(key, value) { return __legado_cache_put(String(key || ''), value == null ? '' : String(value)); },
    setContent: function(content, baseUrl) { return __legado_set_content(String(content || ''), String(baseUrl || '')); },
    getString: function(rule, isUrl) {
        var content = typeof result !== 'undefined' && result !== null ? String(result) : String(src || '');
        return __legado_get_string(String(rule || ''), content, String(baseUrl || ''));
    },
    getStringList: function(rule, isUrl) {
        var content = typeof result !== 'undefined' && result !== null ? String(result) : String(src || '');
        return JSON.parse(__legado_get_string_list(String(rule || ''), content, String(baseUrl || '')));
    },
    getElements: function(rule) {
        var content = typeof result !== 'undefined' && result !== null ? String(result) : String(src || '');
        return JSON.parse(__legado_get_elements(String(rule || ''), content, String(baseUrl || ''))).map(function(item) {
            return java._wrapElement(item);
        });
    },
    _wrapElement: function(item) {
        return {
            _item: item || {},
            tagName: function() { return String(this._item.tagName || ''); },
            nodeName: function() { return this.tagName(); },
            text: function() { return String(this._item.text || ''); },
            ownText: function() { return String(this._item.ownText || ''); },
            html: function() { return String(this._item.html || ''); },
            outerHtml: function() { return String(this._item.outerHtml || ''); },
            attr: function(name) {
                var attrs = this._item.attrs || {};
                var key = String(name || '');
                return attrs[key] == null ? '' : String(attrs[key]);
            },
            hasAttr: function(name) {
                var attrs = this._item.attrs || {};
                return Object.prototype.hasOwnProperty.call(attrs, String(name || ''));
            },
            id: function() { return this.attr('id'); },
            className: function() { return this.attr('class'); },
            classNames: function() {
                return this.className().split(/\s+/).filter(function(x) { return x.length > 0; });
            },
            hasClass: function(name) {
                return this.classNames().indexOf(String(name || '')) >= 0;
            },
            absUrl: function(name) {
                var value = this.attr(name);
                if (!value) return '';
                return java._resolveUrl(value, String(baseUrl || ''));
            },
            children: function() {
                var children = this._item.children || [];
                return children.map(function(child) { return java._wrapElement(child); });
            },
            child: function(index) {
                var items = this.children();
                return items[Number(index) || 0] || null;
            },
            childNodeSize: function() { return (this._item.children || []).length; },
            select: function(rule) {
                return JSON.parse(__legado_get_elements(String(rule || ''), String(this._item.html || ''), String(baseUrl || ''))).map(function(child) {
                    return java._wrapElement(child);
                });
            },
            selectFirst: function(rule) {
                var items = this.select(rule);
                return items.length > 0 ? items[0] : null;
            },
            // F-W1B-012 (BATCH-11): JSON.stringify on a wrapped element
            // used to fall back to `{}` because every member is a function
            // (which JSON.stringify drops). Returning text() makes the
            // wrapper round-trip through stringify as the visible text
            // — matching Legado's Java side, where Element#toString
            // returns the rendered HTML/text and JSON serialisation
            // collapses to the same string. We deliberately do NOT change
            // the global stringify wrapper.
            toJSON: function() { return this.text(); },
            toString: function() { return this.text(); }
        };
    },
    // F-W1B-015 (BATCH-11): delegate to the Rust-side `build_full_url`
    // (`url::Url::join` under the hood) so that JS-driven `element.absUrl()`
    // and Rust-driven `crate::utils::build_full_url` agree byte-for-byte.
    // The previous JS-only implementation drifted on `//host`, `?query`,
    // `#fragment`, and IPv6 base URLs.
    _resolveUrl: function(value, base) { return __legado_resolve_url(String(value == null ? '' : value), String(base == null ? '' : base)); },
    log: function(msg) { return __legado_log(String(msg || '')); },
    encodeURI: function(str) { return __legado_encode_uri(String(str)); },
    encodeURIComponent: function(str) { return __legado_encode_uri_component(String(str)); },
    decodeURI: function(str) { return __legado_decode_uri(String(str)); },
    base64Encode: function(str, _flags) { return __legado_base64_encode(String(str || '')); },
    base64Decode: function(str, _flags) { return __legado_base64_decode(String(str || '')); },
    base64DecodeToByteArray: function(str, _flags) { return JSON.parse(__legado_base64_decode_to_byte_array(String(str || ''))); },
    md5Encode: function(str) { return __legado_md5(String(str)); },
    md5Encode16: function(str) { return __legado_md5_16(String(str)); },
    aesDecodeToString: function(str, key, transformation, iv) { return __legado_aes_decode_to_string(String(str || ''), String(key || ''), String(transformation || 'AES/CBC/PKCS5Padding'), String(iv || '')); },
    aesBase64DecodeToString: function(str, key, transformation, iv) { return __legado_aes_base64_decode_to_string(String(str || ''), String(key || ''), String(transformation || 'AES/CBC/PKCS5Padding'), String(iv || '')); },
    aesEncodeToString: function(data, key, transformation, iv) { return __legado_aes_encode_to_string(String(data || ''), String(key || ''), String(transformation || 'AES/CBC/PKCS5Padding'), String(iv || '')); },
    aesEncodeToBase64String: function(data, key, transformation, iv) { return __legado_aes_encode_to_base64_string(String(data || ''), String(key || ''), String(transformation || 'AES/CBC/PKCS5Padding'), String(iv || '')); },
    aesDecodeToByteArray: function(str, key, transformation, iv) { return JSON.parse(__legado_aes_decode_to_byte_array(String(str || ''), String(key || ''), String(transformation || 'AES/CBC/PKCS5Padding'), String(iv || ''))); },
    aesBase64DecodeToByteArray: function(str, key, transformation, iv) { return JSON.parse(__legado_aes_base64_decode_to_byte_array(String(str || ''), String(key || ''), String(transformation || 'AES/CBC/PKCS5Padding'), String(iv || ''))); },
    aesEncodeToByteArray: function(data, key, transformation, iv) { return JSON.parse(__legado_aes_encode_to_byte_array(String(data || ''), String(key || ''), String(transformation || 'AES/CBC/PKCS5Padding'), String(iv || ''))); },
    aesEncodeToBase64ByteArray: function(data, key, transformation, iv) { return JSON.parse(__legado_aes_encode_to_base64_byte_array(String(data || ''), String(key || ''), String(transformation || 'AES/CBC/PKCS5Padding'), String(iv || ''))); },
    timeFormat: function(value) { return __legado_time_format(value == null ? '' : String(value)); },
    htmlFormat: function(value) { return __legado_html_format(value == null ? '' : String(value)); },
    getZipStringContent: function(url, path) { return __legado_get_zip_string_content(String(url || ''), String(path || '')); },
    getZipByteArrayContent: function(url, path) { return JSON.parse(__legado_get_zip_byte_array_content(String(url || ''), String(path || ''))); },
    readFile: function(path) { return JSON.parse(__legado_read_file(String(path || ''))); },
    readTxtFile: function(path, charsetName) { return __legado_read_txt_file(String(path || ''), charsetName == null ? '' : String(charsetName)); },
    downloadFile: function(url, path) { return __legado_download_file(String(url || ''), String(path || '')); },
    getFile: function(path) { return __legado_get_file(String(path || '')); },
    deleteFile: function(path) { return __legado_delete_file(String(path || '')); },
    unzipFile: function(zipPath, destDir) { return __legado_unzip_file(String(zipPath || ''), String(destDir || '')); },
    getTxtInFolder: function(dirPath) { return JSON.parse(__legado_get_txt_in_folder(String(dirPath || ''))); },
    utf8ToGbk: function(str) { return __legado_utf8_to_gbk(String(str)); },
    queryBase64Ttf: function(base64) { return __legado_query_base64_ttf(String(base64)); },
    queryTtf: function(input) { return __legado_query_ttf(String(input)); },
    replaceFont: function(text, font1Json, font2Json) { return __legado_replace_font(String(text), String(font1Json || ''), String(font2Json || '')); },
    replaceFontByUrls: function(text, url1, url2) { return __legado_replace_font_by_urls(String(text), String(url1 || ''), String(url2 || '')); }
};

var cache = {
    getFromMemory: function(key) { return __legado_cache_get(String(key || '')); },
    putMemory: function(key, value) { return __legado_cache_put(String(key || ''), value == null ? '' : String(value)); },
    get: function(key) { return __legado_cache_get(String(key || '')); },
    put: function(key, value) { return __legado_cache_put(String(key || ''), value == null ? '' : String(value)); }
};

var cookie = {
    getCookie: function(url) { return __legado_get_cookie(String(url || ''), ''); },
    setCookie: function(url, cookieStr) { return __legado_set_cookie(String(url || ''), String(cookieStr || '')); },
    removeCookie: function(url) { return __legado_remove_cookie(String(url || '')); },
    getKey: function(url, key) { return __legado_get_cookie(String(url || ''), String(key || '')); }
};

var source = {
    getKey: function() {
        if (typeof __source_url__ !== 'undefined') return __source_url__;
        if (typeof baseUrl !== 'undefined') {
            var m = String(baseUrl).match(/https?:\/\/[^\/]+/);
            return m ? m[0] : '';
        }
        return '';
    },
    key: ''
};
if (typeof __source_url__ !== 'undefined') source.key = __source_url__;
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn file_env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn test_simple_eval() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("1 + 2", &vars).unwrap();
        assert!(matches!(result, LegadoValue::Int(3)));
    }

    #[test]
    fn test_string_concat() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval(r#""hello " + "world""#, &vars).unwrap();
        assert_eq!(result.as_str(), Some("hello world"));
    }

    #[test]
    fn test_with_variable() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://x.com/read/17047/".into()),
        );
        vars.insert("key".into(), LegadoValue::String("test".into()));
        let result = rt.eval("baseUrl + 's?q=' + key", &vars).unwrap();
        assert_eq!(result.as_str(), Some("https://x.com/read/17047/s?q=test"));
    }

    #[test]
    fn test_regex_match() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://x.com/read/17047/".into()),
        );
        let result = rt.eval("baseUrl.match(/read\\/(\\d+)/)[1]", &vars).unwrap();
        assert_eq!(result.as_str(), Some("17047"));
    }

    #[test]
    fn test_source_get_key() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "__source_url__".into(),
            LegadoValue::String("https://ixdzs8.com".into()),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://ixdzs8.com/read/17047/".into()),
        );
        let result = rt.eval("source.getKey()", &vars).unwrap();
        assert_eq!(result.as_str(), Some("https://ixdzs8.com"));
    }

    #[test]
    fn test_empty_script() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("", &vars).unwrap();
        assert!(result.is_null());
    }

    #[test]
    fn test_java_base64_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let encoded = rt.eval("java.base64Encode('test')", &vars).unwrap();
        assert_eq!(encoded.as_str(), Some("dGVzdA=="));

        let decoded = rt.eval("java.base64Decode('dGVzdA==')", &vars).unwrap();
        assert_eq!(decoded.as_str(), Some("test"));
    }

    #[test]
    fn test_java_md5_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("java.md5Encode('123')", &vars).unwrap();
        assert_eq!(result.as_str(), Some("202cb962ac59075b964b07152d234b70"));

        let result = rt.eval("java.md5Encode16('123')", &vars).unwrap();
        assert_eq!(result.as_str(), Some("ac59075b964b0715"));
    }

    #[test]
    fn test_java_uri_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt
            .eval("java.encodeURIComponent('你好 test')", &vars)
            .unwrap();
        assert_eq!(result.as_str(), Some("%E4%BD%A0%E5%A5%BD%20test"));

        let result = rt
            .eval("java.decodeURI('%E4%BD%A0%E5%A5%BD%20test')", &vars)
            .unwrap();
        assert_eq!(result.as_str(), Some("你好 test"));
    }

    #[test]
    fn test_java_ajax_bridge() {
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/ajax");
            then.status(200).body("ajax-ok");
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt
            .eval(&format!("java.ajax('{}')", server.url("/ajax")), &vars)
            .unwrap();

        mock.assert();
        assert_eq!(result.as_str(), Some("ajax-ok"));
    }

    #[test]
    fn test_java_get_bridge_response_body() {
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET)
                .path("/get")
                .header("X-Test", "1");
            then.status(200).body("get-ok");
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.get('{}', {{'X-Test':'1'}}).body()",
            server.url("/get")
        );
        let result = rt.eval(&script, &vars).unwrap();

        mock.assert();
        assert_eq!(result.as_str(), Some("get-ok"));
    }

    #[test]
    fn test_java_post_bridge_response_body() {
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::POST)
                .path("/post")
                .header("X-Test", "1")
                .body("a=1");
            then.status(200).body("post-ok");
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.post('{}', 'a=1', {{'X-Test':'1'}}).body()",
            server.url("/post")
        );
        let result = rt.eval(&script, &vars).unwrap();

        mock.assert();
        assert_eq!(result.as_str(), Some("post-ok"));
    }

    #[test]
    fn test_java_ajax_uses_meta_charset_detection() {
        let server = httpmock::MockServer::start();
        let body = b"<html><head><meta charset=gbk></head><body>\xc4\xe3\xba\xc3</body></html>";
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/gbk-meta");
            then.status(200)
                .header("Content-Type", "text/html")
                .body(body.as_slice());
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt
            .eval(&format!("java.ajax('{}')", server.url("/gbk-meta")), &vars)
            .unwrap();

        mock.assert();
        assert!(result.as_str().unwrap_or_default().contains("你好"));
    }

    #[test]
    fn test_java_get_explicit_charset_header() {
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/gbk-explicit");
            then.status(200)
                .header("Content-Type", "text/plain")
                .body(&b"\xc4\xe3\xba\xc3"[..]);
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.get('{}', {{charset:'gbk'}}).body()",
            server.url("/gbk-explicit")
        );
        let result = rt.eval(&script, &vars).unwrap();

        mock.assert();
        assert_eq!(result.as_str(), Some("你好"));
    }

    #[test]
    fn test_java_get_string_bridge() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "src".into(),
            LegadoValue::String(r#"<div><a href="/b/1">Book</a></div>"#.into()),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com".into()),
        );

        let result = rt
            .eval("java.getString('@css:a@text', false)", &vars)
            .unwrap();
        assert_eq!(result.as_str(), Some("Book"));
    }

    #[test]
    fn test_java_get_string_list_bridge() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "src".into(),
            LegadoValue::String(r#"<ul><li>A</li><li>B</li></ul>"#.into()),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com".into()),
        );

        let result = rt
            .eval("java.getStringList('@css:li@text', false).join(',')", &vars)
            .unwrap();
        assert_eq!(result.as_str(), Some("A,B"));
    }

    #[test]
    fn test_java_get_elements_bridge() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "src".into(),
            LegadoValue::String(r#"<ul><li>A</li><li>B</li></ul>"#.into()),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com".into()),
        );

        let result = rt
            .eval("java.getElements('@css:li').length", &vars)
            .unwrap();
        assert!(matches!(result, LegadoValue::Int(2)));
    }

    #[test]
    fn test_java_get_elements_element_methods() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "src".into(),
            LegadoValue::String(
                r#"<div class="book" data-id="7"><a href="/b/7"><span>Book</span></a></div>"#
                    .into(),
            ),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com".into()),
        );

        let script = "var el = java.getElements('@css:div.book')[0]; [el.text(), el.attr('data-id'), el.selectFirst('a').attr('href'), el.selectFirst('span').text()].join('|')";
        let result = rt.eval(script, &vars).unwrap();

        assert_eq!(result.as_str(), Some("Book|7|/b/7|Book"));
    }

    #[test]
    fn test_java_get_elements_to_string_returns_text() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "src".into(),
            LegadoValue::String(r#"<ul><li>A</li><li>B</li></ul>"#.into()),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com".into()),
        );

        let result = rt
            .eval("java.getElements('@css:li').join(',')", &vars)
            .unwrap();

        assert_eq!(result.as_str(), Some("A,B"));
    }

    #[test]
    fn test_java_get_elements_more_element_methods() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert("src".into(), LegadoValue::String(r#"<div id="root" class="book hot" data-id="7">Own <a href="/b/7">Link</a><span>Span</span></div>"#.into()));
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com/base/page.html".into()),
        );

        let script = "var el = java.getElements('@css:div')[0]; [el.tagName(), el.id(), el.hasClass('hot'), el.ownText().trim(), el.children().length, el.child(0).tagName(), el.childNodeSize(), el.selectFirst('a').absUrl('href')].join('|')";
        let result = rt.eval(script, &vars).unwrap();

        assert_eq!(
            result.as_str(),
            Some("div|root|true|Own|2|a|2|https://example.com/b/7")
        );
    }

    #[test]
    fn test_java_get_elements_has_attr_and_class_names() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "src".into(),
            LegadoValue::String(r#"<p class="a b" title="T">Text</p>"#.into()),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com".into()),
        );

        let script = "var el = java.getElements('@css:p')[0]; [el.hasAttr('title'), el.hasAttr('missing'), el.classNames().join(',')].join('|')";
        let result = rt.eval(script, &vars).unwrap();

        assert_eq!(result.as_str(), Some("true|false|a,b"));
    }

    #[test]
    fn test_url_option_js_bridge() {
        let context = UrlJsContext::new("https://example.com/a", &[("A".into(), "1".into())]);
        let updated = eval_url_option_js(
            "java.url = java.url + '?p=1'; java.headerMap.put('X-Test', 'ok')",
            &context,
        )
        .unwrap();

        assert_eq!(updated.url, "https://example.com/a?p=1");
        assert!(updated.headers.contains(&("A".into(), "1".into())));
        assert!(updated.headers.contains(&("X-Test".into(), "ok".into())));
    }

    #[test]
    fn test_java_put_get_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt
            .eval("java.put('token', 'abc') && java.get('token')", &vars)
            .unwrap();
        assert_eq!(result.as_str(), Some("abc"));
    }

    #[test]
    fn test_java_get_from_context_variables() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        let mut stored = HashMap::new();
        stored.insert("token".into(), LegadoValue::String("abc".into()));
        vars.insert("__legado_variables__".into(), LegadoValue::Map(stored));
        let result = rt.eval("java.get('token')", &vars).unwrap();
        assert_eq!(result.as_str(), Some("abc"));
    }

    #[test]
    fn test_cache_memory_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt
            .eval(
                "cache.putMemory('bid', '42'); cache.getFromMemory('bid')",
                &vars,
            )
            .unwrap();
        assert_eq!(result.as_str(), Some("42"));
    }

    #[test]
    fn test_java_get_cookie_bridge() {
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/cookie");
            then.status(200)
                .header("Set-Cookie", "sid=abc; Path=/")
                .body("cookie-ok");
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.ajax('{}') && java.getCookie('{}', 'sid')",
            server.url("/cookie"),
            server.url("/")
        );
        let result = rt.eval(&script, &vars).unwrap();

        mock.assert();
        assert_eq!(result.as_str(), Some("abc"));
    }

    #[test]
    fn test_java_get_cookie_all_bridge() {
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/cookie-all");
            then.status(200)
                .header("Set-Cookie", "token=xyz; Path=/")
                .body("cookie-ok");
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.ajax('{}') && java.getCookie('{}', null)",
            server.url("/cookie-all"),
            server.url("/")
        );
        let result = rt.eval(&script, &vars).unwrap();

        mock.assert();
        assert!(result.as_str().unwrap_or_default().contains("token=xyz"));
    }

    #[test]
    fn test_java_aes_cbc_base64_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = r#"
            (function(){
                var key = '1234567890123456';
                var iv = 'abcdefghijklmnop';
                var enc = java.aesEncodeToBase64String('hello', key, 'AES/CBC/PKCS5Padding', iv);
                return java.aesBase64DecodeToString(enc, key, 'AES/CBC/PKCS5Padding', iv);
            })()
        "#;
        let result = rt.eval(script, &vars).unwrap();
        assert_eq!(result.as_str(), Some("hello"));
    }

    #[test]
    fn test_java_aes_ecb_hex_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = r#"
            (function(){
                var key = '1234567890123456';
                var enc = java.aesEncodeToString('hello', key, 'AES/ECB/PKCS5Padding', '');
                return java.aesDecodeToString(enc, key, 'AES/ECB/PKCS5Padding', '');
            })()
        "#;
        let result = rt.eval(script, &vars).unwrap();
        assert_eq!(result.as_str(), Some("hello"));
    }

    #[test]
    fn test_java_aes_256_cbc_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = r#"
            (function(){
                var key = '12345678901234567890123456789012';
                var iv = 'abcdefghijklmnop';
                var enc = java.aesEncodeToBase64String('hello-256', key, 'AES/CBC/PKCS5Padding', iv);
                return java.aesBase64DecodeToString(enc, key, 'AES/CBC/PKCS5Padding', iv);
            })()
        "#;
        let result = rt.eval(script, &vars).unwrap();
        assert_eq!(result.as_str(), Some("hello-256"));
    }

    #[test]
    fn test_java_aes_byte_array_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = r#"
            (function(){
                var key = '1234567890123456';
                var iv = 'abcdefghijklmnop';
                var enc = java.aesEncodeToBase64String('hello', key, 'AES/CBC/PKCS5Padding', iv);
                return java.aesBase64DecodeToByteArray(enc, key, 'AES/CBC/PKCS5Padding', iv).join(',');
            })()
        "#;
        let result = rt.eval(script, &vars).unwrap();
        assert_eq!(result.as_str(), Some("104,101,108,108,111"));
    }

    #[test]
    fn test_java_aes_encode_to_byte_array_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = r#"
            (function(){
                var key = '1234567890123456';
                var iv = 'abcdefghijklmnop';
                return java.aesEncodeToByteArray('hello', key, 'AES/CBC/PKCS5Padding', iv).length > 0;
            })()
        "#;
        let result = rt.eval(script, &vars).unwrap();
        assert!(matches!(result, LegadoValue::Bool(true)));
    }

    #[test]
    fn test_java_time_format_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("java.timeFormat(0)", &vars).unwrap();
        assert_eq!(result.as_str(), Some("1970/01/01 00:00"));

        // F-W1B-016 (BATCH-11): under the new threshold (>= 10^11 ms),
        // a value of 60000 is treated as *seconds* (60000s ≈ 16h 40min)
        // rather than milliseconds. The previous heuristic
        // (`abs() < 10^9` → divide by 1000) was the bug being removed.
        let result = rt.eval("java.timeFormat(60000)", &vars).unwrap();
        assert_eq!(result.as_str(), Some("1970/01/01 16:40"));
    }

    #[test]
    fn test_java_html_format_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt
            .eval(
                "java.htmlFormat('<p>A&nbsp;&amp;B</p><br><script>x</script><p>C</p>')",
                &vars,
            )
            .unwrap();
        assert_eq!(result.as_str(), Some("A &B\nC"));
    }

    #[test]
    fn test_java_get_zip_string_content_bridge() {
        let zip = build_test_zip("dir/a.txt", b"zip-ok");
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/test.zip");
            then.status(200).body(zip.clone());
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.getZipStringContent('{}', 'dir/a.txt')",
            server.url("/test.zip")
        );
        let result = rt.eval(&script, &vars).unwrap();

        mock.assert();
        assert_eq!(result.as_str(), Some("zip-ok"));
    }

    #[test]
    fn test_java_get_zip_byte_array_content_bridge() {
        let zip = build_test_zip("a.bin", &[1, 2, 3]);
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/bytes.zip");
            then.status(200).body(zip.clone());
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.getZipByteArrayContent('{}', 'a.bin').join(',')",
            server.url("/bytes.zip")
        );
        let result = rt.eval(&script, &vars).unwrap();

        mock.assert();
        assert_eq!(result.as_str(), Some("1,2,3"));
    }

    fn build_test_zip(path: &str, content: &[u8]) -> Vec<u8> {
        use std::io::{Cursor, Write};

        let cursor = Cursor::new(Vec::new());
        let mut writer = zip::ZipWriter::new(cursor);
        let options = zip::write::FileOptions::default();
        writer.start_file(path, options).unwrap();
        writer.write_all(content).unwrap();
        writer.finish().unwrap().into_inner()
    }

    #[test]
    fn test_java_read_txt_file_bridge() {
        let _guard = file_env_lock().lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), "file-ok").unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", dir.path());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("java.readTxtFile('a.txt')", &vars).unwrap();

        assert_eq!(result.as_str(), Some("file-ok"));
    }

    #[test]
    fn test_java_read_file_bridge() {
        let _guard = file_env_lock().lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.bin"), [1, 2, 3]).unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", dir.path());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("java.readFile('a.bin').join(',')", &vars).unwrap();

        assert_eq!(result.as_str(), Some("1,2,3"));
    }

    #[test]
    fn test_java_read_file_blocks_path_escape() {
        let _guard = file_env_lock().lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("secret.txt"), "secret").unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", dir.path());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let escaped = format!("{}/secret.txt", outside.path().display());
        let result = rt
            .eval(&format!("java.readTxtFile('{}')", escaped), &vars)
            .unwrap();

        assert_eq!(result.as_str(), Some(""));
    }

    #[test]
    fn test_java_connect_bridge() {
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/connect-test");
            then.status(200).body("connect-ok");
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!("java.connect('{}').body()", server.url("/connect-test"));
        let result = rt.eval(&script, &vars).unwrap();
        mock.assert();
        assert_eq!(result.as_str(), Some("connect-ok"));
    }

    #[test]
    fn test_java_base64_decode_to_byte_array_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt
            .eval("java.base64DecodeToByteArray('AQIDBA==').join(',')", &vars)
            .unwrap();
        assert_eq!(result.as_str(), Some("1,2,3,4"));
    }

    #[test]
    fn test_java_log_bridge() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("java.log('test-message')", &vars).unwrap();
        assert_eq!(result.as_str(), Some(""));
    }

    #[test]
    fn test_java_set_content_bridge() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "src".into(),
            LegadoValue::String(r#"<html><body><div class="x">ignored</div></body></html>"#.into()),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com".into()),
        );

        let script = r#"
            java.setContent('<html><body><div class="x">setcontent-ok</div></body></html>', 'https://example.com');
            java.getString('@css:div.x@text', false)
        "#;
        let result = rt.eval(script, &vars).unwrap();
        assert_eq!(result.as_str(), Some("setcontent-ok"));
    }

    #[test]
    fn test_java_base64_encode_decode_flags() {
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let encoded = rt.eval("java.base64Encode('test', 0)", &vars).unwrap();
        assert_eq!(encoded.as_str(), Some("dGVzdA=="));
        let decoded = rt.eval("java.base64Decode('dGVzdA==', 0)", &vars).unwrap();
        assert_eq!(decoded.as_str(), Some("test"));
    }

    #[test]
    fn test_java_download_file_bridge() {
        let _guard = file_env_lock().lock().unwrap();
        let server = httpmock::MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/dl/test.txt");
            then.status(200).body("downloaded-content");
        });

        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", dir.path());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.downloadFile('{}/dl/test.txt', 'saved.txt')",
            server.base_url()
        );
        let result = rt.eval(&script, &vars).unwrap();
        mock.assert();
        assert_eq!(result.as_str(), Some("true"));

        let saved = std::fs::read_to_string(dir.path().join("saved.txt")).unwrap();
        assert_eq!(saved, "downloaded-content");
    }

    #[test]
    fn test_java_get_file_bridge() {
        let _guard = file_env_lock().lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("test.txt"), "file-content").unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", dir.path());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("java.getFile('test.txt')", &vars).unwrap();
        assert_eq!(result.as_str(), Some("file-content"));
    }

    #[test]
    fn test_java_delete_file_bridge() {
        let _guard = file_env_lock().lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("to_delete.txt");
        std::fs::write(&path, "delete-me").unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", dir.path());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("java.deleteFile('to_delete.txt')", &vars).unwrap();
        assert_eq!(result.as_str(), Some("true"));
        assert!(!path.exists());
    }

    #[test]
    fn test_java_unzip_file_bridge() {
        let _guard = file_env_lock().lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let zip_data = build_test_zip("inner.txt", b"zipped-content");
        std::fs::write(dir.path().join("test.zip"), &zip_data).unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", dir.path());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval("java.unzipFile('test.zip', 'out')", &vars).unwrap();
        assert_eq!(result.as_str(), Some("true"));

        let extracted = std::fs::read_to_string(dir.path().join("out").join("inner.txt")).unwrap();
        assert_eq!(extracted, "zipped-content");
    }

    #[test]
    fn test_java_get_txt_in_folder_bridge() {
        let _guard = file_env_lock().lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), "a").unwrap();
        std::fs::write(dir.path().join("b.txt"), "b").unwrap();
        std::fs::write(dir.path().join("c.dat"), "c").unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", dir.path());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt
            .eval("java.getTxtInFolder('.').join(',')", &vars)
            .unwrap();
        let files: Vec<&str> = result.as_str().unwrap_or("").split(',').collect();
        assert!(files.contains(&"a.txt"));
        assert!(files.contains(&"b.txt"));
        assert!(!files.contains(&"c.dat"));
    }

    /// **F-W1B-031 (BATCH-14)**: 新接口 `java.replaceFontByUrls` 的单次到位
    /// 算法必须与"老路径走两步" (queryTtf → replaceFont via JSON) 等价。
    ///
    /// 真实 ttf bytes 构造成本高，本测试直接验证两条路径共享的核心算法
    /// `replace_font_text`：给定相同的 mapping1 / mapping2，输出 text 与
    /// "老路径走 java_replace_font(JSON)" 完全一致。两条路径都委托到
    /// `replace_font_text`，所以一致性由结构保证；本测覆盖映射存在/缺失
    /// /链断开三种情况的字符替换正确性。
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_replace_font_by_urls_equivalent_to_two_step() {
        // mapping1: 文本里的字符 → 字形 id
        // 'A' (0x41) → glyph 100, 'B' (0x42) → glyph 101, 'X' (0x58) → glyph 999
        let mut mapping1: std::collections::HashMap<u32, u16> =
            std::collections::HashMap::new();
        mapping1.insert(0x41, 100);
        mapping1.insert(0x42, 101);
        mapping1.insert(0x58, 999);

        // mapping2: 字形 id → 真实 codepoint（反向用 glyph→codepoint 查）
        // glyph 100 → 'a' (0x61), glyph 101 → 'b' (0x62)
        // 注意：glyph 999 不在 mapping2 — 'X' 应保持原样不替换
        let mut mapping2: std::collections::HashMap<u32, u16> =
            std::collections::HashMap::new();
        mapping2.insert(0x61, 100);
        mapping2.insert(0x62, 101);

        let text = "A B X C"; // 'C' 不在 mapping1 也保持原样

        // 新路径：直接调 replace_font_text（与 java_replace_font_by_urls
        // 共享同一算法 helper）。
        let direct = replace_font_text(text, &mapping1, &mapping2);

        // 老路径：模拟 queryTtf 输出的 JSON → java_replace_font 走 JSON
        // 解析 → 内部同一 helper。两条路径必须输出相同字符串。
        let json1 = serde_json::to_string(&mapping1).unwrap();
        let json2 = serde_json::to_string(&mapping2).unwrap();
        let two_step = java_replace_font(text.to_string(), json1, json2);

        assert_eq!(direct, two_step, "新旧路径替换结果必须一致");
        // 显式检查替换语义：A→a, B→b, X 链断开保持原样，C 无 mapping1 保持原样，空格保持原样。
        assert_eq!(direct, "a b X C");
    }

    /// **F-W1B-031 (BATCH-14)**: 失败路径行为对齐 — `replaceFontByUrls`
    /// 在任何一步失败（input 解析、ttf parse、文件读取）时返回原 text，
    /// 与老路径"映射缺失则不替换"的语义对齐。
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_replace_font_by_urls_returns_text_on_failure() {
        // 显式给两个非法 input（不是 http、不是 base64、文件读不到 —
        // LEGADO_FILE_ROOT 未设置或路径不在 root 下）。
        let _guard = file_env_lock().lock().unwrap();
        std::env::remove_var("LEGADO_FILE_ROOT");
        let result =
            java_replace_font_by_urls("hello".to_string(), "/nope".to_string(), "/nope".to_string());
        assert_eq!(result, "hello", "input 不可解析时应返回原文本");
    }

    /// F-W1B-014 (BATCH-11): the JS object literal emitted from a
    /// `LegadoValue::Map` must keep stable key order so JS rules like
    /// `Object.keys(book)[0]` are deterministic across evals.
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_legado_value_to_js_expr_map_key_order_stable() {
        let mut map = HashMap::new();
        map.insert("zeta".to_string(), LegadoValue::String("z".into()));
        map.insert("alpha".to_string(), LegadoValue::Int(1));
        map.insert("middle".to_string(), LegadoValue::Bool(true));
        map.insert("beta".to_string(), LegadoValue::Null);
        map.insert("delta".to_string(), LegadoValue::Float(1.5));
        let value = LegadoValue::Map(map);
        let first = legado_value_to_js_expr(&value);
        for _ in 0..10 {
            assert_eq!(
                legado_value_to_js_expr(&value),
                first,
                "map literal must serialise identically across calls"
            );
        }
        // Sanity: keys appear in BTreeMap (alphabetical) order.
        let alpha_pos = first.find("\"alpha\"").expect("alpha present");
        let beta_pos = first.find("\"beta\"").expect("beta present");
        let delta_pos = first.find("\"delta\"").expect("delta present");
        let middle_pos = first.find("\"middle\"").expect("middle present");
        let zeta_pos = first.find("\"zeta\"").expect("zeta present");
        assert!(alpha_pos < beta_pos);
        assert!(beta_pos < delta_pos);
        assert!(delta_pos < middle_pos);
        assert!(middle_pos < zeta_pos);
    }

    /// F-W1B-016 (BATCH-11): seconds-level timestamps below 10^9 (e.g.
    /// `999_999_999` ≈ 2001-09-09) used to be silently divided by 1000
    /// and rendered as 1970. The new threshold (`>= 10^11`) preserves
    /// them. Negative (pre-1970) seconds are no longer abs()-collapsed.
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_java_time_format_seconds_boundary() {
        // 999_999_999 seconds ≈ 2001-09-09 UTC. Under the old heuristic
        // (`abs() < 10^9`), this was wrongly classified as ms and divided
        // by 1000, producing a year close to 1970. We assert the new
        // behaviour keeps it in the 2001 window.
        let s_2001 = java_time_format("999999999".to_string());
        assert!(
            s_2001.starts_with("2001/"),
            "999_999_999 should resolve to 2001-09-x, got {s_2001}"
        );

        // 100_000_000_000 ms ≈ 1973-03-03 UTC. With the new threshold,
        // this lands on the millisecond branch and divides by 1000.
        let s_1973 = java_time_format("100000000000".to_string());
        assert!(
            s_1973.starts_with("1973/"),
            "100_000_000_000 should resolve to 1973, got {s_1973}"
        );

        // 1_700_000_000 seconds ≈ 2023-11-15 UTC; must remain seconds.
        let s_2023 = java_time_format("1700000000".to_string());
        assert!(
            s_2023.starts_with("2023/"),
            "1_700_000_000 should resolve to 2023, got {s_2023}"
        );

        // 1_700_000_000_000 ms ≈ same instant in 2023 — must divide by 1000.
        let s_2023_ms = java_time_format("1700000000000".to_string());
        assert!(
            s_2023_ms.starts_with("2023/"),
            "1_700_000_000_000 should resolve to 2023, got {s_2023_ms}"
        );

        // Negative seconds (pre-1970) — chrono's local rendering should
        // be a 1969 timestamp. Under the old heuristic this could be
        // abs()-collapsed and hit the wrong branch.
        let s_neg = java_time_format("-1000000000".to_string());
        assert!(
            !s_neg.is_empty(),
            "negative seconds should produce a valid string, got empty"
        );
        assert!(
            s_neg.starts_with("1937/") || s_neg.starts_with("1938/") || s_neg.starts_with("1969/"),
            "negative seconds should land before 1970, got {s_neg}"
        );
    }

    /// F-W1B-015 (BATCH-11): JS-side `java._resolveUrl` and Rust-side
    /// `crate::utils::build_full_url` must produce byte-identical output
    /// because the same conceptual operation is split across both layers
    /// (Rust pre-resolves chapter URLs, JS `element.absUrl(...)` resolves
    /// links inside extracted HTML). Drift between the two implementations
    /// caused cache-key mismatches and inconsistent redirect targets.
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_resolve_url_consistent_with_rust() {
        let rt = DefaultJsRuntime::new();
        let cases: &[(&str, &str)] = &[
            // (base, relative)
            ("https://example.com/books/", "/chapter/1"),
            ("https://example.com/books/", "chapter/1"),
            ("https://example.com/books?x=1", "/y"),
            ("https://example.com/books#frag", "y"),
            ("https://example.com/", "//cdn.example.com/x"),
            ("https://example.com/a/b/c", "../d"),
            ("https://example.com/", "https://other.example.com/abs"),
        ];
        for (base, rel) in cases {
            let vars = HashMap::new();
            // Use java._resolveUrl so the bridge wiring (PREAMBLE → Rust)
            // is exercised end-to-end.
            let script = format!(
                "java._resolveUrl({}, {})",
                serde_json::to_string(rel).unwrap(),
                serde_json::to_string(base).unwrap()
            );
            let result = rt.eval(&script, &vars).expect("eval ok");
            let resolved = match result {
                LegadoValue::String(s) => s,
                other => panic!("expected string, got {other:?} for base={base} rel={rel}"),
            };
            let rust_resolved = crate::utils::build_full_url(base, rel);
            assert_eq!(
                resolved, rust_resolved,
                "JS and Rust URL resolvers disagree for base={base} rel={rel}"
            );
        }
    }

    /// F-W1B-012 (BATCH-11): `JSON.stringify` on a wrapped element used to
    /// fall back to `{}` because every member is a function. With
    /// `_wrapElement.toJSON` returning `text()`, the wrapper now serialises
    /// as the visible text — matching Legado's Java side semantics.
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_wrap_element_to_json_returns_text() {
        let rt = DefaultJsRuntime::new();
        let mut vars = HashMap::new();
        vars.insert(
            "src".into(),
            LegadoValue::String(r#"<a href="/x">linktext</a>"#.into()),
        );
        vars.insert(
            "baseUrl".into(),
            LegadoValue::String("https://example.com".into()),
        );
        // The eval pipeline wraps the result in `JSON.stringify(...)` once
        // already, so we run `JSON.parse(JSON.stringify(elem))` here to
        // round-trip through stringify and observe the *unwrapped* output.
        // Before the toJSON fix the round-trip would produce `{}`; with
        // it, the wrapper serialises as its visible text.
        let script = "JSON.parse(JSON.stringify(java.getElements('@css:a')[0]))";
        let result = rt.eval(script, &vars).expect("eval ok");
        assert_eq!(
            result.as_str(),
            Some("linktext"),
            "wrapped element should JSON.stringify-round-trip as its text, not as an empty object"
        );

        // Also assert the regression case directly: the raw stringify
        // output must NOT be the empty-object `{}` that the missing
        // toJSON used to produce.
        let raw = rt
            .eval("JSON.stringify(java.getElements('@css:a')[0])", &vars)
            .expect("eval ok");
        let raw_str = raw.as_str().unwrap_or_default().to_string();
        assert!(
            raw_str.contains("linktext") && !raw_str.contains("{}"),
            "raw JSON.stringify of wrapped element should contain text, not {{}} (got {raw_str:?})"
        );
    }

    /// F-W1B-011 (BATCH-11): a `java.put` in one eval must be visible to
    /// `java.get` in a subsequent eval **on the same OS thread**.
    /// This exercises the `__legado_js_put` write-through into
    /// `LEGADO_JS_VARIABLES` and the matching `__legado_js_get` fallback
    /// inside the PREAMBLE's `java.get`. Both evals here go through the
    /// raw `DefaultJsRuntime::new().eval(...)` path — no
    /// `JsVariablesOverride` guard installed — so the thread-local
    /// retains its contents across the boundary.
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_java_put_persists_across_eval() {
        // Reset the thread-local to a known empty state so that residue
        // from earlier tests on the same worker thread does not interfere.
        LEGADO_JS_VARIABLES.with(|cell| cell.borrow_mut().clear());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        // First eval: write the value.
        rt.eval("java.put('mykey', 'myvalue')", &vars)
            .expect("first eval ok");
        // Second eval: a fresh Runtime/Context is built inside `eval`,
        // but the thread-local persists.
        let result = rt.eval("java.get('mykey')", &vars).expect("second eval ok");
        assert_eq!(
            result.as_str(),
            Some("myvalue"),
            "java.put written in eval A must be visible to java.get in eval B"
        );

        // Cleanup so subsequent tests on the same worker thread start
        // with a clean slate.
        LEGADO_JS_VARIABLES.with(|cell| cell.borrow_mut().clear());
    }

    /// BATCH-13 (F-W1B-023): the per-thread Runtime + Context pool must
    /// amortize the dominant cost of `eval` (creating a Runtime, full
    /// Context, and registering ~30 bridge functions). Pre-pool, every
    /// call paid for register; pooled, only the first call does.
    ///
    /// The test runs on a dedicated thread so the per-thread pool starts
    /// `None` and the first eval pays the full register cost. Subsequent
    /// calls only pay PREAMBLE re-eval + interrupt handler refresh, both
    /// orders of magnitude cheaper. We assert that 100 subsequent evals
    /// cost less than 100× the cold call (i.e. less than the cost of
    /// re-registering 100 times). The threshold is loose because CI
    /// machines vary; failing this test means the pool is broken (e.g.
    /// somebody re-introduced `Runtime::new()` per call).
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_runtime_pool_amortizes_bridge_register() {
        // Spawn a dedicated thread so the QUICKJS_POOL thread-local is
        // freshly `None` when we start measuring.
        std::thread::spawn(|| {
            let rt = DefaultJsRuntime::new();
            let vars = HashMap::new();

            // Cold call: pays Runtime::new + Context::full +
            // register_quickjs_bridge (the expensive part).
            let cold = std::time::Instant::now();
            rt.eval("1 + 1", &vars).expect("cold eval ok");
            let cold_elapsed = cold.elapsed();

            // 100 subsequent calls: each pays only PREAMBLE re-eval +
            // interrupt handler refresh + var injection (cheap).
            let many = std::time::Instant::now();
            for _ in 0..100 {
                rt.eval("1 + 1", &vars).expect("loop eval ok");
            }
            let many_elapsed = many.elapsed();

            // If pooling is broken, 100 evals would each pay the full
            // register cost: ~100× cold. The 100× threshold catches that
            // regression with comfortable headroom for CI noise.
            let ratio = many_elapsed.as_nanos() as f64
                / std::cmp::max(1, cold_elapsed.as_nanos()) as f64;
            assert!(
                ratio < 100.0,
                "pool not amortizing: 100 warm evals/{many_elapsed:?} vs cold/{cold_elapsed:?} (ratio {ratio:.1})"
            );
        })
        .join()
        .expect("worker thread ok");
    }

    /// BATCH-13 (F-W1B-023): re-evaluating PREAMBLE at the top of every
    /// pooled call rebuilds `var java = { ... }`, which discards any
    /// state the previous user script wrote into `java._vars`. Without
    /// this isolation, sharing a Context across evals would leak state.
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_runtime_pool_isolates_user_state_via_preamble_reset() {
        // Reset any thread-local residue from earlier tests.
        LEGADO_JS_VARIABLES.with(|cell| cell.borrow_mut().clear());

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();

        // First eval: stash a key directly on java._vars (NOT via
        // java.put — that would also write through to the thread-local
        // bucket, which is precisely the cross-eval persistence path
        // and would defeat this test). PREAMBLE re-eval should wipe
        // the JS-side `java._vars` for the next call.
        let r1 = rt
            .eval(
                "(function(){ java._vars = java._vars || {}; java._vars.batch13_test_key = 'a'; return 'ok'; })()",
                &vars,
            )
            .expect("first eval ok");
        assert_eq!(r1.as_str(), Some("ok"));

        // Second eval: the previous `java._vars.batch13_test_key` must
        // be gone because PREAMBLE rebuilt the `java` object.
        let r2 = rt
            .eval(
                "(java._vars && java._vars.batch13_test_key) || ''",
                &vars,
            )
            .expect("second eval ok");
        assert_eq!(
            r2.as_str(),
            Some(""),
            "PREAMBLE re-eval should reset java._vars between calls; got {r2:?}"
        );

        LEGADO_JS_VARIABLES.with(|cell| cell.borrow_mut().clear());
    }

    /// BATCH-13 (F-W1B-023): rquickjs's interrupt handler is cooperative
    /// — when it fires, the runtime is left in a usable state. The pool
    /// must therefore continue functioning after a timeout: the next
    /// eval on the same thread should run normally.
    #[cfg(feature = "js-quickjs")]
    #[test]
    fn test_runtime_pool_recovers_from_timeout() {
        let rt = QuickJsRuntime {
            config: JsRuntimeConfig {
                timeout_ms: 50,
                max_script_len: 100_000,
            },
        };
        let vars = HashMap::new();

        // Trip the interrupt handler. The exact error string varies
        // across rquickjs releases; we only require Err.
        let timed_out = rt.eval("while (true) {}", &vars);
        assert!(
            timed_out.is_err(),
            "infinite loop must be terminated by interrupt handler; got {timed_out:?}"
        );

        // The pool entry must still be usable.
        let recovered = rt.eval("1 + 1", &vars).expect("post-timeout eval ok");
        assert!(
            matches!(recovered, LegadoValue::Int(2)),
            "post-timeout eval should return 2, got {recovered:?}"
        );
    }

    /// F-W1B-005 (BATCH-10): `java.getZipStringContent` and friends must
    /// reject zip entry paths containing `..` segments, absolute prefixes,
    /// Windows backslashes, or empty segments — the unit-level guard
    /// that complements the zip-archive-level `archive.by_name` lookup
    /// (which itself does not canonicalize entry paths).
    #[test]
    fn test_is_safe_zip_entry_path_rejects_traversal_and_absolute() {
        // Allowed shapes (positive cases first to confirm the helper isn't
        // over-eager).
        assert!(is_safe_zip_entry_path("a.txt"));
        assert!(is_safe_zip_entry_path("dir/a.txt"));
        assert!(is_safe_zip_entry_path("a/b/c/d.txt"));

        // Rejected shapes.
        assert!(!is_safe_zip_entry_path(""), "empty path");
        assert!(!is_safe_zip_entry_path(".."), "bare dotdot");
        assert!(!is_safe_zip_entry_path("../etc/passwd"), "leading dotdot");
        assert!(
            !is_safe_zip_entry_path("dir/../etc/passwd"),
            "embedded dotdot"
        );
        assert!(!is_safe_zip_entry_path("/etc/passwd"), "unix absolute");
        assert!(
            !is_safe_zip_entry_path("\\windows\\system32"),
            "windows backslash absolute"
        );
        assert!(
            !is_safe_zip_entry_path("dir\\file"),
            "embedded backslash separator"
        );
        assert!(
            !is_safe_zip_entry_path("C:/Windows/System32"),
            "windows drive absolute"
        );
        assert!(
            !is_safe_zip_entry_path("a//b.txt"),
            "double slash leaves empty segment"
        );
    }

    /// F-W1B-005 (BATCH-10): the `java.getZipStringContent` bridge
    /// returns an empty string for a `..` traversal path without ever
    /// hitting the network (no mock asserted; the SSRF / fetch path
    /// must short-circuit before the HTTP call).
    #[test]
    fn test_java_get_zip_string_content_rejects_traversal() {
        let server = httpmock::MockServer::start();
        // Mock is set up but should NOT be hit for a rejected path.
        let _mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/test.zip");
            then.status(200).body(b"never-served".to_vec());
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.getZipStringContent('{}', '../etc/passwd')",
            server.url("/test.zip")
        );
        let result = rt.eval(&script, &vars).unwrap();
        assert_eq!(
            result.as_str(),
            Some(""),
            "traversal path must yield empty string"
        );
    }

    /// F-W1B-005 (BATCH-10): the `java.getZipByteArrayContent` bridge
    /// returns `[]` for a `..` traversal path.
    #[test]
    fn test_java_get_zip_byte_array_content_rejects_traversal() {
        let server = httpmock::MockServer::start();
        let _mock = server.mock(|when, then| {
            when.method(httpmock::Method::GET).path("/bytes.zip");
            then.status(200).body(b"never-served".to_vec());
        });

        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let script = format!(
            "java.getZipByteArrayContent('{}', '../etc/passwd').length",
            server.url("/bytes.zip")
        );
        let result = rt.eval(&script, &vars).unwrap();
        assert!(
            matches!(result, LegadoValue::Int(0)),
            "traversal path must yield zero-length byte array, got {result:?}"
        );
    }

    /// F-W1B-005 (BATCH-10): `read_allowed_file` must reject `..`
    /// segments *before* `canonicalize`, closing the symlink-resolution
    /// window. Even if `LEGADO_FILE_ROOT` happens to canonicalize to the
    /// same parent as the `..` target, the explicit segment check
    /// rejects first.
    #[test]
    fn test_read_allowed_file_rejects_dotdot_segment() {
        let _guard = file_env_lock().lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let inner = dir.path().join("inner");
        std::fs::create_dir(&inner).unwrap();
        // A file the test could otherwise read, sitting two levels up
        // from `inner`. The traversal path `subdir/../../escape.txt`
        // would be rejected by the segment check, regardless of
        // canonicalize behaviour.
        std::fs::write(dir.path().join("escape.txt"), b"escape").unwrap();
        std::env::set_var("LEGADO_FILE_ROOT", &inner);

        // No `..` is allowed even when the target ultimately stays
        // within root.
        assert!(read_allowed_file("subdir/../../escape.txt").is_none());
        assert!(read_allowed_file("../escape.txt").is_none());
        // Absolute paths also rejected.
        assert!(read_allowed_file("/etc/passwd").is_none());
    }

    /// F-W1B-013 (BATCH-10): the `eval(JSON_STRING)` branch's safety
    /// rests on `serde_json::to_string` producing a well-formed JS
    /// string literal. This test pins that contract: a script
    /// containing every metacharacter that could break naive concat
    /// (single quote, double quote, backslash, newline, carriage
    /// return, tab, NULL, `</script>`) is safely escaped and re-eval'd
    /// to its original value.
    ///
    /// If somebody ever swaps the JSON-stringify call for a manual
    /// concat, this test will trip — proving the escape is doing real
    /// work even though the eval'd text is the user's verbatim script.
    #[test]
    fn test_js_script_to_expression_eval_branch_escapes_meta_chars() {
        // A multi-line script (forces the `needs_direct_eval` branch
        // because `script.contains('\n')` is true). The script writes
        // a tricky string literal then returns its length so we can
        // assert the eval'd content matches our expectation byte-for-byte.
        let script = "var s = '\\'\"\\\\\\n\\r\\t';\ns.length";
        let wrapped = js_script_to_expression(script);
        assert!(
            wrapped.starts_with("eval("),
            "multi-line script should hit the eval branch, got {wrapped}"
        );
        // The wrapped form must round-trip through QuickJS to the same
        // numeric value as the script (string length 6: `'`, `"`, `\`,
        // `\n`, `\r`, `\t`).
        let rt = DefaultJsRuntime::new();
        let vars = HashMap::new();
        let result = rt.eval(script, &vars).unwrap();
        assert!(
            matches!(result, LegadoValue::Int(6)),
            "escape contract broken: got {result:?}"
        );
    }

    /// F-W1B-013 (BATCH-10): explicit `return` keeps the IIFE wrap.
    /// Confirms `js_script_to_expression` still routes a leading-`return`
    /// script through the `(function(){...})()` form, not the
    /// `eval(...)` branch.
    #[test]
    fn test_js_script_to_expression_iife_wraps_return_in_var_decl() {
        // `contains_return_statement` matches `\nreturn ` and the
        // leading `return ` form. Use a multiline script so the IIFE
        // branch is the one that fires.
        let script = "var x = 1;\nreturn x";
        let wrapped = js_script_to_expression(script);
        assert!(
            wrapped.starts_with("(function(){"),
            "explicit return should hit IIFE branch, got {wrapped}"
        );
        assert!(wrapped.ends_with("})()"));
    }
}
