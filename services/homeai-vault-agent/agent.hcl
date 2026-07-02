// homeai-vault-agent
// =================================================================
// One Vault Agent process for the ai-internal trust zone. Auto-auth
// via AppRole. Renders secrets into /run/secrets/* on a tmpfs volume
// shared with consumer containers via bind mount.
//
// Consumers read secrets from FILES (the swarm-compat *_FILE env
// convention), so no service code holds plaintext.

pid_file = "/tmp/vault-agent.pid"

vault {
  address = "http://vault:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path = "/etc/vault-agent/role_id"
      secret_id_file_path = "/etc/vault-agent/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  // Optional internal sink (token file inside container, perms 0400)
  sink "file" {
    config = {
      path = "/tmp/vault-token"
      mode = 0400
    }
  }
}

// ---- Templates (one file per secret) ----------------------------

template {
  destination = "/run/secrets/anthropic-api-key"
  perms       = 0444
  contents    = <<-EOT
  {{ with secret "secret/data/anthropic" }}{{ .Data.data.api_key }}{{ end }}
  EOT
}

template {
  destination = "/run/secrets/postgres-readonly-password"
  perms       = 0444
  contents    = <<-EOT
  {{ with secret "secret/data/postgres-roles" }}{{ .Data.data.homeai_readonly }}{{ end }}
  EOT
}

// Telegram bot token (used by alertmanager + n8n in future)
template {
  destination = "/run/secrets/telegram-bot-token"
  perms       = 0444
  contents    = <<-EOT
  {{ with secret "secret/data/telegram" }}{{ .Data.data.bot_token }}{{ end }}
  EOT
}

// DeepSeek API key (TD-007: routes Hermes's deepseek egress through the
// LiteLLM gateway so it gets Presidio redaction + ai_usage logging instead
// of hitting api.deepseek.com directly).
template {
  destination = "/run/secrets/deepseek-api-key"
  perms       = 0444
  contents    = <<-EOT
  {{ with secret "secret/data/deepseek" }}{{ .Data.data.api_key }}{{ end }}
  EOT
}
