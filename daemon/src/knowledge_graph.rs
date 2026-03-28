//! Personal Knowledge Graph (Fase V) + Cross-App Context
//!
//! Stores entities and relations extracted from user interactions,
//! persisted as JSON files. Supports fuzzy search, conflict detection,
//! relevance decay, cross-app ingestion, and LLM-powered context queries.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum EntityType {
    Person,
    Project,
    Decision,
    Commitment,
    Date,
    Location,
    Tool,
    File,
    Topic,
    Event,
    Conversation,
    Commit,
    Email,
    Task,
    Skill,
}

impl std::fmt::Display for EntityType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            EntityType::Person => "Person",
            EntityType::Project => "Project",
            EntityType::Decision => "Decision",
            EntityType::Commitment => "Commitment",
            EntityType::Date => "Date",
            EntityType::Location => "Location",
            EntityType::Tool => "Tool",
            EntityType::File => "File",
            EntityType::Topic => "Topic",
            EntityType::Event => "Event",
            EntityType::Conversation => "Conversation",
            EntityType::Commit => "Commit",
            EntityType::Email => "Email",
            EntityType::Task => "Task",
            EntityType::Skill => "Skill",
        };
        write!(f, "{}", s)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entity {
    pub id: String,
    pub name: String,
    pub entity_type: EntityType,
    #[serde(default)]
    pub properties: HashMap<String, String>,
    pub created_at: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
    pub relevance_score: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Relation {
    pub from_id: String,
    pub to_id: String,
    pub relation_type: String,
    #[serde(default = "default_weight")]
    pub weight: f32,
    pub context: String,
    pub timestamp: DateTime<Utc>,
    pub confidence: f64,
}

fn default_weight() -> f32 {
    1.0
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct KgStats {
    pub entities_by_type: HashMap<String, usize>,
    pub total_relations: usize,
    pub oldest: Option<DateTime<Utc>>,
    pub newest: Option<DateTime<Utc>>,
}

// ---------------------------------------------------------------------------
// Privacy
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyLevel {
    /// Store everything the system observes.
    Everything,
    /// Only store entities/relations extracted from explicit conversations.
    ConversationsOnly,
    /// Only store when the user explicitly requests it.
    ExplicitOnly,
}

impl Default for PrivacyLevel {
    fn default() -> Self {
        Self::Everything
    }
}

// ---------------------------------------------------------------------------
// KnowledgeGraph
// ---------------------------------------------------------------------------

pub struct KnowledgeGraph {
    data_dir: PathBuf,
    entities: Vec<Entity>,
    relations: Vec<Relation>,
    privacy_level: PrivacyLevel,
}

impl KnowledgeGraph {
    /// Load from disk or create empty graph.
    pub fn new(data_dir: PathBuf) -> Self {
        fs::create_dir_all(&data_dir).ok();

        let entities_path = data_dir.join("kg_entities.json");
        let relations_path = data_dir.join("kg_relations.json");

        let entities: Vec<Entity> = fs::read_to_string(&entities_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();

        let relations: Vec<Relation> = fs::read_to_string(&relations_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();

        Self {
            data_dir,
            entities,
            relations,
            privacy_level: PrivacyLevel::default(),
        }
    }

    // -- persistence --------------------------------------------------------

    fn save(&self) {
        let entities_path = self.data_dir.join("kg_entities.json");
        let relations_path = self.data_dir.join("kg_relations.json");

        if let Ok(json) = serde_json::to_string_pretty(&self.entities) {
            fs::write(&entities_path, json).ok();
        }
        if let Ok(json) = serde_json::to_string_pretty(&self.relations) {
            fs::write(&relations_path, json).ok();
        }
    }

    // -- entities -----------------------------------------------------------

    /// Add an entity. Deduplicates by (name lowercase, entity_type).
    /// Returns the entity ID (existing or new).
    pub fn add_entity(&mut self, name: &str, entity_type: EntityType) -> String {
        let name_lower = name.to_lowercase();

        // Deduplicate: if an entity with same name+type exists, bump last_seen
        if let Some(existing) = self
            .entities
            .iter_mut()
            .find(|e| e.name.to_lowercase() == name_lower && e.entity_type == entity_type)
        {
            existing.last_seen = Utc::now();
            existing.relevance_score = (existing.relevance_score + 0.05).min(1.0);
            let id = existing.id.clone();
            self.save();
            return id;
        }

        let entity = Entity {
            id: Uuid::new_v4().to_string(),
            name: name.to_string(),
            entity_type,
            properties: HashMap::new(),
            created_at: Utc::now(),
            last_seen: Utc::now(),
            relevance_score: 1.0,
        };
        let id = entity.id.clone();
        self.entities.push(entity);
        self.save();
        id
    }

    /// Add a relation between two entities.
    pub fn add_relation(&mut self, from_id: &str, to_id: &str, relation_type: &str, context: &str) {
        self.add_relation_weighted(from_id, to_id, relation_type, context, 1.0);
    }

    /// Add a weighted relation between two entities.
    pub fn add_relation_weighted(
        &mut self,
        from_id: &str,
        to_id: &str,
        relation_type: &str,
        context: &str,
        weight: f32,
    ) {
        let relation = Relation {
            from_id: from_id.to_string(),
            to_id: to_id.to_string(),
            relation_type: relation_type.to_string(),
            weight,
            context: context.to_string(),
            timestamp: Utc::now(),
            confidence: 1.0,
        };
        self.relations.push(relation);
        self.save();
    }

    // -- queries ------------------------------------------------------------

    /// Fuzzy search entities by name (case-insensitive substring match).
    pub fn query_entity(&self, name: &str) -> Vec<Entity> {
        let needle = name.to_lowercase();
        self.entities
            .iter()
            .filter(|e| e.name.to_lowercase().contains(&needle))
            .cloned()
            .collect()
    }

    /// Get all relations for an entity together with the connected entity.
    pub fn query_relations(&self, entity_id: &str) -> Vec<(Relation, Entity)> {
        let mut results = Vec::new();
        for rel in &self.relations {
            if rel.from_id == entity_id {
                if let Some(other) = self.entities.iter().find(|e| e.id == rel.to_id) {
                    results.push((rel.clone(), other.clone()));
                }
            } else if rel.to_id == entity_id {
                if let Some(other) = self.entities.iter().find(|e| e.id == rel.from_id) {
                    results.push((rel.clone(), other.clone()));
                }
            }
        }
        results
    }

    // -- privacy ------------------------------------------------------------

    /// Set the privacy level for the knowledge graph.
    pub fn set_privacy_level(&mut self, level: PrivacyLevel) {
        self.privacy_level = level;
    }

    /// Get the current privacy level.
    pub fn privacy_level(&self) -> PrivacyLevel {
        self.privacy_level
    }

    // -- temporal queries ---------------------------------------------------

    /// Query relations for an entity sorted by timestamp (newest first).
    /// Optionally filters by `relation_type`.
    pub fn query_temporal(
        &self,
        entity_name: &str,
        relation_type: Option<&str>,
    ) -> Vec<(Relation, Entity)> {
        let needle = entity_name.to_lowercase();
        // Find all entity IDs matching the name
        let ids: Vec<&str> = self
            .entities
            .iter()
            .filter(|e| e.name.to_lowercase().contains(&needle))
            .map(|e| e.id.as_str())
            .collect();

        let mut results: Vec<(Relation, Entity)> = Vec::new();
        for rel in &self.relations {
            let matches_entity = ids.iter().any(|id| *id == rel.from_id || *id == rel.to_id);
            if !matches_entity {
                continue;
            }
            if let Some(rt) = relation_type {
                if rel.relation_type != rt {
                    continue;
                }
            }
            // Find the "other" entity
            let other_id = if ids.contains(&rel.from_id.as_str()) {
                &rel.to_id
            } else {
                &rel.from_id
            };
            if let Some(other) = self.entities.iter().find(|e| e.id == *other_id) {
                results.push((rel.clone(), other.clone()));
            }
        }

        // Sort newest first
        results.sort_by(|a, b| b.0.timestamp.cmp(&a.0.timestamp));
        results
    }

    /// Return all entities with relations whose timestamp falls within
    /// `[from, to]`, grouped by entity.
    pub fn query_by_time_range(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Vec<(Entity, Vec<Relation>)> {
        let mut map: HashMap<String, Vec<Relation>> = HashMap::new();

        for rel in &self.relations {
            if rel.timestamp >= from && rel.timestamp <= to {
                map.entry(rel.from_id.clone())
                    .or_default()
                    .push(rel.clone());
                map.entry(rel.to_id.clone()).or_default().push(rel.clone());
            }
        }

        let mut results = Vec::new();
        for entity in &self.entities {
            if let Some(rels) = map.remove(&entity.id) {
                results.push((entity.clone(), rels));
            }
        }
        results
    }

    // -- deletion -----------------------------------------------------------

    /// Remove an entity and ALL relations that reference it.
    pub fn delete_entity_cascade(&mut self, entity_id: &str) {
        self.entities.retain(|e| e.id != entity_id);
        self.relations
            .retain(|r| r.from_id != entity_id && r.to_id != entity_id);
        self.save();
    }

    /// Remove entities whose `created_at` falls within `[from, to]` and
    /// all relations referencing them.
    pub fn delete_by_date_range(&mut self, from: DateTime<Utc>, to: DateTime<Utc>) {
        let removed_ids: std::collections::HashSet<String> = self
            .entities
            .iter()
            .filter(|e| e.created_at >= from && e.created_at <= to)
            .map(|e| e.id.clone())
            .collect();

        self.entities
            .retain(|e| !(e.created_at >= from && e.created_at <= to));

        if !removed_ids.is_empty() {
            self.relations
                .retain(|r| !removed_ids.contains(&r.from_id) && !removed_ids.contains(&r.to_id));
        }

        self.save();
    }

    // -- text extraction (regex, no LLM) ------------------------------------

    /// Extract entities from free text using simple patterns.
    ///
    /// Recognised patterns:
    /// - Dates: `YYYY-MM-DD`
    /// - Spanish day names: lunes, martes, ..., domingo
    /// - @mentions: `@username` -> Person
    /// - File paths: `/path/to/file` or `~/path` -> File
    /// - URLs: `https://...` or `http://...` -> Topic
    pub fn extract_entities_from_text(text: &str) -> Vec<(String, EntityType)> {
        let mut found: Vec<(String, EntityType)> = Vec::new();
        let mut seen = std::collections::HashSet::new();

        // ISO dates  YYYY-MM-DD
        for cap in regex_lite_find_all(text, r"\b\d{4}-\d{2}-\d{2}\b") {
            if seen.insert((cap.clone(), EntityType::Date)) {
                found.push((cap, EntityType::Date));
            }
        }

        // Spanish day names (case-insensitive)
        let days = [
            "lunes",
            "martes",
            "miercoles",
            "miércoles",
            "jueves",
            "viernes",
            "sabado",
            "sábado",
            "domingo",
        ];
        for word in text.split_whitespace() {
            let w = word
                .trim_matches(|c: char| c.is_ascii_punctuation())
                .to_lowercase();
            if days.contains(&w.as_str()) && seen.insert((w.clone(), EntityType::Date)) {
                found.push((w, EntityType::Date));
            }
        }

        // @mentions -> Person
        for word in text.split_whitespace() {
            if word.starts_with('@') && word.len() > 1 {
                let name = word
                    .trim_start_matches('@')
                    .trim_matches(|c: char| c.is_ascii_punctuation());
                if !name.is_empty() && seen.insert((name.to_string(), EntityType::Person)) {
                    found.push((name.to_string(), EntityType::Person));
                }
            }
        }

        // File paths
        for word in text.split_whitespace() {
            let clean = word.trim_matches(|c: char| c == ',' || c == ';' || c == ')' || c == '(');
            if (clean.starts_with('/') || clean.starts_with("~/"))
                && clean.len() > 2
                && !clean.starts_with("//")
                && seen.insert((clean.to_string(), EntityType::File))
            {
                found.push((clean.to_string(), EntityType::File));
            }
        }

        // URLs -> Topic
        for word in text.split_whitespace() {
            let clean = word.trim_matches(|c: char| c == ',' || c == ';' || c == ')' || c == '(');
            if (clean.starts_with("https://") || clean.starts_with("http://"))
                && seen.insert((clean.to_string(), EntityType::Topic))
            {
                found.push((clean.to_string(), EntityType::Topic));
            }
        }

        found
    }

    // -- maintenance --------------------------------------------------------

    /// Decay relevance for entities not seen in 7+ days.
    /// Remove entities whose score drops below 0.1.
    pub fn decay_relevance(&mut self) {
        let now = Utc::now();
        let seven_days = chrono::Duration::days(7);

        for entity in &mut self.entities {
            if now.signed_duration_since(entity.last_seen) > seven_days {
                entity.relevance_score -= 0.01;
            }
        }

        // Collect IDs of entities to remove
        let removed_ids: std::collections::HashSet<String> = self
            .entities
            .iter()
            .filter(|e| e.relevance_score < 0.1)
            .map(|e| e.id.clone())
            .collect();

        self.entities.retain(|e| e.relevance_score >= 0.1);

        // Also remove relations referencing removed entities
        if !removed_ids.is_empty() {
            self.relations
                .retain(|r| !removed_ids.contains(&r.from_id) && !removed_ids.contains(&r.to_id));
        }

        self.save();
    }

    /// Statistics about the knowledge graph.
    pub fn stats(&self) -> KgStats {
        let mut entities_by_type: HashMap<String, usize> = HashMap::new();
        let mut oldest: Option<DateTime<Utc>> = None;
        let mut newest: Option<DateTime<Utc>> = None;

        for entity in &self.entities {
            *entities_by_type
                .entry(entity.entity_type.to_string())
                .or_insert(0) += 1;

            match oldest {
                None => oldest = Some(entity.created_at),
                Some(o) if entity.created_at < o => oldest = Some(entity.created_at),
                _ => {}
            }
            match newest {
                None => newest = Some(entity.created_at),
                Some(n) if entity.created_at > n => newest = Some(entity.created_at),
                _ => {}
            }
        }

        KgStats {
            entities_by_type,
            total_relations: self.relations.len(),
            oldest,
            newest,
        }
    }

    // -- context query ------------------------------------------------------

    /// Extract entity names from a question, find them in the graph, and
    /// return their relations as context results.
    pub fn query_context(&self, question: &str) -> Vec<ContextResult> {
        let extracted = Self::extract_entities_from_text(question);
        let mut results = Vec::new();

        // Also try splitting question into meaningful words (3+ chars) as entity name searches
        let words: Vec<&str> = question
            .split_whitespace()
            .filter(|w| w.len() >= 3)
            .collect();

        let mut searched_names = std::collections::HashSet::new();

        // Search for extracted entities
        for (name, _etype) in &extracted {
            if searched_names.insert(name.to_lowercase()) {
                for entity in self.query_entity(name) {
                    let relations = self.query_relations(&entity.id);
                    results.push(ContextResult {
                        entity: entity.clone(),
                        relations: relations.iter().map(|(r, _)| r.clone()).collect(),
                        related_entities: relations.iter().map(|(_, e)| e.clone()).collect(),
                    });
                }
            }
        }

        // Also search raw words as potential entity names
        for word in &words {
            let w = word
                .trim_matches(|c: char| c.is_ascii_punctuation())
                .to_lowercase();
            if w.len() >= 3 && searched_names.insert(w.clone()) {
                for entity in self.query_entity(&w) {
                    // Avoid duplicates
                    if results.iter().any(|r| r.entity.id == entity.id) {
                        continue;
                    }
                    let relations = self.query_relations(&entity.id);
                    results.push(ContextResult {
                        entity: entity.clone(),
                        relations: relations.iter().map(|(r, _)| r.clone()).collect(),
                        related_entities: relations.iter().map(|(_, e)| e.clone()).collect(),
                    });
                }
            }
        }

        results
    }

    // -- cross-app ingestion ------------------------------------------------

    /// Ingest a Telegram message: extract entities, create a Conversation node,
    /// and link the sender and mentioned entities.
    pub async fn ingest_telegram_message(
        &mut self,
        from: &str,
        text: &str,
        timestamp: DateTime<Utc>,
    ) -> Result<(), String> {
        let person_id = self.add_entity(from, EntityType::Person);
        let conv_id = self.add_entity(
            &format!("telegram:{}", &text.chars().take(50).collect::<String>()),
            EntityType::Conversation,
        );

        // Set timestamp property
        if let Some(conv) = self.entities.iter_mut().find(|e| e.id == conv_id) {
            conv.properties
                .insert("timestamp".into(), timestamp.to_rfc3339());
            conv.properties.insert("source".into(), "telegram".into());
            conv.properties.insert("text".into(), text.to_string());
        }
        self.save();

        self.add_relation(&person_id, &conv_id, "sent_message", text);

        // Extract and link mentioned entities
        let extracted = Self::extract_entities_from_text(text);
        for (name, etype) in extracted {
            let eid = self.add_entity(&name, etype);
            self.add_relation(&conv_id, &eid, "mentioned_in", text);
        }

        Ok(())
    }

    /// Ingest an email: extract entities from subject+body, create an Email node.
    pub async fn ingest_email(
        &mut self,
        from: &str,
        subject: &str,
        body: &str,
        timestamp: DateTime<Utc>,
    ) -> Result<(), String> {
        let person_id = self.add_entity(from, EntityType::Person);
        let email_id = self.add_entity(&format!("email:{}", subject), EntityType::Email);

        if let Some(email) = self.entities.iter_mut().find(|e| e.id == email_id) {
            email
                .properties
                .insert("timestamp".into(), timestamp.to_rfc3339());
            email.properties.insert("subject".into(), subject.into());
            email
                .properties
                .insert("body_preview".into(), body.chars().take(200).collect());
        }
        self.save();

        self.add_relation(&person_id, &email_id, "sent_email", subject);

        // Extract entities from subject + body
        let full_text = format!("{} {}", subject, body);
        let extracted = Self::extract_entities_from_text(&full_text);
        for (name, etype) in extracted {
            let eid = self.add_entity(&name, etype);
            self.add_relation(&email_id, &eid, "mentioned_in", subject);
        }

        Ok(())
    }

    /// Ingest a calendar event: create an Event node, link attendees.
    pub async fn ingest_calendar_event(
        &mut self,
        title: &str,
        attendees: &[String],
        timestamp: DateTime<Utc>,
    ) -> Result<(), String> {
        let event_id = self.add_entity(title, EntityType::Event);

        if let Some(event) = self.entities.iter_mut().find(|e| e.id == event_id) {
            event
                .properties
                .insert("timestamp".into(), timestamp.to_rfc3339());
            event
                .properties
                .insert("attendees".into(), attendees.join(", "));
        }
        self.save();

        for attendee in attendees {
            let person_id = self.add_entity(attendee, EntityType::Person);
            self.add_relation(&person_id, &event_id, "attends", title);
        }

        // Extract entities from the title
        let extracted = Self::extract_entities_from_text(title);
        for (name, etype) in extracted {
            let eid = self.add_entity(&name, etype);
            self.add_relation(&event_id, &eid, "discussed_in", title);
        }

        Ok(())
    }

    /// Ingest a git commit: create a Commit node, link author and files.
    pub async fn ingest_git_commit(
        &mut self,
        author: &str,
        message: &str,
        files: &[String],
        timestamp: DateTime<Utc>,
    ) -> Result<(), String> {
        let author_id = self.add_entity(author, EntityType::Person);
        let commit_id = self.add_entity(
            &format!("commit:{}", &message.chars().take(60).collect::<String>()),
            EntityType::Commit,
        );

        if let Some(commit) = self.entities.iter_mut().find(|e| e.id == commit_id) {
            commit
                .properties
                .insert("timestamp".into(), timestamp.to_rfc3339());
            commit.properties.insert("message".into(), message.into());
            commit.properties.insert("files".into(), files.join(", "));
        }
        self.save();

        self.add_relation(&author_id, &commit_id, "authored", message);

        for file_path in files {
            let file_id = self.add_entity(file_path, EntityType::File);
            self.add_relation(&commit_id, &file_id, "modified", message);
        }

        // Extract entities from commit message
        let extracted = Self::extract_entities_from_text(message);
        for (name, etype) in extracted {
            let eid = self.add_entity(&name, etype);
            self.add_relation(&commit_id, &eid, "mentioned_in", message);
        }

        Ok(())
    }

    /// Ingest a file interaction (open, edit, save, etc.).
    pub async fn ingest_file_interaction(
        &mut self,
        path: &str,
        action: &str,
        timestamp: DateTime<Utc>,
    ) -> Result<(), String> {
        let file_id = self.add_entity(path, EntityType::File);

        if let Some(file) = self.entities.iter_mut().find(|e| e.id == file_id) {
            file.properties.insert("last_action".into(), action.into());
            file.properties
                .insert("last_action_at".into(), timestamp.to_rfc3339());
        }
        self.save();

        // Try to associate with a project based on the path
        let parts: Vec<&str> = path.split('/').collect();
        if parts.len() >= 3 {
            // Use the directory two levels up as a project hint
            let project_hint = parts.iter().rev().nth(1).unwrap_or(&"unknown");
            if project_hint.len() >= 2 {
                let project_id = self.add_entity(project_hint, EntityType::Project);
                self.add_relation(&file_id, &project_id, "belongs_to", action);
            }
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// ContextResult
// ---------------------------------------------------------------------------

/// Result from a context query: an entity with its related entities and relations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextResult {
    pub entity: Entity,
    pub relations: Vec<Relation>,
    pub related_entities: Vec<Entity>,
}

impl ContextResult {
    /// Format this context result as a human-readable summary.
    pub fn to_summary(&self) -> String {
        let mut lines = Vec::new();
        lines.push(format!(
            "- {} ({})",
            self.entity.name, self.entity.entity_type
        ));
        for (rel, other) in self.relations.iter().zip(self.related_entities.iter()) {
            lines.push(format!(
                "  {} {} ({})",
                rel.relation_type, other.name, other.entity_type
            ));
            if !rel.context.is_empty() {
                let preview: String = rel.context.chars().take(80).collect();
                lines.push(format!("    context: {}", preview));
            }
        }
        lines.join("\n")
    }
}

// ---------------------------------------------------------------------------
// LLM-powered context answer
// ---------------------------------------------------------------------------

/// Query the knowledge graph and use the LLM router to answer a question
/// with full cross-app context.
#[allow(dead_code)]
pub async fn answer_context_question(
    question: &str,
    graph: &KnowledgeGraph,
    router: &crate::llm_router::LlmRouter,
) -> Result<String, String> {
    // 1. Extract entities and query the graph
    let context_results = graph.query_context(question);

    if context_results.is_empty() {
        // No context found -- still ask the LLM but note the lack of context
        let request = crate::llm_router::RouterRequest {
            messages: vec![crate::llm_router::ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(format!(
                    "The user asked: \"{}\"\n\n\
                     No relevant context was found in the LifeOS knowledge graph. \
                     Answer based on general knowledge, and mention that no personal \
                     context was available.",
                    question
                )),
            }],
            complexity: Some(crate::llm_router::TaskComplexity::Medium),
            sensitivity: None,
            preferred_provider: None,
            max_tokens: Some(512),
        };

        let response = router.chat(&request).await.map_err(|e| e.to_string())?;
        return Ok(response.text);
    }

    // 2. Format context summary
    let context_summary: String = context_results
        .iter()
        .map(|cr| cr.to_summary())
        .collect::<Vec<_>>()
        .join("\n\n");

    // 3. Build prompt with context and send to LLM
    let system_prompt = format!(
        "You are LifeOS, a personal AI assistant with access to the user's knowledge graph. \
         Use the following context from the knowledge graph to answer the user's question. \
         Be specific and reference the context when relevant. Answer concisely.\n\n\
         Context from LifeOS knowledge graph:\n{}\n",
        context_summary
    );

    let request = crate::llm_router::RouterRequest {
        messages: vec![
            crate::llm_router::ChatMessage {
                role: "system".into(),
                content: serde_json::Value::String(system_prompt),
            },
            crate::llm_router::ChatMessage {
                role: "user".into(),
                content: serde_json::Value::String(question.to_string()),
            },
        ],
        complexity: Some(crate::llm_router::TaskComplexity::Medium),
        sensitivity: None,
        preferred_provider: None,
        max_tokens: Some(512),
    };

    let response = router.chat(&request).await.map_err(|e| e.to_string())?;
    Ok(response.text)
}

// ---------------------------------------------------------------------------
// ConflictDetector
// ---------------------------------------------------------------------------

pub struct ConflictDetector;

impl ConflictDetector {
    /// Check if adding a new fact about `entity_id` conflicts with existing
    /// relations. Returns a human-readable description of the conflict, if any.
    ///
    /// Currently detects:
    /// - Different `deadline_for` on the same commitment
    /// - Different `located_at` for the same entity
    /// - Different `promised_to` for the same commitment
    pub fn check_conflict(
        graph: &KnowledgeGraph,
        new_fact: &str,
        entity_id: &str,
    ) -> Option<String> {
        // Parse new_fact as "relation_type:value", e.g. "deadline_for:2026-04-01"
        let parts: Vec<&str> = new_fact.splitn(2, ':').collect();
        if parts.len() != 2 {
            return None;
        }
        let new_rel_type = parts[0].trim();
        let new_value = parts[1].trim().to_lowercase();

        // Relation types where only one value makes sense
        let unique_relations = ["deadline_for", "located_at", "promised_to"];

        if !unique_relations.contains(&new_rel_type) {
            return None;
        }

        // Look for existing relations of the same type on this entity
        for rel in &graph.relations {
            if rel.relation_type == new_rel_type
                && (rel.from_id == entity_id || rel.to_id == entity_id)
            {
                // Find the "other" entity to compare values
                let other_id = if rel.from_id == entity_id {
                    &rel.to_id
                } else {
                    &rel.from_id
                };

                if let Some(other_entity) = graph.entities.iter().find(|e| e.id == *other_id) {
                    let existing_value = other_entity.name.to_lowercase();
                    if existing_value != new_value {
                        let entity_name = graph
                            .entities
                            .iter()
                            .find(|e| e.id == entity_id)
                            .map(|e| e.name.as_str())
                            .unwrap_or(entity_id);

                        return Some(format!(
                            "Conflict: '{}' already has {} = '{}', but new value is '{}'",
                            entity_name,
                            new_rel_type,
                            other_entity.name,
                            parts[1].trim()
                        ));
                    }
                }
            }
        }

        None
    }
}

// ---------------------------------------------------------------------------
// Minimal regex helper (avoids pulling in the `regex` crate)
// ---------------------------------------------------------------------------

/// Simple pattern matching for `\b\d{4}-\d{2}-\d{2}\b` without the regex crate.
fn regex_lite_find_all(text: &str, _pattern: &str) -> Vec<String> {
    // We only support the date pattern here; extend as needed.
    let mut results = Vec::new();
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i + 10 <= len {
        // Check for YYYY-MM-DD (exactly 10 chars)
        if chars[i].is_ascii_digit()
            && chars[i + 1].is_ascii_digit()
            && chars[i + 2].is_ascii_digit()
            && chars[i + 3].is_ascii_digit()
            && chars[i + 4] == '-'
            && chars[i + 5].is_ascii_digit()
            && chars[i + 6].is_ascii_digit()
            && chars[i + 7] == '-'
            && chars[i + 8].is_ascii_digit()
            && chars[i + 9].is_ascii_digit()
        {
            // Word boundary check: char before (if any) should not be alphanumeric
            let before_ok = i == 0 || !chars[i - 1].is_alphanumeric();
            let after_ok = i + 10 >= len || !chars[i + 10].is_alphanumeric();
            if before_ok && after_ok {
                let date: String = chars[i..i + 10].iter().collect();
                results.push(date);
                i += 10;
                continue;
            }
        }
        i += 1;
    }
    results
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_graph() -> KnowledgeGraph {
        let dir = std::env::temp_dir().join(format!("kg_test_{}", Uuid::new_v4()));
        KnowledgeGraph::new(dir)
    }

    #[test]
    fn test_add_and_query_entity() {
        let mut g = temp_graph();
        let id = g.add_entity("Hector", EntityType::Person);
        assert!(!id.is_empty());

        let results = g.query_entity("hector");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "Hector");
    }

    #[test]
    fn test_dedup_entity() {
        let mut g = temp_graph();
        let id1 = g.add_entity("LifeOS", EntityType::Project);
        let id2 = g.add_entity("lifeos", EntityType::Project);
        assert_eq!(id1, id2);
        assert_eq!(g.entities.len(), 1);
    }

    #[test]
    fn test_add_relation_and_query() {
        let mut g = temp_graph();
        let p = g.add_entity("Hector", EntityType::Person);
        let proj = g.add_entity("LifeOS", EntityType::Project);
        g.add_relation(&p, &proj, "works_on", "main developer");

        let rels = g.query_relations(&p);
        assert_eq!(rels.len(), 1);
        assert_eq!(rels[0].0.relation_type, "works_on");
        assert_eq!(rels[0].1.name, "LifeOS");
    }

    #[test]
    fn test_extract_entities_from_text() {
        let text = "Meeting with @carlos on 2026-04-01 about /home/user/project. \
                     See https://example.com for details. Next lunes we continue.";
        let entities = KnowledgeGraph::extract_entities_from_text(text);

        let types: Vec<_> = entities.iter().map(|(_, t)| t.clone()).collect();
        assert!(types.contains(&EntityType::Date)); // 2026-04-01 and lunes
        assert!(types.contains(&EntityType::Person)); // @carlos
        assert!(types.contains(&EntityType::File)); // /home/user/project
        assert!(types.contains(&EntityType::Topic)); // https://example.com
    }

    #[test]
    fn test_conflict_detector() {
        let mut g = temp_graph();
        let commit = g.add_entity("Ship v1.0", EntityType::Commitment);
        let deadline1 = g.add_entity("2026-04-01", EntityType::Date);
        g.add_relation(&commit, &deadline1, "deadline_for", "original deadline");

        let conflict = ConflictDetector::check_conflict(&g, "deadline_for:2026-05-15", &commit);
        assert!(conflict.is_some());
        assert!(conflict.unwrap().contains("Conflict"));
    }

    #[test]
    fn test_decay_relevance() {
        let mut g = temp_graph();
        g.add_entity("OldThing", EntityType::Topic);
        // Manually set last_seen to 30 days ago and low score
        g.entities[0].last_seen = Utc::now() - chrono::Duration::days(30);
        g.entities[0].relevance_score = 0.10;

        g.decay_relevance();
        // Score was 0.10, decayed by 0.01 -> 0.09 < 0.1 -> removed
        assert!(g.entities.is_empty());
    }

    #[test]
    fn test_stats() {
        let mut g = temp_graph();
        g.add_entity("Alice", EntityType::Person);
        g.add_entity("Bob", EntityType::Person);
        g.add_entity("ProjectX", EntityType::Project);

        let stats = g.stats();
        assert_eq!(stats.entities_by_type.get("Person"), Some(&2));
        assert_eq!(stats.entities_by_type.get("Project"), Some(&1));
        assert_eq!(stats.total_relations, 0);
        assert!(stats.oldest.is_some());
    }

    #[test]
    fn test_persistence() {
        let dir = std::env::temp_dir().join(format!("kg_persist_{}", Uuid::new_v4()));
        {
            let mut g = KnowledgeGraph::new(dir.clone());
            g.add_entity("Persistent", EntityType::Tool);
        }
        // Reload from same dir
        let g2 = KnowledgeGraph::new(dir);
        assert_eq!(g2.entities.len(), 1);
        assert_eq!(g2.entities[0].name, "Persistent");
    }

    // -- Fase V: new entity types -------------------------------------------

    #[test]
    fn test_new_entity_types() {
        let mut g = temp_graph();
        g.add_entity("team standup", EntityType::Event);
        g.add_entity("chat with alice", EntityType::Conversation);
        g.add_entity("fix: resolve bug", EntityType::Commit);
        g.add_entity("invoice from vendor", EntityType::Email);
        g.add_entity("deploy v2", EntityType::Task);
        g.add_entity("rust async", EntityType::Skill);

        assert_eq!(g.entities.len(), 6);
        let stats = g.stats();
        assert_eq!(stats.entities_by_type.get("Event"), Some(&1));
        assert_eq!(stats.entities_by_type.get("Conversation"), Some(&1));
        assert_eq!(stats.entities_by_type.get("Commit"), Some(&1));
        assert_eq!(stats.entities_by_type.get("Email"), Some(&1));
        assert_eq!(stats.entities_by_type.get("Task"), Some(&1));
        assert_eq!(stats.entities_by_type.get("Skill"), Some(&1));
    }

    #[test]
    fn test_entity_properties() {
        let mut g = temp_graph();
        let id = g.add_entity("meeting", EntityType::Event);
        if let Some(e) = g.entities.iter_mut().find(|e| e.id == id) {
            e.properties.insert("location".into(), "zoom".into());
            e.properties.insert("recurring".into(), "weekly".into());
        }
        g.save();

        // Reload and check properties persist
        let g2 = KnowledgeGraph::new(g.data_dir.clone());
        let e = g2.query_entity("meeting");
        assert_eq!(e.len(), 1);
        assert_eq!(e[0].properties.get("location"), Some(&"zoom".to_string()));
    }

    #[test]
    fn test_weighted_relation() {
        let mut g = temp_graph();
        let a = g.add_entity("Alice", EntityType::Person);
        let b = g.add_entity("ProjectX", EntityType::Project);
        g.add_relation_weighted(&a, &b, "works_on", "main contributor", 0.9);

        assert_eq!(g.relations.len(), 1);
        assert!((g.relations[0].weight - 0.9).abs() < f32::EPSILON);
    }

    // -- Fase V: query_context ----------------------------------------------

    #[test]
    fn test_query_context() {
        let mut g = temp_graph();
        let hector = g.add_entity("Hector", EntityType::Person);
        let proj = g.add_entity("LifeOS", EntityType::Project);
        g.add_relation(&hector, &proj, "works_on", "main developer");

        let results = g.query_context("What is Hector working on?");
        assert!(!results.is_empty());
        // Should find Hector entity
        assert!(results.iter().any(|r| r.entity.name == "Hector"));
    }

    #[test]
    fn test_query_context_no_results() {
        let g = temp_graph();
        let results = g.query_context("What is the meaning of life?");
        assert!(results.is_empty());
    }

    #[test]
    fn test_context_result_summary() {
        let mut g = temp_graph();
        let hector = g.add_entity("Hector", EntityType::Person);
        let proj = g.add_entity("LifeOS", EntityType::Project);
        g.add_relation(&hector, &proj, "works_on", "main developer");

        let results = g.query_context("Tell me about Hector");
        assert!(!results.is_empty());
        let summary = results[0].to_summary();
        assert!(summary.contains("Hector"));
        assert!(summary.contains("Person"));
    }

    // -- Fase V: cross-app ingestion ----------------------------------------

    #[tokio::test]
    async fn test_ingest_telegram_message() {
        let mut g = temp_graph();
        g.ingest_telegram_message(
            "Carlos",
            "Hey @maria check /home/carlos/docs/report.pdf by 2026-04-15",
            Utc::now(),
        )
        .await
        .unwrap();

        // Should have: Carlos (Person), conversation, maria (Person), file, date
        let carlos: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.name == "Carlos" && e.entity_type == EntityType::Person)
            .collect();
        assert_eq!(carlos.len(), 1);

        let maria: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.name == "maria" && e.entity_type == EntityType::Person)
            .collect();
        assert_eq!(maria.len(), 1);

        let files: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.name == "/home/carlos/docs/report.pdf")
            .collect();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].entity_type, EntityType::File);

        // Conversation entity should have properties
        let convs: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.entity_type == EntityType::Conversation)
            .collect();
        assert_eq!(convs.len(), 1);
        assert_eq!(convs[0].properties.get("source"), Some(&"telegram".into()));
    }

    #[tokio::test]
    async fn test_ingest_email() {
        let mut g = temp_graph();
        g.ingest_email(
            "Alice",
            "Q3 Budget Review",
            "Please review the budget at https://docs.example.com/budget",
            Utc::now(),
        )
        .await
        .unwrap();

        let alice = g.query_entity("Alice");
        assert_eq!(alice.len(), 1);

        let emails: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.entity_type == EntityType::Email)
            .collect();
        assert_eq!(emails.len(), 1);
        assert!(emails[0].properties.contains_key("subject"));
    }

    #[tokio::test]
    async fn test_ingest_calendar_event() {
        let mut g = temp_graph();
        g.ingest_calendar_event(
            "Sprint Planning",
            &["Alice".into(), "Bob".into(), "Carlos".into()],
            Utc::now(),
        )
        .await
        .unwrap();

        let events: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.entity_type == EntityType::Event)
            .collect();
        assert_eq!(events.len(), 1);

        // All 3 attendees should be Person entities
        let persons: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.entity_type == EntityType::Person)
            .collect();
        assert_eq!(persons.len(), 3);

        // Each attendee should have an "attends" relation to the event
        let event_id = &events[0].id;
        let attend_rels: Vec<_> = g
            .relations
            .iter()
            .filter(|r| r.to_id == *event_id && r.relation_type == "attends")
            .collect();
        assert_eq!(attend_rels.len(), 3);
    }

    #[tokio::test]
    async fn test_ingest_git_commit() {
        let mut g = temp_graph();
        g.ingest_git_commit(
            "Hector",
            "feat: add knowledge graph module",
            &[
                "daemon/src/knowledge_graph.rs".into(),
                "daemon/src/main.rs".into(),
            ],
            Utc::now(),
        )
        .await
        .unwrap();

        let hector = g.query_entity("Hector");
        assert_eq!(hector.len(), 1);

        let commits: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.entity_type == EntityType::Commit)
            .collect();
        assert_eq!(commits.len(), 1);
        assert!(commits[0].properties.contains_key("message"));

        // Two files should be linked
        let files: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.entity_type == EntityType::File)
            .collect();
        assert_eq!(files.len(), 2);
    }

    #[tokio::test]
    async fn test_ingest_file_interaction() {
        let mut g = temp_graph();
        g.ingest_file_interaction("/home/hector/lifeos/README.md", "edit", Utc::now())
            .await
            .unwrap();

        let _files = g.query_entity("README.md");
        // The full path entity should exist
        let all_files: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.entity_type == EntityType::File)
            .collect();
        assert_eq!(all_files.len(), 1);
        assert_eq!(
            all_files[0].properties.get("last_action"),
            Some(&"edit".into())
        );

        // Should have created a project entity from the path
        let projects: Vec<_> = g
            .entities
            .iter()
            .filter(|e| e.entity_type == EntityType::Project)
            .collect();
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].name, "lifeos");
    }
}
