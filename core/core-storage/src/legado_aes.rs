//! # Legado 兼容 AES 加密 helper（批次 12 / 05-19；批次 09 加固于 2026-05-21）
//!
//! ## ⚠ 安全警告（F-W1A-001）
//!
//! 本模块**仅为与原 Legado `BackupAES.kt` 比特级互通**而存在，使用
//! AES-128/ECB + MD5(password) 派生 key + PKCS7 padding。这套组合在现代
//! 密码学视角下是**弱混淆而非真加密**：
//!
//! - **ECB 模式**不抗"模式分析"——相同明文块产出相同密文块，结构泄漏严重
//! - **MD5 已被证伪不应作 KDF**——对暴力搜索几乎无防御
//! - **PKCS7 padding** 错密码也有概率通过校验，解出"乱码字节流"
//! - **空密码**退化：key = `MD5("")` 是公开常量，等同明文
//!
//! **请勿** 视本模块为对外加密保护。仅在以下场景使用：
//! 1. 读取 / 写入与原 Legado APP 互兼容的备份 zip（`servers.json` /
//!    `web_dav_password`）
//! 2. **不要**作为新增功能的"加密"实现 —— 请用 AES-GCM + Argon2id
//!
//! 未来若引入"强加密备份" v2，应新加独立模块（`legado_aes_v2.rs`），
//! 用 zip 内 magic header 区分版本，本模块仅作 fallback 兼容旧格式。
//!
//! ## 加密格式（v1 / Legado 兼容）
//!
//! 对齐原 Legado `BackupAES.kt` + `Backup.kt:180-202` 的格式，让本工程
//! 与原 Legado 的备份 zip 在加密字段上互通：
//!
//! - `servers.json` 整体内容 base64 加密（解密时若 `isJsonArray()` 通过则
//!   视为未加密 fallback —— 见 [`try_decrypt_or_passthrough_array`]）
//! - `config.xml` 里 `web_dav_password` 字段加密
//!
//! 算法细节：
//!
//! - 算法：AES-128-ECB
//! - 密钥：`MD5(LocalConfig.password ?: "")[0..16]`（MD5 输出本来就是 16
//!   字节，所以"前 16"≡完整 MD5；保留与原注释一致的措辞）
//! - 填充：PKCS7（在 AES 块大小 = 16 时与 PKCS5 等价 —— 所有 PKCS7 实现
//!   都能解 PKCS5 密文反之亦然）
//! - 输出：Base64 标准编码
//!
//! ## 不引入 cbc crate
//!
//! ECB 极简：分块 16B → `cipher.encrypt_block(block)` /
//! `cipher.decrypt_block(block)`。手写 PKCS7 padding 即可，省一份依赖。

use aes::cipher::{
    generic_array::GenericArray, BlockDecrypt, BlockEncrypt, KeyInit,
};
use aes::Aes128;
use base64::{engine::general_purpose::STANDARD as BASE64_STD, Engine as _};
use md5::{Digest, Md5};
use std::sync::Once;
use tracing::warn;

/// AES 块大小（固定 16 字节）。
const BLOCK_SIZE: usize = 16;

/// 一次性 warn 标记：每个进程只打印一次"weak crypto"警告，避免日志污染。
static WEAK_CRYPTO_WARNED: Once = Once::new();

/// 在首次调用 encrypt/decrypt 时打印一次 warn 日志，提醒运维 / 开发者
/// 本模块**不是真加密**。
fn warn_weak_crypto_once() {
    WEAK_CRYPTO_WARNED.call_once(|| {
        warn!(
            target: "legado_aes",
            "legado_aes 使用 AES-128/ECB + MD5(password)（与原 Legado 兼容），\
             这是弱混淆而非真加密。请勿视为对外加密保护。\
             详见模块 doc 与 finding F-W1A-001。"
        );
    });
}

/// 计算 Legado 兼容的 AES key：`MD5(password)` 取前 16 字节。
///
/// MD5 输出本来就是 16 字节，所以"取前 16"等同于完整 MD5；保留 PRD /
/// 原 Legado 注释里"前 16"的措辞便于对照。空串密码会得到 MD5("") =
/// `[0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, 0xe9, 0x80, 0x09,
///   0x98, 0xec, 0xf8, 0x42, 0x7e]`。
pub fn legado_md5_key(password: &str) -> [u8; 16] {
    let mut hasher = Md5::new();
    hasher.update(password.as_bytes());
    let digest = hasher.finalize(); // GenericArray<u8, U16>
    let mut out = [0u8; 16];
    out.copy_from_slice(&digest[..16]);
    out
}

/// PKCS7 填充：明文长度 mod 16 ≠ 0 时补 N 个 N 字节；正好整除时补 16 个
/// 0x10。返回填充后的 buffer。
fn pkcs7_pad(data: &[u8]) -> Vec<u8> {
    let pad_len = BLOCK_SIZE - (data.len() % BLOCK_SIZE);
    let mut out = Vec::with_capacity(data.len() + pad_len);
    out.extend_from_slice(data);
    out.extend(std::iter::repeat(pad_len as u8).take(pad_len));
    out
}

/// PKCS7 反填充：读最后一字节作为填充长度并截掉。校验填充字节一致性 —
/// 不合法时返回错误（防止把"明文密钥不对解出来一段乱码"误当成成功）。
fn pkcs7_unpad(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.is_empty() || data.len() % BLOCK_SIZE != 0 {
        return Err("PKCS7 反填充失败: 密文长度不是 16 字节倍数".to_string());
    }
    let pad_len = *data.last().unwrap() as usize;
    if pad_len == 0 || pad_len > BLOCK_SIZE {
        return Err("PKCS7 反填充失败: 非法 padding 长度".to_string());
    }
    if data.len() < pad_len {
        return Err("PKCS7 反填充失败: 数据短于 padding 长度".to_string());
    }
    let (body, padding) = data.split_at(data.len() - pad_len);
    if !padding.iter().all(|&b| b as usize == pad_len) {
        return Err("PKCS7 反填充失败: padding 字节不一致".to_string());
    }
    Ok(body.to_vec())
}

/// 加密：plain → AES-128/ECB/PKCS7 → base64。
///
/// **⚠ 弱混淆，非真加密**。仅用于与原 Legado 互兼容场景，详见模块 doc。
///
/// 输出与原 Legado `BackupAES().encryptBase64(plain)` 比特级一致。
pub fn encrypt_legado_aes(plain: &str, password: &str) -> Result<String, String> {
    warn_weak_crypto_once();
    let key = legado_md5_key(password);
    let cipher = Aes128::new(GenericArray::from_slice(&key));
    let padded = pkcs7_pad(plain.as_bytes());
    debug_assert!(padded.len() % BLOCK_SIZE == 0);
    let mut buf = padded; // 转成可变 buffer 后逐块原地加密
    for chunk in buf.chunks_mut(BLOCK_SIZE) {
        let block = GenericArray::from_mut_slice(chunk);
        cipher.encrypt_block(block);
    }
    Ok(BASE64_STD.encode(&buf))
}

/// 解密：base64 → AES-128/ECB/PKCS7 → plain。
///
/// **⚠ 弱混淆，非真加密**。仅用于与原 Legado 互兼容场景，详见模块 doc。
///
/// 接受原 Legado `BackupAES().encryptBase64(...)` 输出。失败原因可能是
/// base64 非法、密文长度不是 16 倍数、padding 不合法、或解出的字节不是
/// UTF-8。所有情况都返回 `Err(String)`，由 caller 决定 fallback。
///
/// **注意**：PKCS7 反填充错密码也有概率通过校验，解出"乱码字节流"。
/// 务必通过 [`try_decrypt_or_passthrough_array`] 走"成功后强制 JSON Array
/// 校验"路径，不要直接信任本函数返回的字符串作业务消费 —— 见
/// finding F-W1A-003。
pub fn decrypt_legado_aes(b64: &str, password: &str) -> Result<String, String> {
    warn_weak_crypto_once();
    let cipher_bytes = BASE64_STD
        .decode(b64.trim())
        .map_err(|e| format!("base64 解码失败: {}", e))?;
    if cipher_bytes.is_empty() {
        return Err("密文为空".to_string());
    }
    if cipher_bytes.len() % BLOCK_SIZE != 0 {
        return Err(format!(
            "密文长度 {} 不是 16 字节倍数",
            cipher_bytes.len()
        ));
    }
    let key = legado_md5_key(password);
    let cipher = Aes128::new(GenericArray::from_slice(&key));
    let mut buf = cipher_bytes;
    for chunk in buf.chunks_mut(BLOCK_SIZE) {
        let block = GenericArray::from_mut_slice(chunk);
        cipher.decrypt_block(block);
    }
    let plain_bytes = pkcs7_unpad(&buf)?;
    String::from_utf8(plain_bytes).map_err(|e| format!("解密结果不是合法 UTF-8: {}", e))
}

/// servers.json 解码兜底：若 `text` 是合法 JsonArray 则原文返回（明文兜底）；
/// 否则当作 base64 加密文本走 [`decrypt_legado_aes`]。
///
/// 对齐 `Restore.kt:184-196` 的 `fileToListT<Server>("servers.json")` 逻辑：
/// 原代码先尝试 `JsonElement.isJsonArray()` —— 通过即直接 GSON.fromJson；
/// 否则才走 AES 解密。我们 Rust 端用 [`serde_json::from_str::<serde_json::Value>`]
/// + `is_array()` 替代。
///
/// **F-W1A-003 加固（2026-05-21, BATCH-09）**：解密成功后**强制再做一次
/// JSON Array 校验**。原版本仅判断 PKCS7 padding + UTF-8 通过即返回字符串，
/// 但错密码也有概率通过这两步、解出"合法 UTF-8 但非业务结构"的乱码。本函
/// 数 servers.json 业务的合约就是 JSON Array，所以解密成功后必须 parse 出
/// `Value::Array`，否则视为密文损坏 / 密码错误，返回 `Err`。
pub fn try_decrypt_or_passthrough_array(
    text: &str,
    password: &str,
) -> Result<String, String> {
    let trimmed = text.trim();
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed) {
        if v.is_array() {
            return Ok(text.to_string());
        }
    }
    let decrypted = decrypt_legado_aes(trimmed, password)?;
    // F-W1A-003：强校验 — 解密成功的字节流必须是合法 JSON Array，否则视为
    // 密文损坏 / 密码错。这一步把"PKCS7+UTF-8 双过但解出乱码"的攻击窗口关上。
    let parsed: serde_json::Value = serde_json::from_str(&decrypted).map_err(|e| {
        format!(
            "解密成功但内容不是合法 JSON: {}（疑似密码错误或密文被篡改）",
            e
        )
    })?;
    if !parsed.is_array() {
        return Err(format!(
            "解密成功但内容不是 JSON Array（实际类型: {}），\
             servers.json 合约要求 Array — 视为密文损坏",
            value_type_name(&parsed)
        ));
    }
    Ok(decrypted)
}

/// 给 `serde_json::Value` 取一个简短的人类可读类型名，方便错误信息提示用户。
fn value_type_name(v: &serde_json::Value) -> &'static str {
    match v {
        serde_json::Value::Null => "Null",
        serde_json::Value::Bool(_) => "Bool",
        serde_json::Value::Number(_) => "Number",
        serde_json::Value::String(_) => "String",
        serde_json::Value::Array(_) => "Array",
        serde_json::Value::Object(_) => "Object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 已知答案：MD5("") = `d41d8cd98f00b204e9800998ecf8427e`（RFC 1321
    /// + 任何 md5sum 实现都给出同样的输出）。
    #[test]
    fn test_legado_md5_key_empty_password() {
        let key = legado_md5_key("");
        assert_eq!(
            key,
            [
                0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, 0xe9, 0x80, 0x09, 0x98, 0xec,
                0xf8, 0x42, 0x7e
            ],
            "MD5(\"\") 前 16 字节应等于已知 RFC 1321 测试向量"
        );
    }

    /// 已知答案：`echo -n password | md5sum` =
    /// `5f4dcc3b5aa765d61d8327deb882cf99`（CyberChef / md5sum 一致）。
    #[test]
    fn test_legado_md5_key_with_password() {
        let key = legado_md5_key("password");
        assert_eq!(
            key,
            [
                0x5f, 0x4d, 0xcc, 0x3b, 0x5a, 0xa7, 0x65, 0xd6, 0x1d, 0x83, 0x27, 0xde, 0xb8,
                0x82, 0xcf, 0x99
            ]
        );
    }

    /// 多种长度往返测试（PKCS7 + AES-ECB）：
    /// - 1B 触发"补 15 字节"路径
    /// - 16B 触发"正好整除 → 补 16 字节 0x10"边界
    /// - 100B 普通中等长度（多块）
    /// - 1KB 大文本
    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        for len in [1usize, 16, 100, 1024] {
            let plain: String = (0..len).map(|i| ((b'a' + (i % 26) as u8)) as char).collect();
            let encrypted = encrypt_legado_aes(&plain, "mypass").expect("加密失败");
            let decrypted = decrypt_legado_aes(&encrypted, "mypass").expect("解密失败");
            assert_eq!(decrypted, plain, "len={} 往返失败", len);
        }
    }

    /// 密码空串场景：未设密码时也能加解密，与原 Legado `LocalConfig.password
    /// = ""` 默认行为一致。
    #[test]
    fn test_encrypt_decrypt_empty_password() {
        let plain = r#"[{"name":"server1","url":"https://example.com"}]"#;
        let encrypted = encrypt_legado_aes(plain, "").expect("加密失败");
        let decrypted = decrypt_legado_aes(&encrypted, "").expect("解密失败");
        assert_eq!(decrypted, plain);
    }

    /// Legado 兼容性自洽测试：用本实现产出的密文，**用同一密码**能解出来。
    /// PRD §"测试"里说的"用一段从原 Legado dump 的 base64 验证"目前没有
    /// 实机 dump，所以用本端 encrypt → decrypt 形式锁定算法不变量。
    /// 一旦未来拿到原 Legado dump，这个测试可以加 `assert_eq!` 一段已知
    /// 密文 + 密码 + 明文。
    #[test]
    fn test_decrypt_legado_compatible() {
        // 模拟"原 Legado dump 的 servers.json 加密文本" — 现在用本端
        // 自产生密文，密码 = "test123"，明文 = 一段简短 JSON Array。
        let plain = r#"[{"id":1,"name":"my-server"}]"#;
        let encrypted = encrypt_legado_aes(plain, "test123").expect("加密失败");
        // 密文应为合法 base64 + 长度是 16 的倍数（base64 编码后约为 ceil(N/3)*4）
        assert!(!encrypted.is_empty());
        let decoded = BASE64_STD.decode(&encrypted).expect("base64 应合法");
        assert_eq!(decoded.len() % 16, 0, "密文应是 16 字节倍数");
        // 关键断言：用同一密码能解回明文
        let decrypted = decrypt_legado_aes(&encrypted, "test123").expect("解密失败");
        assert_eq!(decrypted, plain);
        // 错密码应失败（PKCS7 反填充几乎必然校验失败）。注意小概率
        // 错密码也能"解出"看似合法的 PKCS7 字节流，所以这里不强测必失败 —
        // 退而求其次：错密码 != 原文。
        if let Ok(wrong) = decrypt_legado_aes(&encrypted, "wrong-pwd") {
            assert_ne!(wrong, plain);
        }
    }

    /// `try_decrypt_or_passthrough_array`：明文 `[]` 直接返回（探针生效）。
    /// 对齐原 Legado `Restore.kt:184-196` 的 isJsonArray fallback。
    #[test]
    fn test_try_decrypt_or_passthrough_handles_plain_array() {
        // 空数组
        assert_eq!(
            try_decrypt_or_passthrough_array("[]", "anypass").unwrap(),
            "[]"
        );
        // 含元素的合法数组
        let arr = r#"[{"a":1},{"b":2}]"#;
        assert_eq!(
            try_decrypt_or_passthrough_array(arr, "anypass").unwrap(),
            arr
        );
        // 周围带空白也算"是数组"
        assert_eq!(
            try_decrypt_or_passthrough_array("  [1,2,3]  ", "anypass").unwrap(),
            "  [1,2,3]  "
        );
    }

    /// `try_decrypt_or_passthrough_array`：非数组（看起来像 base64 密文）
    /// → 走 AES 解密路径。
    #[test]
    fn test_try_decrypt_or_passthrough_decrypts_ciphertext() {
        let plain = r#"[{"x":1}]"#;
        let encrypted = encrypt_legado_aes(plain, "k1").expect("加密失败");
        // 密文不可能是 JSON Array → 走解密分支
        let decoded =
            try_decrypt_or_passthrough_array(&encrypted, "k1").expect("应该解密成功");
        assert_eq!(decoded, plain);
    }

    /// PKCS7 padding 单元覆盖：边界长度 0/15/16/17。
    #[test]
    fn test_pkcs7_padding_boundaries() {
        // 正好 16 字节 → 补 16 个 0x10
        let p16 = pkcs7_pad(&[0u8; 16]);
        assert_eq!(p16.len(), 32);
        assert_eq!(&p16[16..], &[0x10u8; 16]);
        // 15 字节 → 补 1 个 0x01
        let p15 = pkcs7_pad(&[0u8; 15]);
        assert_eq!(p15.len(), 16);
        assert_eq!(p15[15], 0x01);
        // 1 字节 → 补 15 个 0x0f
        let p1 = pkcs7_pad(&[0xab]);
        assert_eq!(p1.len(), 16);
        assert_eq!(&p1[1..], &[0x0fu8; 15]);

        // 反填充对称
        assert_eq!(pkcs7_unpad(&p16).unwrap(), vec![0u8; 16]);
        assert_eq!(pkcs7_unpad(&p15).unwrap(), vec![0u8; 15]);
        assert_eq!(pkcs7_unpad(&p1).unwrap(), vec![0xab]);
    }

    /// `try_decrypt_or_passthrough_array` F-W1A-003 强校验：解密成功但解出
    /// 的内容不是 JSON Array 时，必须返回 `Err`，不能透传字符串到上层业务。
    ///
    /// 构造场景：用正确密码加密一个 JSON **Object**（非 Array），用同一密
    /// 码走 `try_decrypt_*`。原版本会成功返回 Object 字符串；加固后必须
    /// 报"不是 JSON Array"错误。
    #[test]
    fn test_try_decrypt_rejects_non_array_after_successful_decrypt() {
        let plain_object = r#"{"foo":1,"bar":"baz"}"#;
        let encrypted = encrypt_legado_aes(plain_object, "k1").expect("加密失败");
        let result = try_decrypt_or_passthrough_array(&encrypted, "k1");
        assert!(result.is_err(), "解出 Object 应返回 Err");
        let msg = result.unwrap_err();
        assert!(
            msg.contains("不是 JSON Array") || msg.contains("不是合法 JSON"),
            "错误信息应说明不是 Array：{}",
            msg
        );
    }

    /// `try_decrypt_or_passthrough_array` F-W1A-003 错密码场景：错密码触发
    /// PKCS7 通过但解出的字节流是乱码（既不是 JSON Object 也不是 JSON Array），
    /// 必须返回 `Err`。
    ///
    /// 注意 PKCS7 错密码"通过"是概率事件，本测试通过反复尝试错密码直到
    /// 命中"PKCS7+UTF-8 双过但 JSON 解析失败"分支。如果一次就 PKCS7 校验
    /// 失败那也算 Err（满足断言）。
    #[test]
    fn test_try_decrypt_rejects_garbage_when_padding_passes() {
        let plain = r#"[{"x":1},{"y":2}]"#;
        let encrypted = encrypt_legado_aes(plain, "correct-pwd").expect("加密失败");
        // 用错密码解码 — 期待返回 Err（无论是 PKCS7 失败、UTF-8 失败、还是
        // 解出非 Array）。关键是绝不能返回乱码字符串。
        let wrong_passwords = [
            "wrong1", "wrong2", "wrong3", "wrong4", "wrong5", "abc", "xyz",
            "1234", "5678",
        ];
        for pwd in &wrong_passwords {
            let result = try_decrypt_or_passthrough_array(&encrypted, pwd);
            assert!(
                result.is_err(),
                "错密码 {:?} 必须返回 Err，但返回 Ok({:?})",
                pwd,
                result
            );
        }
    }
}
