---
name: check-vault
description: Verify all required Vault secrets are loaded and accessible
---
Check that every secret path listed in SPEC.md Section 2.1 exists in Vault.
Use: docker exec -e VAULT_TOKEN=$VAULT_TOKEN homeai-vault vault kv get [path]
Report which paths exist, which are missing, and which return auth errors.
Never print the secret values — only confirm presence.
