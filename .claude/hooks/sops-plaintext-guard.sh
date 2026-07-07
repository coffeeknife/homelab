#!/usr/bin/env bash
# PreToolUse (Edit|Write) hook: block a plaintext overwrite of a sops-encrypted file.
#
# Why: files under nixos/secrets/ are encrypted with sops+age. They must be
# edited via `sops <file>` (which decrypts to a temp editor buffer and re-encrypts
# on save). A direct Edit/Write replaces the ciphertext with plaintext, leaking
# the secret into Git AND breaking the sops metadata so nixos can't decrypt it.
#
# It asks (exit 2 with a decision prompt) rather than hard-failing: an Edit that
# preserves the ENC[...] ciphertext is theoretically fine, but almost never what's
# intended, so it surfaces a confirmation.
set -euo pipefail

input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$f" ] || exit 0

# The .sops.yaml policy file itself is plaintext config — never guard it.
case "$f" in
  */.sops.yaml) exit 0 ;;
esac

# Only guard files that are actually sops-encrypted on disk right now.
[ -f "$f" ] || exit 0
grep -Eq 'ENC\[AES256_GCM|^sops:|sops_version' "$f" 2>/dev/null || exit 0

# The replacement text: Write -> content, Edit -> new_string.
text=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty')
# If the edit keeps the ciphertext intact, let it through silently.
printf '%s' "$text" | grep -Eq 'ENC\[AES256_GCM' && exit 0

jq -n --arg f "$f" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("\($f) is sops-encrypted. Editing it directly writes plaintext to Git and corrupts the sops metadata. Edit it with `sops \($f)` instead, which decrypts, lets you edit, and re-encrypts on save.")
  }
}'
exit 0
