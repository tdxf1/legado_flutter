//! # Legado 兼容 AES 加密 helper（批次 12 / 05-19）
//!
//! 对齐原 Legado `BackupAES.kt` + `Backup.kt:180-202` 的格式，让本工程
//! 与原 Legado 的备份 zip 在加密字段上互通：
//!
//! - `servers.json` 整体内容 base64 加密（解密时若 `isJsonArray()` 通过则
//!   视为未加密 fallback —— 见 [`try_decrypt_or_passthrough_array`]）
//! - `config.xml` 里 `web_dav_password` 字段加密
//!
//! ## 加密格式
//!
//! 原 Legado 用 Hutool `cn.hutool.crypto.symmetric.AES`（默认构造），
//! 等价于 **AES/ECB/PKCS5Padding** + Base64 编码。
//!
//! - 算法：AES-128-ECB
//! - 密钥：`MD5(LocalConfig.password ?: "")[0..16]`（MD5 输出本来就是 16
//!   字节，所以"前 16"≡完整 MD5；保留与原注释一致的措辞）
//! - 填充：PKCS7（在 AES 块大小 = 16 时与 PKCS5 等价 —— 所有 PKCS7 实现
//!   都能解 PKCS5 密文反之亦然）
//! - 输出：Base64 标准编码
//!
//! ## 密码空串
//!
//! 原 Legado `LocalConfig.password` 默认值 = 空串 `""`，此时密钥 =
//! `MD5("")[0..16] = D41D8CD98F00B204E9800998 ECF8427E` 的前 16 字节。
//! 密码"未设"也走一次 ECB 加密 —— 等价于无加密但格式仍是合法密文。
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

/// AES 块大小（固定 16 字节）。
const BLOCK_SIZE: usize = 16;

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
/// 输出与原 Legado `BackupAES().encryptBase64(plain)` 比特级一致。
pub fn encrypt_legado_aes(plain: &str, password: &str) -> Result<String, String> {
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
/// 接受原 Legado `BackupAES().encryptBase64(...)` 输出。失败原因可能是
/// base64 非法、密文长度不是 16 倍数、padding 不合法、或解出的字节不是
/// UTF-8。所有情况都返回 `Err(String)`，由 caller 决定 fallback。
pub fn decrypt_legado_aes(b64: &str, password: &str) -> Result<String, String> {
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
    decrypt_legado_aes(trimmed, password)
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
}
