#!/usr/bin/env bash
# PreToolUse (Edit|Write) hook: warn before committing a plaintext k8s Secret.
#
# Why: this repo commits secrets ONLY as encrypted Bitnami SealedSecrets, or as
# secret-generator templates that autogenerate the value in-cluster. A raw
# `kind: Secret` with an inline data:/stringData: block almost always means a
# credential is about to be committed in cleartext.
#
# It asks (not hard-blocks): legitimate cases exist (secret-generator templates),
# so it surfaces a confirmation prompt rather than refusing outright.
set -euo pipefail

input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
case "$f" in
  *.yaml|*.yml) ;;
  *) exit 0 ;;
esac

# Text about to be written: Write -> content, Edit -> new_string.
text=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty')
[ -n "$text" ] || exit 0

# Must declare a core Secret. `kind: SealedSecret`/`ExternalSecret` won't match
# this anchored pattern, so they pass through untouched.
printf '%s' "$text" | grep -Eq '^[[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$' || exit 0

# secret-generator autogenerates the value — no plaintext is committed.
printf '%s' "$text" | grep -Eq 'secret-generator\.v1\.mittwald\.de/autogenerate' && exit 0

# Must carry an inline data/stringData block to be a leak risk.
printf '%s' "$text" | grep -Eq '^[[:space:]]*(data|stringData):' || exit 0

jq -n --arg f "$f" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("This looks like a plaintext Kubernetes Secret (" + $f +
      "). This repo commits secrets as encrypted SealedSecrets — run the seal-secret " +
      "skill instead of committing raw values. Proceed only if this is intentional " +
      "(e.g. a secret-generator template).")
  }
}'
exit 0
