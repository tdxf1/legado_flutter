# Backup AES Thinking Guide

> **Purpose**: Decide whether to use, extend, or replace `legado_aes` before touching backup-related code.

---

## The Setup

`core/core-storage/src/legado_aes.rs` exposes 4 public functions:

- `legado_md5_key(password)`
- `encrypt_legado_aes(plain, password)`
- `decrypt_legado_aes(b64, password)`
- `try_decrypt_or_passthrough_array(text, password)`

The algorithm is **AES-128 / ECB / PKCS7 / MD5-derived key**, chosen for bit-level compatibility with the original Legado Android app's `BackupAES.kt`. The module's top doc-comment opens with a "⚠ 弱混淆而非真加密" warning, and the first `encrypt_legado_aes` / `decrypt_legado_aes` call per process emits a `tracing::warn!` once via `WEAK_CRYPTO_WARNED: Once`.

This module exists for compat with the original Legado backup zip format. It is **not** a real encryption layer.

---

## The Problem

Two failure modes recur whenever someone touches backup code:

1. **Treating the module as production crypto.** ECB leaks structure, MD5 is a broken KDF, and PKCS7 lets wrong keys "decrypt" into garbage. A new feature that calls `encrypt_legado_aes` on user data outside the Legado-compat path silently builds a security hole.
2. **Adding a v2 strong-encryption path prematurely.** As of BATCH-09, the legado_aes module is **not yet wired into the actual backup zip pipeline** — `backup_dao::export_to_zip` still writes plaintext JSON. Building a v2 (AES-GCM + Argon2id) "for safety" introduces ~400 lines of cross-language UI work for zero real users today.

Both mistakes were avoided in BATCH-09 by stopping to ask the questions below.

---

## Before You Touch `legado_aes`

### 1. Why are you reaching for it?

| Reason | Verdict |
|---|---|
| "I need to encrypt user data for storage." | **Stop.** Use a modern primitive (`aes-gcm` + `argon2`). Don't extend `legado_aes`. |
| "I'm parsing a Legado-format backup zip and need to decrypt `servers.json` / `web_dav_password`." | OK. Use `try_decrypt_or_passthrough_array`. |
| "I'm exporting to a Legado-format backup zip and need to write the encrypted form." | OK. Use `encrypt_legado_aes`. **Add a context comment** stating this is for compat. |
| "I want a quick checksum / token / keyed hash." | **Stop.** Use `sha2::Sha256`. |

### 2. Are you about to bypass the validation?

`try_decrypt_or_passthrough_array` does three checks in order:

1. JSON Array passthrough (legitimate: original Legado wrote a plaintext `[]` in some versions).
2. AES decrypt.
3. **Strong validation**: the decrypted bytes must parse to a JSON Array (BATCH-09 added this).

Don't skip step 3. Decrypted-but-not-validated strings have appeared in the wild — see `findings-rust-data.md::F-W1A-003`.

### 3. Are you about to add a v2 path?

Before adding v2 strong encryption, confirm:

- **There is at least one real user with v1 ciphertext.** Today there is none. v1 is not even wired into export/import.
- **There is a UX plan for v1 → v2 migration.** Without it, users with v1 backups can't restore after upgrade.
- **There is a Flutter UI to choose v2.** Otherwise the option is invisible.
- **There is a magic-byte / filename convention to distinguish v1 vs v2 in the same zip.** Without it, `import_from_zip` can't dispatch.

If any answer is "no", v2 is premature. Open a roadmap batch instead and ship the prerequisites.

---

## When You Find Backup Code That Looks Wrong

Look for these markers:

- A call to `encrypt_legado_aes` outside the Legado-compat code path.
- A call to `decrypt_legado_aes` directly (instead of `try_decrypt_or_passthrough_array`) without an immediate `serde_json::from_str` validation step.
- A new function that `tracing::warn!`s "weak crypto" but doesn't actually use `legado_aes`. The warning is shared via `WEAK_CRYPTO_WARNED`; don't fork it.
- Backup paths that read entire zip entries with `read_to_string` without going through the `MAX_ZIP_ENTRY_SIZE` / `MAX_ZIP_TOTAL_SIZE` cap (BATCH-09 added the cap; the constants are public for reuse).

For each marker, prefer fixing the call site to wrong-then-add-a-test rather than building a workaround.

---

## Reference

- Module: `core/core-storage/src/legado_aes.rs`
- Zip cap: `core/core-storage/src/backup_dao.rs::MAX_ZIP_ENTRY_SIZE` / `MAX_ZIP_TOTAL_SIZE`
- Findings: `.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md` entries F-W1A-001 / F-W1A-003 / F-W1A-012
- Audit notes: `.trellis/tasks/archive/2026-05/05-21-batch-09-aes-hardening/research/batch09-audit.md`
- Spec doc: [../rust-core/quality-and-anti-patterns.md](../rust-core/quality-and-anti-patterns.md)

---

**Core Principle**: This module exists for one job (Legado bit-level compat). Anything else needs a different tool.
