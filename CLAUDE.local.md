# CLAUDE.local.md — P620 local config (never commit this file)

## Hardware
Machine: Lenovo P620, Threadripper 5945WX, 128GB RAM, RTX 3060 12GB
OS: Ubuntu 26.04 LTS

## Network
Tailscale IP: 100.104.82.53
Local subnet: 192.168.x.x (update with actual local IP)

## Mount paths
SSD (OS/DB):  /dev/nvme0n1 → /
HDD (archive): /dev/sda → /mnt/hdd (update after confirming device name)
NAS (backup):  WD MyCloud → /mnt/mycloud (update after mounting)

## Docker container names (verify with: docker compose ps)
postgres:    homeai-postgres
n8n:         homeai-n8n
ollama:      homeai-ollama
vault:       homeai-vault
metabase:    homeai-metabase
pdfplumber:  homeai-pdfplumber
grafana:     homeai-grafana

## Current build state
Phase: 1
Milestone: A
Last completed step: 3
Notes:
  - Ubuntu 26.04 (spec says 22.04 — newer, no issues found)
  - NVIDIA driver 595.58.03 (spec targets 535 — works correctly)
  - Docker 29.4.1 + Compose v5.1.3
  - Tailscale connected: 100.104.82.53
