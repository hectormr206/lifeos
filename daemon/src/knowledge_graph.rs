//! Personal Knowledge Graph (Fase V)
//!
//! Stores entities and relations extracted from user interactions,
//! persisted as JSON files. Supports fuzzy search, conflict detection,
//! and relevance decay.

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
        };
        write!(f, "{}", s)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entity {
    pub id: String,
    pub name: String,
    pub entity_type: EntityType,
    pub created_at: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
    pub relevance_score: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Relation {
    pub from_id: String,
    pub to_id: String,
    pub relation_type: String,
    pub context: String,
    pub timestamp: DateTime<Utc>,
    pub confidence: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct KgStats {
    pub entities_by_type: HashMap<String, usize>,
    pub total_relations: usize,
    pub oldest: Option<DateTime<Utc>>,
    pub newest: Option<DateTime<Utc>>,
}

// ---------------------------------------------------------------------------
// KnowledgeGraph
// ---------------------------------------------------------------------------

pub struct KnowledgeGraph {
    data_dir: PathBuf,
    entities: Vec<Entity>,
    relations: Vec<Relation>,
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
        if let Some(existing) = self.entities.iter_mut().find(|e| {
            e.name.to_lowercase() == name_lower && e.entity_type == entity_type
        }) {
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
    pub fn add_relation(
        &mut self,
        from_id: &str,
        to_id: &str,
        relation_type: &str,
        context: &str,
    ) {
        let relation = Relation {
            from_id: from_id.to_string(),
            to_id: to_id.to_string(),
            relation_type: relation_type.to_string(),
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

        let conflict =
            ConflictDetector::check_conflict(&g, "deadline_for:2026-05-15", &commit);
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
}
