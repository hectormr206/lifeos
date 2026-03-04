//! Agent Runtime manager for Phase 2 foundations.
//!
//! Provides minimal but functional:
//! - Intent planning/apply/status/validate/log
//! - Identity token issue/list/revoke
//! - Local ledger persistence for auditing

use aes_gcm_siv::aead::{Aead, KeyInit};
use aes_gcm_siv::{Aes256GcmSiv, Nonce};
use anyhow::{Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use chrono::{DateTime, Duration, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IntentStatus {
    Draft,
    Planned,
    AwaitingApproval,
    Approved,
    Executing,
    Succeeded,
    Failed,
    RolledBack,
    Blocked,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentConstraints {
    pub max_runtime_sec: u32,
    pub max_cost_usd: f64,
    pub network_policy: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentPlanStep {
    pub tool: String,
    pub args: serde_json::Value,
    pub expected_output: String,
    pub rollback_step: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentRecord {
    pub intent_id: String,
    pub schema_version: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub requested_by: String,
    pub objective_id: String,
    pub action: String,
    pub input: serde_json::Value,
    pub risk: String,
    pub required_capabilities: Vec<String>,
    pub dry_run: bool,
    pub idempotency_key: String,
    pub constraints: IntentConstraints,
    pub plan: Vec<IntentPlanStep>,
    pub status: IntentStatus,
    pub result: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentValidationReport {
    pub valid: bool,
    pub missing_fields: Vec<String>,
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapabilityTokenRecord {
    pub token_id: String,
    pub token: String,
    pub issuer: String,
    pub subject: String,
    pub acting_as: String,
    pub capabilities: Vec<String>,
    pub scope: String,
    pub risk: String,
    pub issued_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub revoked: bool,
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LedgerEntry {
    pub entry_id: String,
    pub timestamp: DateTime<Utc>,
    pub category: String,
    pub action: String,
    pub target: String,
    pub detail: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceRunRecord {
    pub run_id: String,
    pub intent_id: String,
    pub requested_isolation: String,
    pub effective_isolation: String,
    pub workspace_path: String,
    pub command: String,
    pub started_at: DateTime<Utc>,
    pub finished_at: DateTime<Utc>,
    pub duration_ms: u64,
    pub exit_code: i32,
    pub succeeded: bool,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub enum ExecutionMode {
    #[default]
    Interactive,
    RunUntilDone,
    SilentUntilDone,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TrustModeState {
    pub enabled: bool,
    pub consent_bundle_sha256: Option<String>,
    pub activated_by: Option<String>,
    pub updated_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct AgentRuntimeState {
    intents: Vec<IntentRecord>,
    tokens: Vec<CapabilityTokenRecord>,
    ledger: Vec<LedgerEntry>,
    #[serde(default)]
    workspace_runs: Vec<WorkspaceRunRecord>,
    #[serde(default)]
    execution_mode: ExecutionMode,
    #[serde(default)]
    trust_mode: TrustModeState,
}

pub struct AgentRuntimeManager {
    data_dir: PathBuf,
    state: Arc<RwLock<AgentRuntimeState>>,
}

impl AgentRuntimeManager {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        Ok(Self {
            data_dir,
            state: Arc::new(RwLock::new(AgentRuntimeState::default())),
        })
    }

    pub async fn initialize(&self) -> Result<()> {
        self.load_state().await
    }

    pub async fn plan_intent(&self, description: &str) -> Result<IntentRecord> {
        let now = Utc::now();
        let intent_id = format!("intent-{}", Uuid::new_v4());
        let risk = infer_risk_level(description).to_string();

        let intent = IntentRecord {
            intent_id: intent_id.clone(),
            schema_version: "life-intents/v1".to_string(),
            created_at: now,
            updated_at: now,
            requested_by: "user://local/default".to_string(),
            objective_id: format!("obj-{}", now.format("%Y%m%d%H%M%S")),
            action: infer_action(description),
            input: serde_json::json!({ "description": description }),
            risk: risk.clone(),
            required_capabilities: infer_required_capabilities(description),
            dry_run: false,
            idempotency_key: intent_id.clone(),
            constraints: IntentConstraints {
                max_runtime_sec: 120,
                max_cost_usd: 0.0,
                network_policy: "default".to_string(),
            },
            plan: vec![
                IntentPlanStep {
                    tool: "policy.evaluate".to_string(),
                    args: serde_json::json!({ "risk": risk }),
                    expected_output: "policy_result".to_string(),
                    rollback_step: "no-op".to_string(),
                },
                IntentPlanStep {
                    tool: "executor.run".to_string(),
                    args: serde_json::json!({ "description": description }),
                    expected_output: "execution_result".to_string(),
                    rollback_step: "executor.rollback_last".to_string(),
                },
            ],
            status: IntentStatus::Planned,
            result: None,
        };

        let mut state = self.state.write().await;
        state.intents.push(intent.clone());
        append_ledger(
            &mut state,
            "intent",
            "plan",
            &intent_id,
            serde_json::json!({
                "risk": intent.risk,
                "action": intent.action,
                "required_capabilities": intent.required_capabilities,
            }),
        );
        drop(state);

        self.save_state().await?;
        Ok(intent)
    }

    pub async fn apply_intent(&self, intent_id: &str, approved: bool) -> Result<IntentRecord> {
        let mut approved = approved;
        let mut state = self.state.write().await;
        let intent_idx = state
            .intents
            .iter()
            .position(|i| i.intent_id == intent_id)
            .with_context(|| format!("Intent not found: {}", intent_id))?;

        let risk = state.intents[intent_idx].risk.clone();
        let exec_mode = state.execution_mode.clone();
        let trust_enabled = state.trust_mode.enabled;
        if matches!(risk.as_str(), "high" | "critical") && !approved {
            if trust_enabled
                && matches!(
                    exec_mode,
                    ExecutionMode::RunUntilDone | ExecutionMode::SilentUntilDone
                )
            {
                approved = true;
                append_ledger(
                    &mut state,
                    "intent",
                    "auto_approved",
                    intent_id,
                    serde_json::json!({
                        "risk": risk,
                        "execution_mode": format_execution_mode(&exec_mode),
                        "reason": "trust_mode_enabled",
                    }),
                );
            } else {
                {
                    let intent = &mut state.intents[intent_idx];
                    intent.status = IntentStatus::AwaitingApproval;
                    intent.updated_at = Utc::now();
                }
                append_ledger(
                    &mut state,
                    "intent",
                    "awaiting_approval",
                    intent_id,
                    serde_json::json!({
                        "risk": risk,
                        "reason": "high_or_critical_risk_requires_approval"
                    }),
                );
                let snapshot = state.intents[intent_idx].clone();
                drop(state);
                self.save_state().await?;
                return Ok(snapshot);
            }
        }

        {
            let intent = &mut state.intents[intent_idx];
            intent.status = IntentStatus::Succeeded;
            intent.updated_at = Utc::now();
            intent.result = Some(serde_json::json!({
                "status": "success",
                "message": "Intent executed by baseline runtime",
            }));
        }

        append_ledger(
            &mut state,
            "intent",
            "apply",
            intent_id,
            serde_json::json!({
                "status": "succeeded",
                "approved": approved,
            }),
        );

        let snapshot = state.intents[intent_idx].clone();
        drop(state);
        self.save_state().await?;
        Ok(snapshot)
    }

    pub async fn get_intent(&self, intent_id: &str) -> Option<IntentRecord> {
        let state = self.state.read().await;
        state
            .intents
            .iter()
            .find(|i| i.intent_id == intent_id)
            .cloned()
    }

    pub fn validate_intent_payload(&self, payload: &serde_json::Value) -> IntentValidationReport {
        let required = [
            "intent_id",
            "schema_version",
            "created_at",
            "requested_by",
            "objective_id",
            "action",
            "input",
            "risk",
            "required_capabilities",
            "dry_run",
            "idempotency_key",
            "constraints",
        ];

        let mut missing_fields = Vec::new();
        for field in required {
            if payload.get(field).is_none() {
                missing_fields.push(field.to_string());
            }
        }

        let mut errors = Vec::new();
        if let Some(schema_version) = payload.get("schema_version").and_then(|v| v.as_str()) {
            if schema_version != "life-intents/v1" {
                errors.push("schema_version must be 'life-intents/v1'".to_string());
            }
        }

        if let Some(risk) = payload.get("risk").and_then(|v| v.as_str()) {
            if !matches!(risk, "low" | "medium" | "high" | "critical") {
                errors.push("risk must be one of low|medium|high|critical".to_string());
            }
        }

        if let Some(caps) = payload.get("required_capabilities") {
            if !caps.is_array() {
                errors.push("required_capabilities must be an array".to_string());
            }
        }

        IntentValidationReport {
            valid: missing_fields.is_empty() && errors.is_empty(),
            missing_fields,
            errors,
        }
    }

    pub async fn issue_token(
        &self,
        agent: &str,
        capability: &str,
        ttl_minutes: u32,
        scope: Option<&str>,
    ) -> Result<CapabilityTokenRecord> {
        let now = Utc::now();
        let token_id = format!("jti-{}", Uuid::new_v4());
        let subject = format!("agent://{}/primary", agent);
        let scope = scope.unwrap_or("scope://default").to_string();

        let token = CapabilityTokenRecord {
            token_id: token_id.clone(),
            token: format!("lifeid.{}.{}", token_id, Uuid::new_v4().simple()),
            issuer: "life-id.local".to_string(),
            subject: subject.clone(),
            acting_as: subject,
            capabilities: vec![capability.to_string()],
            scope,
            risk: "medium".to_string(),
            issued_at: now,
            expires_at: now + Duration::minutes(i64::from(ttl_minutes)),
            revoked: false,
            revoked_at: None,
        };

        let mut state = self.state.write().await;
        state.tokens.push(token.clone());
        append_ledger(
            &mut state,
            "identity",
            "issue",
            &token_id,
            serde_json::json!({
                "agent": agent,
                "capability": capability,
                "expires_at": token.expires_at,
            }),
        );
        drop(state);

        self.save_state().await?;
        Ok(token)
    }

    pub async fn list_tokens(&self, active_only: bool) -> Vec<CapabilityTokenRecord> {
        let now = Utc::now();
        let state = self.state.read().await;

        state
            .tokens
            .iter()
            .filter(|t| {
                if !active_only {
                    return true;
                }
                !t.revoked && t.expires_at > now
            })
            .cloned()
            .collect()
    }

    pub async fn revoke_token(&self, token_id: &str) -> Result<CapabilityTokenRecord> {
        let mut state = self.state.write().await;
        let token_idx = state
            .tokens
            .iter()
            .position(|t| t.token_id == token_id)
            .with_context(|| format!("Token not found: {}", token_id))?;

        {
            let token = &mut state.tokens[token_idx];
            token.revoked = true;
            token.revoked_at = Some(Utc::now());
        }

        append_ledger(
            &mut state,
            "identity",
            "revoke",
            token_id,
            serde_json::json!({
                "revoked": true
            }),
        );

        let snapshot = state.tokens[token_idx].clone();
        drop(state);
        self.save_state().await?;
        Ok(snapshot)
    }

    pub async fn ledger_entries(&self, limit: usize) -> Vec<LedgerEntry> {
        let state = self.state.read().await;
        state.ledger.iter().rev().take(limit).cloned().collect()
    }

    pub async fn export_ledger_encrypted(
        &self,
        passphrase: &str,
        limit: usize,
    ) -> Result<serde_json::Value> {
        if passphrase.trim().is_empty() {
            anyhow::bail!("Passphrase cannot be empty");
        }

        let entries = self.ledger_entries(limit).await;
        let payload = serde_json::json!({
            "exported_at": Utc::now(),
            "entries_count": entries.len(),
            "entries": entries,
        });
        let plaintext = serde_json::to_vec(&payload)?;

        let key_material = Sha256::digest(passphrase.as_bytes());
        let cipher = Aes256GcmSiv::new_from_slice(&key_material)
            .map_err(|e| anyhow::anyhow!("Failed to initialize cipher: {}", e))?;

        let mut nonce_bytes = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = cipher
            .encrypt(nonce, plaintext.as_ref())
            .map_err(|e| anyhow::anyhow!("Failed to encrypt ledger export: {}", e))?;

        let digest = Sha256::digest(&plaintext);

        Ok(serde_json::json!({
            "format": "lifeos-ledger-export/v1",
            "cipher": "AES-256-GCM-SIV",
            "nonce_b64": B64.encode(nonce_bytes),
            "ciphertext_b64": B64.encode(ciphertext),
            "plaintext_sha256": format!("{:x}", digest),
            "entries_count": payload["entries_count"],
            "exported_at": payload["exported_at"],
        }))
    }

    pub async fn workspace_run(
        &self,
        intent_id: &str,
        command: Option<&str>,
        requested_isolation: &str,
        approved: bool,
    ) -> Result<WorkspaceRunRecord> {
        let mut approved = approved;
        let (intent_risk, max_runtime_sec, default_command, exec_mode, trust_enabled) = {
            let state = self.state.read().await;
            let intent = state
                .intents
                .iter()
                .find(|i| i.intent_id == intent_id)
                .with_context(|| format!("Intent not found: {}", intent_id))?;
            (
                intent.risk.clone(),
                intent.constraints.max_runtime_sec,
                intent_default_command(&intent.action),
                state.execution_mode.clone(),
                state.trust_mode.enabled,
            )
        };

        if matches!(intent_risk.as_str(), "high" | "critical") && !approved {
            if trust_enabled
                && matches!(
                    exec_mode,
                    ExecutionMode::RunUntilDone | ExecutionMode::SilentUntilDone
                )
            {
                approved = true;
                let mut state = self.state.write().await;
                append_ledger(
                    &mut state,
                    "workspace",
                    "auto_approved",
                    intent_id,
                    serde_json::json!({
                        "reason": "trust_mode_enabled",
                        "execution_mode": format_execution_mode(&exec_mode),
                        "risk": intent_risk
                    }),
                );
                drop(state);
                self.save_state().await?;
            } else {
                let mut state = self.state.write().await;
                if let Some(intent) = state.intents.iter_mut().find(|i| i.intent_id == intent_id) {
                    intent.status = IntentStatus::AwaitingApproval;
                    intent.updated_at = Utc::now();
                }
                append_ledger(
                    &mut state,
                    "workspace",
                    "run_blocked",
                    intent_id,
                    serde_json::json!({
                        "reason": "approval_required",
                        "risk": intent_risk
                    }),
                );
                drop(state);
                self.save_state().await?;
                anyhow::bail!("Intent requires approval for workspace execution");
            }
        }

        {
            let mut state = self.state.write().await;
            if let Some(intent) = state.intents.iter_mut().find(|i| i.intent_id == intent_id) {
                intent.status = IntentStatus::Executing;
                intent.updated_at = Utc::now();
            }
        }
        self.save_state().await?;

        let workspace_dir = self.data_dir.join("workspaces").join(intent_id);
        tokio::fs::create_dir_all(&workspace_dir).await?;

        let effective_isolation = match requested_isolation {
            "sandbox" | "container" | "microvm" => "sandbox",
            _ => "sandbox",
        };

        let command = command
            .filter(|c| !c.trim().is_empty())
            .map(|c| c.trim().to_string())
            .unwrap_or_else(|| default_command.to_string());

        let started_at = Utc::now();
        let started_instant = std::time::Instant::now();
        let mut process = Command::new("sh");
        process
            .arg("-lc")
            .arg(&command)
            .current_dir(&workspace_dir)
            .env_clear()
            .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
            .env("HOME", &workspace_dir)
            .env("LIFEOS_WORKSPACE", &workspace_dir)
            .env("LIFEOS_ISOLATION", effective_isolation);

        let run_output = tokio::time::timeout(
            std::time::Duration::from_secs(u64::from(max_runtime_sec.max(1))),
            process.output(),
        )
        .await;
        let finished_at = Utc::now();
        let duration_ms = started_instant.elapsed().as_millis() as u64;

        let (exit_code, succeeded, stdout, stderr) = match run_output {
            Ok(Ok(output)) => {
                let stdout =
                    truncate_for_ledger(String::from_utf8_lossy(&output.stdout).to_string());
                let stderr =
                    truncate_for_ledger(String::from_utf8_lossy(&output.stderr).to_string());
                (
                    output.status.code().unwrap_or(1),
                    output.status.success(),
                    stdout,
                    stderr,
                )
            }
            Ok(Err(e)) => (
                1,
                false,
                String::new(),
                format!("Workspace command failed to start: {}", e),
            ),
            Err(_) => (
                124,
                false,
                String::new(),
                format!("Workspace command timed out after {}s", max_runtime_sec),
            ),
        };

        let run_record = WorkspaceRunRecord {
            run_id: format!("run-{}", Uuid::new_v4()),
            intent_id: intent_id.to_string(),
            requested_isolation: requested_isolation.to_string(),
            effective_isolation: effective_isolation.to_string(),
            workspace_path: workspace_dir.to_string_lossy().to_string(),
            command: command.clone(),
            started_at,
            finished_at,
            duration_ms,
            exit_code,
            succeeded,
            stdout: stdout.clone(),
            stderr: stderr.clone(),
        };

        let mut state = self.state.write().await;
        if let Some(intent) = state.intents.iter_mut().find(|i| i.intent_id == intent_id) {
            intent.status = if succeeded {
                IntentStatus::Succeeded
            } else {
                IntentStatus::Failed
            };
            intent.updated_at = Utc::now();
            intent.result = Some(serde_json::json!({
                "status": if succeeded { "success" } else { "failure" },
                "workspace_run_id": run_record.run_id,
                "exit_code": exit_code,
                "approved": approved,
            }));
        }
        state.workspace_runs.push(run_record.clone());
        append_ledger(
            &mut state,
            "workspace",
            "run",
            intent_id,
            serde_json::json!({
                "run_id": run_record.run_id,
                "requested_isolation": run_record.requested_isolation,
                "effective_isolation": run_record.effective_isolation,
                "exit_code": run_record.exit_code,
                "succeeded": run_record.succeeded,
                "duration_ms": run_record.duration_ms
            }),
        );
        drop(state);

        self.save_state().await?;
        Ok(run_record)
    }

    pub async fn list_workspace_runs(&self, limit: usize) -> Vec<WorkspaceRunRecord> {
        let state = self.state.read().await;
        state
            .workspace_runs
            .iter()
            .rev()
            .take(limit)
            .cloned()
            .collect()
    }

    pub async fn execution_mode(&self) -> ExecutionMode {
        let state = self.state.read().await;
        state.execution_mode.clone()
    }

    pub async fn set_execution_mode(
        &self,
        mode: &str,
        actor: Option<&str>,
    ) -> Result<ExecutionMode> {
        let parsed = parse_execution_mode(mode)?;
        let mut state = self.state.write().await;
        state.execution_mode = parsed.clone();
        append_ledger(
            &mut state,
            "runtime",
            "set_execution_mode",
            "execution-mode",
            serde_json::json!({
                "mode": format_execution_mode(&parsed),
                "actor": actor.unwrap_or("user://local/default"),
            }),
        );
        drop(state);
        self.save_state().await?;
        Ok(parsed)
    }

    pub async fn trust_mode(&self) -> TrustModeState {
        let state = self.state.read().await;
        state.trust_mode.clone()
    }

    pub async fn set_trust_mode(
        &self,
        enabled: bool,
        actor: Option<&str>,
        consent_bundle: Option<&str>,
        signature: Option<&str>,
    ) -> Result<TrustModeState> {
        let actor = actor.unwrap_or("user://local/default");
        let now = Utc::now();

        let mut state = self.state.write().await;
        if enabled {
            let bundle = consent_bundle
                .map(|b| b.trim())
                .filter(|b| !b.is_empty())
                .ok_or_else(|| {
                    anyhow::anyhow!("consent_bundle is required when enabling trust mode")
                })?;
            let signature = signature
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("signature is required when enabling trust mode"))?;

            let digest = Sha256::digest(bundle.as_bytes());
            let digest_hex = format!("{:x}", digest);
            let expected = normalize_sha256_signature(signature)
                .ok_or_else(|| anyhow::anyhow!("signature must contain sha256 digest"))?;

            if digest_hex != expected {
                anyhow::bail!("consent_bundle signature verification failed");
            }

            state.trust_mode = TrustModeState {
                enabled: true,
                consent_bundle_sha256: Some(digest_hex.clone()),
                activated_by: Some(actor.to_string()),
                updated_at: Some(now),
            };
            append_ledger(
                &mut state,
                "trust",
                "enable",
                "trust-me-mode",
                serde_json::json!({
                    "actor": actor,
                    "consent_bundle_sha256": digest_hex,
                    "signature_verified": true,
                }),
            );
        } else {
            let consent_bundle_sha256 = state.trust_mode.consent_bundle_sha256.clone();
            state.trust_mode.enabled = false;
            state.trust_mode.updated_at = Some(now);
            state.trust_mode.activated_by = Some(actor.to_string());
            append_ledger(
                &mut state,
                "trust",
                "disable",
                "trust-me-mode",
                serde_json::json!({
                    "actor": actor,
                    "consent_bundle_sha256": consent_bundle_sha256,
                }),
            );
        }

        let snapshot = state.trust_mode.clone();
        drop(state);
        self.save_state().await?;
        Ok(snapshot)
    }

    async fn load_state(&self) -> Result<()> {
        let path = self.state_file();
        if !path.exists() {
            return Ok(());
        }

        let raw = tokio::fs::read_to_string(&path)
            .await
            .with_context(|| format!("Failed to read {}", path.display()))?;
        let parsed: AgentRuntimeState = serde_json::from_str(&raw)
            .with_context(|| format!("Failed to parse {}", path.display()))?;
        *self.state.write().await = parsed;
        Ok(())
    }

    async fn save_state(&self) -> Result<()> {
        let path = self.state_file();
        tokio::fs::create_dir_all(&self.data_dir).await?;
        let snapshot = self.state.read().await.clone();
        let serialized = serde_json::to_string_pretty(&snapshot)?;
        tokio::fs::write(&path, serialized)
            .await
            .with_context(|| format!("Failed to write {}", path.display()))?;
        Ok(())
    }

    fn state_file(&self) -> PathBuf {
        self.data_dir.join("agent_runtime_state.json")
    }
}

fn append_ledger(
    state: &mut AgentRuntimeState,
    category: &str,
    action: &str,
    target: &str,
    detail: serde_json::Value,
) {
    state.ledger.push(LedgerEntry {
        entry_id: format!("ledger-{}", Uuid::new_v4()),
        timestamp: Utc::now(),
        category: category.to_string(),
        action: action.to_string(),
        target: target.to_string(),
        detail,
    });
}

fn truncate_for_ledger(value: String) -> String {
    const LIMIT: usize = 4096;
    if value.len() <= LIMIT {
        value
    } else {
        format!("{}...[truncated]", &value[..LIMIT])
    }
}

fn intent_default_command(action: &str) -> &'static str {
    match action {
        "system.update" => "echo 'Simulated update workflow in workspace'",
        "system.rollback" => "echo 'Simulated rollback workflow in workspace'",
        "ui.overlay" => "echo 'Simulated overlay workflow in workspace'",
        _ => "echo 'Simulated workspace execution'",
    }
}

fn infer_action(description: &str) -> String {
    let lowered = description.to_lowercase();
    if lowered.contains("update") {
        "system.update".to_string()
    } else if lowered.contains("rollback") {
        "system.rollback".to_string()
    } else if lowered.contains("overlay") {
        "ui.overlay".to_string()
    } else {
        "system.execute".to_string()
    }
}

fn infer_required_capabilities(description: &str) -> Vec<String> {
    let lowered = description.to_lowercase();
    let mut capabilities = vec!["system.read".to_string()];

    if lowered.contains("update") {
        capabilities.push("updates.install".to_string());
    }
    if lowered.contains("delete") || lowered.contains("rm ") {
        capabilities.push("fs.write".to_string());
    }
    if lowered.contains("network") || lowered.contains("download") {
        capabilities.push("network.access".to_string());
    }

    capabilities.sort();
    capabilities.dedup();
    capabilities
}

fn infer_risk_level(description: &str) -> &'static str {
    let lowered = description.to_lowercase();
    if lowered.contains("format")
        || lowered.contains("wipe")
        || lowered.contains("delete")
        || lowered.contains("rm -rf")
    {
        "critical"
    } else if lowered.contains("reboot")
        || lowered.contains("shutdown")
        || lowered.contains("install")
        || lowered.contains("update")
    {
        "high"
    } else if lowered.contains("configure") || lowered.contains("set") {
        "medium"
    } else {
        "low"
    }
}

fn parse_execution_mode(mode: &str) -> Result<ExecutionMode> {
    match mode.trim().to_lowercase().as_str() {
        "interactive" => Ok(ExecutionMode::Interactive),
        "run-until-done" => Ok(ExecutionMode::RunUntilDone),
        "silent-until-done" => Ok(ExecutionMode::SilentUntilDone),
        other => anyhow::bail!(
            "invalid execution mode '{}': use interactive|run-until-done|silent-until-done",
            other
        ),
    }
}

fn format_execution_mode(mode: &ExecutionMode) -> &'static str {
    match mode {
        ExecutionMode::Interactive => "interactive",
        ExecutionMode::RunUntilDone => "run-until-done",
        ExecutionMode::SilentUntilDone => "silent-until-done",
    }
}

fn normalize_sha256_signature(sig: &str) -> Option<String> {
    let trimmed = sig.trim();
    let candidate = trimmed
        .strip_prefix("sha256:")
        .or_else(|| trimmed.strip_prefix("SHA256:"))
        .unwrap_or(trimmed)
        .trim()
        .to_lowercase();
    if candidate.len() == 64 && candidate.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(candidate)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("lifeos-{}-{}", prefix, Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[tokio::test]
    async fn plan_and_apply_low_risk_intent() {
        let dir = temp_dir("agent-runtime-test-plan");
        let mgr = AgentRuntimeManager::new(dir.clone()).unwrap();
        mgr.initialize().await.unwrap();

        let planned = mgr.plan_intent("show system status").await.unwrap();
        assert_eq!(planned.status, IntentStatus::Planned);

        let applied = mgr.apply_intent(&planned.intent_id, false).await.unwrap();
        assert_eq!(applied.status, IntentStatus::Succeeded);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn high_risk_requires_approval() {
        let dir = temp_dir("agent-runtime-test-approval");
        let mgr = AgentRuntimeManager::new(dir.clone()).unwrap();

        let planned = mgr.plan_intent("install updates now").await.unwrap();
        let applied = mgr.apply_intent(&planned.intent_id, false).await.unwrap();
        assert_eq!(applied.status, IntentStatus::AwaitingApproval);

        let approved = mgr.apply_intent(&planned.intent_id, true).await.unwrap();
        assert_eq!(approved.status, IntentStatus::Succeeded);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn issue_list_and_revoke_token() {
        let dir = temp_dir("agent-runtime-test-id");
        let mgr = AgentRuntimeManager::new(dir.clone()).unwrap();

        let token = mgr
            .issue_token("delivery-agent", "fs.write", 30, Some("repo:/workspace/a"))
            .await
            .unwrap();
        let active = mgr.list_tokens(true).await;
        assert!(active.iter().any(|t| t.token_id == token.token_id));

        let revoked = mgr.revoke_token(&token.token_id).await.unwrap();
        assert!(revoked.revoked);

        let active_after = mgr.list_tokens(true).await;
        assert!(!active_after.iter().any(|t| t.token_id == token.token_id));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn workspace_run_executes_in_workspace() {
        let dir = temp_dir("agent-runtime-test-workspace");
        let mgr = AgentRuntimeManager::new(dir.clone()).unwrap();

        let planned = mgr.plan_intent("show system status").await.unwrap();
        let run = mgr
            .workspace_run(
                &planned.intent_id,
                Some("echo workspace_ok > output.txt && cat output.txt"),
                "sandbox",
                true,
            )
            .await
            .unwrap();

        assert!(run.succeeded);
        assert!(run.stdout.contains("workspace_ok"));

        let out_path = std::path::PathBuf::from(&run.workspace_path).join("output.txt");
        assert!(out_path.exists());

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn encrypted_ledger_export_produces_ciphertext() {
        let dir = temp_dir("agent-runtime-test-export");
        let mgr = AgentRuntimeManager::new(dir.clone()).unwrap();

        let planned = mgr.plan_intent("show system status").await.unwrap();
        let _ = mgr.apply_intent(&planned.intent_id, false).await.unwrap();

        let export = mgr
            .export_ledger_encrypted("test-passphrase", 20)
            .await
            .unwrap();

        assert_eq!(export["format"].as_str(), Some("lifeos-ledger-export/v1"));
        assert!(export["ciphertext_b64"]
            .as_str()
            .map(|v| !v.is_empty())
            .unwrap_or(false));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn trust_mode_requires_valid_signature() {
        let dir = temp_dir("agent-runtime-test-trust");
        let mgr = AgentRuntimeManager::new(dir.clone()).unwrap();

        let bad = mgr
            .set_trust_mode(
                true,
                Some("user://local/admin"),
                Some("allow=true"),
                Some("sha256:deadbeef"),
            )
            .await;
        assert!(bad.is_err());

        let digest = format!("{:x}", Sha256::digest("allow=true".as_bytes()));
        let good = mgr
            .set_trust_mode(
                true,
                Some("user://local/admin"),
                Some("allow=true"),
                Some(&format!("sha256:{}", digest)),
            )
            .await
            .unwrap();
        assert!(good.enabled);
        assert_eq!(good.consent_bundle_sha256.as_deref(), Some(digest.as_str()));

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn run_until_done_auto_approves_high_risk_intent() {
        let dir = temp_dir("agent-runtime-test-auto-approve");
        let mgr = AgentRuntimeManager::new(dir.clone()).unwrap();

        let digest = format!("{:x}", Sha256::digest("allow=true".as_bytes()));
        mgr.set_trust_mode(
            true,
            Some("user://local/admin"),
            Some("allow=true"),
            Some(&format!("sha256:{}", digest)),
        )
        .await
        .unwrap();
        mgr.set_execution_mode("run-until-done", Some("user://local/admin"))
            .await
            .unwrap();

        let planned = mgr.plan_intent("install updates now").await.unwrap();
        let applied = mgr.apply_intent(&planned.intent_id, false).await.unwrap();
        assert_eq!(applied.status, IntentStatus::Succeeded);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn execution_mode_roundtrip() {
        let dir = temp_dir("agent-runtime-test-mode");
        let mgr = AgentRuntimeManager::new(dir.clone()).unwrap();

        let mode = mgr
            .set_execution_mode("silent-until-done", Some("user://local/default"))
            .await
            .unwrap();
        assert_eq!(mode, ExecutionMode::SilentUntilDone);
        assert_eq!(mgr.execution_mode().await, ExecutionMode::SilentUntilDone);

        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn validate_intent_payload_reports_missing_fields() {
        let mgr = AgentRuntimeManager::new(PathBuf::from("/tmp/lifeos-agent-runtime")).unwrap();
        let report = mgr.validate_intent_payload(&serde_json::json!({
            "schema_version": "life-intents/v1"
        }));
        assert!(!report.valid);
        assert!(report.missing_fields.contains(&"intent_id".to_string()));
    }
}
