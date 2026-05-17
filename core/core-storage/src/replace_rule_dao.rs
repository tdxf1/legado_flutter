//! # 替换规则 DAO (Data Access Object)
//!
//! 提供替换规则相关的数据库操作。
//! 对应原 Legado 的 ReplaceRule 实体操作 (data/entities/ReplaceRule.kt)

use super::models::ReplaceRule;
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::{debug, info};
use uuid::Uuid;

/// 替换规则 DAO
pub struct ReplaceRuleDao<'a> {
    conn: &'a Connection,
}

impl<'a> ReplaceRuleDao<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入或更新替换规则。R24 schema 含 scope/scope_title/scope_content/exclude_scope。
    pub fn upsert(&self, rule: &ReplaceRule) -> SqlResult<()> {
        debug!("插入/更新替换规则: {}", rule.name);

        self.conn.execute(
            "INSERT INTO replace_rules (
                id, name, pattern, replacement, enabled,
                scope, scope_title, scope_content, exclude_scope,
                sort_number, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                pattern = excluded.pattern,
                replacement = excluded.replacement,
                enabled = excluded.enabled,
                scope = excluded.scope,
                scope_title = excluded.scope_title,
                scope_content = excluded.scope_content,
                exclude_scope = excluded.exclude_scope,
                sort_number = excluded.sort_number,
                updated_at = excluded.updated_at",
            params![
                rule.id,
                rule.name,
                rule.pattern,
                rule.replacement,
                rule.enabled as i32,
                rule.scope,
                rule.scope_title as i32,
                rule.scope_content as i32,
                rule.exclude_scope,
                rule.sort_number,
                rule.created_at,
                rule.updated_at,
            ],
        )?;

        Ok(())
    }

    /// 根据 ID 获取替换规则
    pub fn get_by_id(&self, id: &str) -> SqlResult<Option<ReplaceRule>> {
        let mut stmt = self.conn.prepare(SELECT_COLUMNS_SQL)?;

        let mut rows = stmt.query(params![id])?;

        if let Some(row) = rows.next()? {
            Ok(Some(replace_rule_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// 获取所有替换规则（按排序号）
    pub fn get_all(&self) -> SqlResult<Vec<ReplaceRule>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, pattern, replacement, enabled,
                    scope, scope_title, scope_content, exclude_scope,
                    sort_number, created_at, updated_at
             FROM replace_rules ORDER BY sort_number ASC",
        )?;

        let rows = stmt.query_map([], replace_rule_from_row)?;
        rows.collect()
    }

    /// 获取所有启用的替换规则
    pub fn get_enabled(&self) -> SqlResult<Vec<ReplaceRule>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, pattern, replacement, enabled,
                    scope, scope_title, scope_content, exclude_scope,
                    sort_number, created_at, updated_at
             FROM replace_rules WHERE enabled = 1 ORDER BY sort_number ASC",
        )?;

        let rows = stmt.query_map([], replace_rule_from_row)?;
        rows.collect()
    }

    /// 删除替换规则
    pub fn delete(&self, id: &str) -> SqlResult<()> {
        info!("删除替换规则: {}", id);
        self.conn
            .execute("DELETE FROM replace_rules WHERE id = ?", params![id])?;
        Ok(())
    }

    /// 启用/禁用替换规则
    pub fn set_enabled(&self, id: &str, enabled: bool) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE replace_rules SET enabled = ?, updated_at = ? WHERE id = ?",
            params![enabled as i32, Utc::now().timestamp(), id],
        )?;
        Ok(())
    }

    /// 更新排序号
    pub fn update_order(&self, id: &str, sort_number: i32) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE replace_rules SET sort_number = ?, updated_at = ? WHERE id = ?",
            params![sort_number, Utc::now().timestamp(), id],
        )?;
        Ok(())
    }

    /// 创建新替换规则（便捷函数）。
    ///
    /// R24: 默认创建全局正文规则（scope=None, scope_content=true,
    /// scope_title=false）。需要自定义作用范围的 caller 应该构造
    /// 完整 [`ReplaceRule`] 后调用 [`upsert`]。
    pub fn create(
        &self,
        name: &str,
        pattern: &str,
        replacement: &str,
    ) -> SqlResult<ReplaceRule> {
        let now = Utc::now().timestamp();
        let rule = ReplaceRule {
            id: Uuid::new_v4().to_string(),
            name: name.to_string(),
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            enabled: true,
            scope: None,
            scope_title: false,
            scope_content: true,
            exclude_scope: None,
            sort_number: 0,
            created_at: now,
            updated_at: now,
        };

        self.upsert(&rule)?;
        Ok(rule)
    }
}

const SELECT_COLUMNS_SQL: &str = "SELECT id, name, pattern, replacement, enabled,
            scope, scope_title, scope_content, exclude_scope,
            sort_number, created_at, updated_at
     FROM replace_rules WHERE id = ?";

/// 从数据库行转换到 ReplaceRule 结构体
fn replace_rule_from_row(row: &rusqlite::Row) -> SqlResult<ReplaceRule> {
    Ok(ReplaceRule {
        id: row.get(0)?,
        name: row.get(1)?,
        pattern: row.get(2)?,
        replacement: row.get(3)?,
        enabled: row.get::<_, i32>(4)? != 0,
        scope: row.get(5)?,
        scope_title: row.get::<_, i32>(6)? != 0,
        scope_content: row.get::<_, i32>(7)? != 0,
        exclude_scope: row.get(8)?,
        sort_number: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}
