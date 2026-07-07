#!/usr/bin/env bash
# PostToolUse (Edit|Write) hook: build the kustomize overlay of an edited manifest.
#
# Why: kubeconform validates each file in isolation, but Flux runs
# `kustomize build` on the whole overlay every reconcile. That catches a class of
# errors per-file validation misses entirely — a resource left out of (or a typo
# in) kustomization.yaml's `resources:`, a broken patch target, a bad
# configMapGenerator. A build that fails locally will fail in-cluster too.
#
# Non-blocking: on failure it injects the error into Claude's context but never
# blocks the edit. Degrades gracefully if no kustomize is available.
set -euo pipefail

export PATH="$HOME/go/bin:$HOME/.nix-profile/bin:$PATH"

input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$f" ] || exit 0

# Only manifests under apps/.
case "$f" in
  *apps/*.yaml|*apps/*.yml) ;;
  *) exit 0 ;;
esac
[ -f "$f" ] || exit 0

# Build the overlay the edited file belongs to: the nearest ancestor dir that
# contains a kustomization.yaml. (Editing kustomization.yaml itself → its own dir.)
dir=$(dirname "$f")
while [ "$dir" != "/" ] && [ ! -f "$dir/kustomization.yaml" ] && [ ! -f "$dir/kustomization.yml" ]; do
  dir=$(dirname "$dir")
done
{ [ -f "$dir/kustomization.yaml" ] || [ -f "$dir/kustomization.yml" ]; } || exit 0

# Prefer standalone kustomize; fall back to the copy built into kubectl.
if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1"; }
elif command -v kubectl >/dev/null 2>&1; then
  build() { kubectl kustomize "$1"; }
else
  exit 0
fi

if out=$(build "$dir" 2>&1 >/dev/null); then
  exit 0
fi

jq -n --arg d "$dir" --arg out "$out" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("⚠️ kustomize build failed for overlay " + $d + ":\n" + $out +
      "\nFlux runs this on every reconcile — fix before committing or the whole overlay fails to apply.")
  }
}'
exit 0
