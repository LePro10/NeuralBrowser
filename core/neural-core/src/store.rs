// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! SQLite-backed persistence: history, bookmarks, session, settings and
//! address-bar suggestions.

use crate::NeuralError;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, NeuralError>;

/// Ordered schema migrations; index + 1 is the `user_version` after applying.
const MIGRATIONS: &[&str] = &["CREATE TABLE history (
        id INTEGER PRIMARY KEY,
        url TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL DEFAULT '',
        host TEXT NOT NULL DEFAULT '',
        search_text TEXT NOT NULL DEFAULT '',
        last_visit_ms INTEGER NOT NULL,
        visit_count INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX history_last_visit ON history(last_visit_ms DESC);
    CREATE INDEX history_host ON history(host);
    CREATE VIRTUAL TABLE history_fts USING fts5(
        search_text, content='history', content_rowid='id', tokenize='trigram');
    CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
        INSERT INTO history_fts(rowid, search_text) VALUES (new.id, new.search_text);
    END;
    CREATE TRIGGER history_ad AFTER DELETE ON history BEGIN
        INSERT INTO history_fts(history_fts, rowid, search_text)
            VALUES ('delete', old.id, old.search_text);
    END;
    CREATE TRIGGER history_au AFTER UPDATE ON history BEGIN
        INSERT INTO history_fts(history_fts, rowid, search_text)
            VALUES ('delete', old.id, old.search_text);
        INSERT INTO history_fts(rowid, search_text) VALUES (new.id, new.search_text);
    END;
    CREATE TABLE folders (
        id INTEGER PRIMARY KEY,
        uuid TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        modified_ms INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE bookmarks (
        id INTEGER PRIMARY KEY,
        uuid TEXT NOT NULL UNIQUE,
        url TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        folder_id INTEGER REFERENCES folders(id),
        modified_ms INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX bookmarks_url ON bookmarks(url);
    CREATE TABLE session_tabs (
        id TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        title TEXT NOT NULL,
        pinned INTEGER NOT NULL,
        position INTEGER NOT NULL,
        last_active_ms INTEGER NOT NULL
    );
    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);"];

/// One visited page.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryEntry {
    pub id: i64,
    pub url: String,
    pub title: String,
    pub last_visit_ms: i64,
    pub visit_count: u32,
}

/// A bookmark. `uuid` is stable across devices; `modified_ms` supports sync.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Bookmark {
    pub id: i64,
    pub uuid: String,
    pub url: String,
    pub title: String,
    pub folder_id: Option<i64>,
    pub modified_ms: i64,
}

/// A bookmark folder.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Folder {
    pub id: i64,
    pub uuid: String,
    pub name: String,
    pub modified_ms: i64,
}

/// Persisted state of one tab.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TabState {
    pub id: String,
    pub url: String,
    pub title: String,
    pub pinned: bool,
    pub position: u32,
    pub last_active_ms: i64,
}

/// A saved browsing session.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Session {
    pub tabs: Vec<TabState>,
    pub active_tab_id: Option<String>,
}

/// Where a suggestion came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SuggestionKind {
    History,
    Bookmark,
}

/// An address-bar suggestion; higher `score` is better.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Suggestion {
    pub url: String,
    pub title: String,
    pub kind: SuggestionKind,
    pub score: f64,
}

/// Thread-safe handle to the browser database.
#[derive(uniffi::Object)]
pub struct Store {
    conn: Mutex<Connection>,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

/// Lower-cased host without `www.`, port or credentials.
fn host_of(url: &str) -> String {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let auth = rest.split(['/', '?', '#']).next().unwrap_or("");
    let auth = auth.rsplit('@').next().unwrap_or("");
    let host = if auth.starts_with('[') {
        auth
    } else {
        auth.split(':').next().unwrap_or("")
    };
    let host = host.to_lowercase();
    host.strip_prefix("www.")
        .map_or(host.clone(), str::to_string)
}

fn search_text(url: &str, title: &str) -> String {
    format!("{} {}", url.to_lowercase(), title.to_lowercase())
}

fn like_escape(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        if matches!(c, '%' | '_' | '\\') {
            o.push('\\');
        }
        o.push(c);
    }
    o
}

/// Lower-cased query terms as LIKE patterns (`%term%`).
fn like_terms(query: &str) -> Vec<String> {
    query
        .split_whitespace()
        .map(|t| format!("%{}%", like_escape(&t.to_lowercase())))
        .collect()
}

/// Parsed history query: a LIKE condition over `search_text` (params
/// `?1..?n`, every term must match) and an optional FTS5 trigram expression
/// built from the terms of 3+ chars, used to find rare matches quickly.
struct HistoryFilter {
    like_cond: String,
    like_args: Vec<rusqlite::types::Value>,
    fts: Option<String>,
}

fn history_filter(query: &str) -> HistoryFilter {
    let mut conds = Vec::new();
    let mut like_args: Vec<rusqlite::types::Value> = Vec::new();
    let mut fts = Vec::new();
    for t in query.split_whitespace() {
        let t = t.to_lowercase();
        if t.chars().count() >= 3 {
            fts.push(format!("\"{}\"", t.replace('"', "\"\"")));
        }
        conds.push(format!(
            "search_text LIKE ?{} ESCAPE '\\'",
            like_args.len() + 1
        ));
        like_args.push(format!("%{}%", like_escape(&t)).into());
    }
    HistoryFilter {
        like_cond: conds.join(" AND "),
        like_args,
        fts: (!fts.is_empty()).then(|| fts.join(" AND ")),
    }
}

fn history_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<HistoryEntry> {
    Ok(HistoryEntry {
        id: r.get(0)?,
        url: r.get(1)?,
        title: r.get(2)?,
        last_visit_ms: r.get(3)?,
        visit_count: r.get(4)?,
    })
}

fn bookmark_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Bookmark> {
    Ok(Bookmark {
        id: r.get(0)?,
        uuid: r.get(1)?,
        url: r.get(2)?,
        title: r.get(3)?,
        folder_id: r.get(4)?,
        modified_ms: r.get(5)?,
    })
}

fn migrate(conn: &Connection) -> Result<()> {
    let current = conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))? as usize;
    if current > MIGRATIONS.len() {
        return Err(NeuralError::Database {
            message: format!("database schema version {current} is newer than supported"),
        });
    }
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(current) {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(sql)?;
        tx.execute_batch(&format!("PRAGMA user_version = {}", i + 1))?;
        tx.commit()?;
    }
    Ok(())
}

impl Store {
    fn from_conn(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "foreign_keys", true)?;
        migrate(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>> {
        self.conn.lock().map_err(|_| NeuralError::Internal {
            message: "database lock poisoned".into(),
        })
    }

    /// Core of `suggest`, with an injectable clock for tests.
    pub fn suggest_at(&self, query: &str, limit: u32, now: i64) -> Result<Vec<Suggestion>> {
        let terms = like_terms(query);
        if terms.is_empty() || limit == 0 {
            return Ok(vec![]);
        }
        let host_prefix = format!("{}%", like_escape(&query.trim().to_lowercase()));
        let conn = self.lock()?;
        let mut out: Vec<Suggestion> = Vec::new();

        // Bookmarks (few rows): fixed boost over any history entry.
        let cond = (0..terms.len())
            .map(|i| {
                format!(
                    "(lower(url) LIKE ?{0} ESCAPE '\\' OR lower(title) LIKE ?{0} ESCAPE '\\')",
                    i + 1
                )
            })
            .collect::<Vec<_>>()
            .join(" AND ");
        let sql = format!(
            "SELECT url, title FROM bookmarks WHERE deleted = 0 AND {cond} LIMIT {}",
            limit * 2
        );
        let mut st = conn.prepare_cached(&sql)?;
        let rows = st.query_map(rusqlite::params_from_iter(terms.iter()), |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (url, title) = row?;
            if out.iter().any(|s| s.url == url) {
                continue;
            }
            let bonus = if host_of(&url).starts_with(query.trim().to_lowercase().as_str()) {
                100.0
            } else {
                0.0
            };
            out.push(Suggestion {
                url,
                title,
                kind: SuggestionKind::Bookmark,
                score: 1000.0 + bonus,
            });
        }

        // History: frecency = (1 + visits) * recency weight, x3 for host prefix.
        let f = history_filter(query);
        let cond = &f.like_cond;
        let mut args = f.like_args.clone();
        let n = args.len();
        // Candidates: the most recent matches (bounded scan), host-prefix
        // matches, and FTS matches (finds rare terms in old history). Common
        // terms are therefore ranked over a bounded candidate set.
        let fts_branch = if f.fts.is_some() {
            format!(
                "UNION SELECT id FROM (SELECT rowid AS id FROM history_fts WHERE history_fts MATCH ?{} LIMIT 3000)",
                n + 5
            )
        } else {
            String::new()
        };
        let sql = format!(
            "SELECT url, title, (1 + visit_count) * (CASE
                 WHEN ?{now_i} - last_visit_ms < 86400000 THEN 100.0
                 WHEN ?{now_i} - last_visit_ms < 604800000 THEN 70.0
                 WHEN ?{now_i} - last_visit_ms < 2592000000 THEN 50.0
                 WHEN ?{now_i} - last_visit_ms < 7776000000 THEN 30.0
                 ELSE 10.0 END) * (CASE WHEN host LIKE ?{hp_i} ESCAPE '\\' THEN 3.0 ELSE 1.0 END) AS score
             FROM history WHERE ({cond}) AND id IN (
                 SELECT id FROM (SELECT id FROM (SELECT id, search_text FROM history
                                 ORDER BY last_visit_ms DESC LIMIT 20000)
                     WHERE {cond} LIMIT 3000)
                 UNION
                 SELECT id FROM history WHERE host >= ?{lo_i} AND host < ?{hi_i} AND {cond}
                 {fts_branch})
             ORDER BY score DESC LIMIT {lim}",
            now_i = n + 1,
            hp_i = n + 2,
            lo_i = n + 3,
            hi_i = n + 4,
            lim = limit * 2
        );
        let mut st = conn.prepare_cached(&sql)?;
        args.push(now.into());
        args.push(host_prefix.into());
        let q = query.trim().to_lowercase();
        args.push(q.clone().into());
        args.push(format!("{q}\u{10FFFF}").into());
        if let Some(m) = &f.fts {
            args.push(m.clone().into());
        }
        let rows = st.query_map(rusqlite::params_from_iter(args), |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, f64>(2)?,
            ))
        })?;
        for row in rows {
            let (url, title, score) = row?;
            if out.iter().any(|s| s.url == url) {
                continue;
            }
            out.push(Suggestion {
                url,
                title,
                kind: SuggestionKind::History,
                score,
            });
        }
        out.sort_by(|a, b| b.score.total_cmp(&a.score));
        out.truncate(limit as usize);
        Ok(out)
    }
}

#[uniffi::export]
impl Store {
    /// Opens (creating and migrating if needed) the database at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Self> {
        let conn = Connection::open(path)?;
        // `journal_mode` returns a row, so it cannot go through `execute`.
        let _mode: String = conn.query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        Self::from_conn(conn)
    }

    /// Opens a throw-away in-memory database.
    #[uniffi::constructor]
    pub fn open_in_memory() -> Result<Self> {
        Self::from_conn(Connection::open_in_memory()?)
    }

    // ---- history ----

    /// Records a visit: inserts the URL or bumps its count and last visit.
    /// An empty `title` keeps any previously known title.
    pub fn record_visit(&self, url: String, title: String, timestamp_ms: i64) -> Result<()> {
        let conn = self.lock()?;
        let old: Option<String> = conn
            .query_row("SELECT title FROM history WHERE url = ?1", [&url], |r| {
                r.get(0)
            })
            .optional()?;
        let title = if title.is_empty() {
            old.unwrap_or_default()
        } else {
            title
        };
        conn.execute(
            "INSERT INTO history (url, title, host, search_text, last_visit_ms, visit_count)
             VALUES (?1, ?2, ?3, ?4, ?5, 1)
             ON CONFLICT(url) DO UPDATE SET title = excluded.title,
                 search_text = excluded.search_text,
                 last_visit_ms = max(last_visit_ms, excluded.last_visit_ms),
                 visit_count = visit_count + 1",
            params![
                url,
                title,
                host_of(&url),
                search_text(&url, &title),
                timestamp_ms
            ],
        )?;
        Ok(())
    }

    /// Updates the title of an already recorded URL (no-op if unknown).
    pub fn update_title(&self, url: String, title: String) -> Result<()> {
        self.lock()?.execute(
            "UPDATE history SET title = ?2, search_text = ?3 WHERE url = ?1",
            params![url, title, search_text(&url, &title)],
        )?;
        Ok(())
    }

    /// Most recently visited entries first.
    pub fn recent_history(&self, limit: u32) -> Result<Vec<HistoryEntry>> {
        let conn = self.lock()?;
        let mut st = conn.prepare_cached(
            "SELECT id, url, title, last_visit_ms, visit_count FROM history
             ORDER BY last_visit_ms DESC LIMIT ?1",
        )?;
        let rows = st.query_map([limit], history_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Entries whose URL or title contain every whitespace-separated term of
    /// `query` (case-insensitive), most recent first.
    pub fn search_history(&self, query: String, limit: u32) -> Result<Vec<HistoryEntry>> {
        let terms = like_terms(&query);
        if terms.is_empty() {
            return self.recent_history(limit);
        }
        let f = history_filter(&query);
        let cond = &f.like_cond;
        let mut args = f.like_args.clone();
        let fts = match &f.fts {
            Some(m) => {
                args.push(m.clone().into());
                format!(
                    "AND id IN (SELECT rowid FROM history_fts WHERE history_fts MATCH ?{})",
                    args.len()
                )
            }
            None => String::new(),
        };
        let sql = format!(
            "SELECT id, url, title, last_visit_ms, visit_count FROM history
             WHERE {cond} {fts} ORDER BY last_visit_ms DESC LIMIT {limit}"
        );
        let conn = self.lock()?;
        let mut st = conn.prepare_cached(&sql)?;
        let rows = st.query_map(rusqlite::params_from_iter(args), history_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Deletes one history entry.
    pub fn delete_history_entry(&self, id: i64) -> Result<()> {
        self.lock()?
            .execute("DELETE FROM history WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Deletes all history with a last visit at or after `since_ms`
    /// (use 0 to clear everything).
    pub fn clear_history(&self, since_ms: i64) -> Result<()> {
        self.lock()?
            .execute("DELETE FROM history WHERE last_visit_ms >= ?1", [since_ms])?;
        Ok(())
    }

    // ---- bookmarks ----

    /// Adds a bookmark (a duplicate URL in the same folder is not re-added;
    /// the existing one is returned).
    pub fn add_bookmark(
        &self,
        url: String,
        title: String,
        folder_id: Option<i64>,
    ) -> Result<Bookmark> {
        let conn = self.lock()?;
        let existing = conn
            .query_row(
                "SELECT id, uuid, url, title, folder_id, modified_ms FROM bookmarks
                 WHERE deleted = 0 AND url = ?1 AND folder_id IS ?2",
                params![url, folder_id],
                bookmark_from_row,
            )
            .optional()?;
        if let Some(b) = existing {
            return Ok(b);
        }
        let uuid = uuid::Uuid::new_v4().to_string();
        let now = now_ms();
        conn.execute(
            "INSERT INTO bookmarks (uuid, url, title, folder_id, modified_ms) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![uuid, url, title, folder_id, now],
        )?;
        Ok(Bookmark {
            id: conn.last_insert_rowid(),
            uuid,
            url,
            title,
            folder_id,
            modified_ms: now,
        })
    }

    /// Marks a bookmark as deleted (tombstone kept for sync).
    pub fn remove_bookmark(&self, id: i64) -> Result<()> {
        self.lock()?.execute(
            "UPDATE bookmarks SET deleted = 1, modified_ms = ?2 WHERE id = ?1",
            params![id, now_ms()],
        )?;
        Ok(())
    }

    /// Live bookmarks of `folder_id`, or all live bookmarks when `None`.
    pub fn list_bookmarks(&self, folder_id: Option<i64>) -> Result<Vec<Bookmark>> {
        let conn = self.lock()?;
        let mut st = conn.prepare_cached(
            "SELECT id, uuid, url, title, folder_id, modified_ms FROM bookmarks
             WHERE deleted = 0 AND (?1 IS NULL OR folder_id = ?1) ORDER BY id",
        )?;
        let rows = st.query_map([folder_id], bookmark_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Whether a live bookmark with exactly this URL exists.
    pub fn is_bookmarked(&self, url: String) -> Result<bool> {
        Ok(self.lock()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM bookmarks WHERE deleted = 0 AND url = ?1)",
            [url],
            |r| r.get(0),
        )?)
    }

    /// Creates a bookmark folder.
    pub fn add_folder(&self, name: String) -> Result<Folder> {
        let conn = self.lock()?;
        let uuid = uuid::Uuid::new_v4().to_string();
        let now = now_ms();
        conn.execute(
            "INSERT INTO folders (uuid, name, modified_ms) VALUES (?1, ?2, ?3)",
            params![uuid, name, now],
        )?;
        Ok(Folder {
            id: conn.last_insert_rowid(),
            uuid,
            name,
            modified_ms: now,
        })
    }

    /// All live folders.
    pub fn list_folders(&self) -> Result<Vec<Folder>> {
        let conn = self.lock()?;
        let mut st = conn.prepare_cached(
            "SELECT id, uuid, name, modified_ms FROM folders WHERE deleted = 0 ORDER BY id",
        )?;
        let rows = st.query_map([], |r| {
            Ok(Folder {
                id: r.get(0)?,
                uuid: r.get(1)?,
                name: r.get(2)?,
                modified_ms: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    // ---- session ----

    /// Replaces the saved session atomically.
    pub fn save_session(&self, tabs: Vec<TabState>, active_tab_id: Option<String>) -> Result<()> {
        let conn = self.lock()?;
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM session_tabs", [])?;
        {
            let mut ins = tx.prepare(
                "INSERT OR REPLACE INTO session_tabs (id, url, title, pinned, position, last_active_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )?;
            for t in &tabs {
                ins.execute(params![
                    t.id,
                    t.url,
                    t.title,
                    t.pinned,
                    t.position,
                    t.last_active_ms
                ])?;
            }
        }
        match active_tab_id {
            Some(id) => tx.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES ('session.active_tab_id', ?1)",
                [id],
            )?,
            None => tx.execute(
                "DELETE FROM settings WHERE key = 'session.active_tab_id'",
                [],
            )?,
        };
        tx.commit()?;
        Ok(())
    }

    /// Loads the saved session (empty if none was saved).
    pub fn load_session(&self) -> Result<Session> {
        let conn = self.lock()?;
        let mut st = conn.prepare_cached(
            "SELECT id, url, title, pinned, position, last_active_ms FROM session_tabs ORDER BY position",
        )?;
        let tabs = st
            .query_map([], |r| {
                Ok(TabState {
                    id: r.get(0)?,
                    url: r.get(1)?,
                    title: r.get(2)?,
                    pinned: r.get(3)?,
                    position: r.get(4)?,
                    last_active_ms: r.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let active_tab_id = conn
            .query_row(
                "SELECT value FROM settings WHERE key = 'session.active_tab_id'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        Ok(Session {
            tabs,
            active_tab_id,
        })
    }

    // ---- settings ----

    /// Reads a setting.
    pub fn get_setting(&self, key: String) -> Result<Option<String>> {
        Ok(self
            .lock()?
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .optional()?)
    }

    /// Writes a setting.
    pub fn set_setting(&self, key: String, value: String) -> Result<()> {
        self.lock()?.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?1, ?2)",
            params![key, value],
        )?;
        Ok(())
    }

    // ---- suggestions ----

    /// Address-bar suggestions for `query`, best first. Combines bookmarks and
    /// history, ranked by frecency with a boost for host-prefix matches.
    pub fn suggest(&self, query: String, limit: u32) -> Result<Vec<Suggestion>> {
        self.suggest_at(&query, limit, now_ms())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s() -> Store {
        Store::open_in_memory().unwrap()
    }

    #[test]
    fn visits_and_history() {
        let st = s();
        st.record_visit("https://a.com/".into(), "A".into(), 10)
            .unwrap();
        st.record_visit("https://b.com/".into(), "Bee".into(), 20)
            .unwrap();
        st.record_visit("https://a.com/".into(), "".into(), 30)
            .unwrap();
        let r = st.recent_history(10).unwrap();
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].url, "https://a.com/");
        assert_eq!(r[0].title, "A");
        assert_eq!(r[0].visit_count, 2);
        assert_eq!(r[0].last_visit_ms, 30);
        st.update_title("https://b.com/".into(), "Buzz".into())
            .unwrap();
        assert_eq!(st.search_history("buzz".into(), 5).unwrap().len(), 1);
        assert_eq!(st.search_history("b.com BUZZ".into(), 5).unwrap().len(), 1);
        assert_eq!(st.search_history("100%".into(), 5).unwrap().len(), 0);
        st.delete_history_entry(r[0].id).unwrap();
        assert_eq!(st.recent_history(10).unwrap().len(), 1);
        st.clear_history(0).unwrap();
        assert!(st.recent_history(10).unwrap().is_empty());
    }

    #[test]
    fn clear_since() {
        let st = s();
        st.record_visit("https://old.com".into(), "".into(), 100)
            .unwrap();
        st.record_visit("https://new.com".into(), "".into(), 500)
            .unwrap();
        st.clear_history(300).unwrap();
        let r = st.recent_history(10).unwrap();
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].url, "https://old.com");
    }

    #[test]
    fn bookmarks_and_folders() {
        let st = s();
        let f = st.add_folder("Work".into()).unwrap();
        let b1 = st
            .add_bookmark("https://a.com".into(), "A".into(), None)
            .unwrap();
        let b2 = st
            .add_bookmark("https://b.com".into(), "B".into(), Some(f.id))
            .unwrap();
        assert_ne!(b1.uuid, b2.uuid);
        assert_eq!(
            st.add_bookmark("https://a.com".into(), "A".into(), None)
                .unwrap()
                .id,
            b1.id
        );
        assert_eq!(st.list_bookmarks(None).unwrap().len(), 2);
        assert_eq!(st.list_bookmarks(Some(f.id)).unwrap().len(), 1);
        assert!(st.is_bookmarked("https://a.com".into()).unwrap());
        st.remove_bookmark(b1.id).unwrap();
        assert!(!st.is_bookmarked("https://a.com".into()).unwrap());
        assert_eq!(st.list_bookmarks(None).unwrap().len(), 1);
        // tombstone remains in the table
        let n: i64 = st
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM bookmarks", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 2);
        assert_eq!(st.list_folders().unwrap().len(), 1);
    }

    #[test]
    fn session_roundtrip() {
        let st = s();
        assert_eq!(
            st.load_session().unwrap(),
            Session {
                tabs: vec![],
                active_tab_id: None
            }
        );
        let tab = |id: &str, pos| TabState {
            id: id.into(),
            url: format!("https://{id}.com"),
            title: id.into(),
            pinned: pos == 0,
            position: pos,
            last_active_ms: 5,
        };
        st.save_session(vec![tab("b", 1), tab("a", 0)], Some("b".into()))
            .unwrap();
        let s1 = st.load_session().unwrap();
        assert_eq!(
            s1.tabs.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(),
            ["a", "b"]
        );
        assert!(s1.tabs[0].pinned);
        assert_eq!(s1.active_tab_id.as_deref(), Some("b"));
        st.save_session(vec![tab("c", 0)], None).unwrap();
        let s2 = st.load_session().unwrap();
        assert_eq!(s2.tabs.len(), 1);
        assert_eq!(s2.active_tab_id, None);
    }

    #[test]
    fn settings() {
        let st = s();
        assert_eq!(st.get_setting("k".into()).unwrap(), None);
        st.set_setting("k".into(), "v".into()).unwrap();
        st.set_setting("k".into(), "w".into()).unwrap();
        assert_eq!(st.get_setting("k".into()).unwrap().as_deref(), Some("w"));
    }

    #[test]
    fn suggest_ranking() {
        let st = s();
        let now = 1_000_000_000_000;
        st.record_visit("https://example.com/".into(), "Example".into(), now)
            .unwrap();
        for _ in 0..5 {
            st.record_visit(
                "https://other.org/example-page".into(),
                "Page about example".into(),
                now,
            )
            .unwrap();
        }
        st.record_visit(
            "https://stale.net/example".into(),
            "x".into(),
            now - 200 * 86_400_000,
        )
        .unwrap();
        st.add_bookmark("https://bm.io/".into(), "Example bookmark".into(), None)
            .unwrap();
        let r = st.suggest_at("exa", 10, now).unwrap();
        assert_eq!(r[0].kind, SuggestionKind::Bookmark);
        assert_eq!(r.last().unwrap().url, "https://stale.net/example");
        // host prefix beats higher visit count
        let pos = |u: &str| r.iter().position(|x| x.url == u).unwrap();
        assert!(pos("https://example.com/") < pos("https://other.org/example-page"));
        assert_eq!(st.suggest_at("", 5, now).unwrap().len(), 0);
        assert_eq!(st.suggest_at("exa", 2, now).unwrap().len(), 2);
        // bookmarked URL that is also in history is listed once
        st.record_visit("https://bm.io/".into(), "".into(), now)
            .unwrap();
        let r = st.suggest_at("bm.io", 10, now).unwrap();
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn migration_version_and_reopen() {
        let dir = std::env::temp_dir().join(format!("neural-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("db.sqlite").to_string_lossy().into_owned();
        {
            let st = Store::open(p.clone()).unwrap();
            st.set_setting("a".into(), "1".into()).unwrap();
        }
        let st = Store::open(p).unwrap();
        assert_eq!(st.get_setting("a".into()).unwrap().as_deref(), Some("1"));
        let v: i64 = st
            .lock()
            .unwrap()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v as usize, MIGRATIONS.len());
        let mode: String = st
            .lock()
            .unwrap()
            .query_row("PRAGMA journal_mode", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn threads() {
        let st = std::sync::Arc::new(s());
        let hs: Vec<_> = (0..4)
            .map(|i| {
                let st = st.clone();
                std::thread::spawn(move || {
                    for j in 0..50 {
                        st.record_visit(format!("https://t{i}.com/{j}"), "t".into(), j)
                            .unwrap();
                    }
                })
            })
            .collect();
        hs.into_iter().for_each(|h| h.join().unwrap());
        assert_eq!(st.recent_history(1000).unwrap().len(), 200);
    }

    /// Benchmark: 100k history rows, suggestions must stay fast.
    #[test]
    fn bench_suggest_100k() {
        let st = s();
        let now = 1_700_000_000_000i64;
        {
            let conn = st.lock().unwrap();
            let tx = conn.unchecked_transaction().unwrap();
            {
                let mut ins = tx
                    .prepare("INSERT INTO history (url, title, host, search_text, last_visit_ms, visit_count) VALUES (?1,?2,?3,?4,?5,?6)")
                    .unwrap();
                for i in 0..100_000i64 {
                    let url = format!(
                        "https://site{}.example{}.com/path/{}/page?id={}",
                        i % 997,
                        i % 13,
                        i,
                        i
                    );
                    let title = format!("Article number {i} about topic {}", i % 311);
                    ins.execute(params![
                        url,
                        title,
                        host_of(&url),
                        search_text(&url, &title),
                        now - i * 60_000,
                        1 + i % 7
                    ])
                    .unwrap();
                }
            }
            tx.commit().unwrap();
        }
        let queries = ["site12", "topic 77", "article", "example5.com", "zzzz", "g"];
        let mut worst = std::time::Duration::ZERO;
        for q in queries {
            let t = std::time::Instant::now();
            let r = st.suggest_at(q, 8, now).unwrap();
            let d = t.elapsed();
            eprintln!("suggest({q:?}) -> {} results in {d:?}", r.len());
            worst = worst.max(d);
        }
        eprintln!("worst suggest over 100k rows: {worst:?}");
        assert!(worst.as_millis() < 25, "too slow: {worst:?}");
    }
}
