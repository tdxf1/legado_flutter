//! # bridge - Flutter-Rust 桥接层
//!
//! 通过 flutter_rust_bridge 实现 Dart 与 Rust 的双向调用。

mod frb_generated;
// 批次 13 (05-19): 本地书导入辅助函数。pub(crate) 即可，仅供
// `api::import_local_book` 内部使用。
pub(crate) mod local_book;
// 批次 69 (05-20, BATCH-07b): 跨 DAO 事务 helper，仅 bridge 内部使用，
// 不暴露给 FRB。
pub(crate) mod transaction;

pub use api::*;
pub mod api;

/// 测试函数 - 验证桥接是否正常工作
pub fn ping() -> String {
    "pong".to_string()
}
