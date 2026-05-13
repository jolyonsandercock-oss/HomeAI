#!/bin/bash
# /home_ai/scripts/u33-bot-responder.sh
#
# Cron wrapper for the bot-responder microservice. Picks ONE pending
# query-lane bot_instruction, classifies it via Haiku tool-use against the
# query_whitelist, replies via /send/bot. Non-whitelisted senders are
# silently rejected and logged to query_rejections.
#
# Cron: every 5 minutes. Idempotent — picks one row at a time under
# `FOR UPDATE SKIP LOCKED` so parallel runs (overlap) won't double-process.

set -uo pipefail
docker exec homeai-bot-responder python /app/responder.py
