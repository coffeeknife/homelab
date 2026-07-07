#!/usr/bin/env bash
# PostToolUse (Edit|Write) hook: schema-validate edited Kubernetes manifests.
#
# Why: Flux auto-reconciles `main`, so a malformed manifest reaches the live
# cluster within minutes. This catches YAML/schema errors at authoring time.
#
# Non-blocking: on failure it injects the errors into Claude's context (so they
# get fixed) but never blocks the edit. Degrades gracefully — if kubeconform
# isn't installed yet (fresh machine), it silently exits 0.
set -euo pipefail

# Hooks run in a non-interactive shell, so ~/.bashrc (which adds ~/go/bin) is
# skipped. Make user-local tool dirs discoverable so kubeconform is found.
export PATH="$HOME/go/bin:$HOME/.nix-profile/bin:$PATH"

input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$f" ] || exit 0

# Only manifests under apps/
case "$f" in
  *apps/*.yaml|*apps/*.yml) ;;
  *) exit 0 ;;
esac

# Graceful skip until the toolchain is installed.
command -v kubeconform >/dev/null 2>&1 || exit 0
[ -f "$f" ] || exit 0

# -ignore-missing-schemas: skip CRDs we have no schema for (HelmRelease,
# SealedSecret, etc.) while still strictly checking core kinds (Deployment,
# Service, ConfigMap, Namespace...) where a typo actually breaks things.
if out=$(kubeconform -strict -ignore-missing-schemas -summary "$f" 2>&1); then
  exit 0
fi

jq -n --arg f "$f" --arg out "$out" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("⚠️ kubeconform found issues in " + $f + ":\n" + $out +
      "\nFix before committing — Flux applies main automatically.")
  }
}'
exit 0
