# Zipline — image pastebin (`i.wrenspace.dev`)

Self-hosted image/file pastebin. Manifests: `apps/services/zipline/`.
Image `ghcr.io/diced/zipline:4.7.0`, its own Postgres (`local-path`), uploads on
NFS (`vulcan-nfs`, 50Gi, `onDelete: retain`). `CORE_SECRET` and the Postgres
password are generated in-cluster by secret-generator — nothing to seal.

## Going public is a two-step deploy, on purpose

Zipline ships with **no default account**: whoever reaches `/setup` first becomes
the super administrator. cert-manager publishes `i.wrenspace.dev` to Certificate
Transparency logs within minutes of issuance, so a fresh instance that is public
before setup is a real (if brief) exposure.

So `manifests/tunnelbinding.yaml` was committed but deliberately left out of
`manifests/kustomization.yaml` until the account existed (done 2026-08-23 — the
binding is active now). Repeat this order for any rebuild from scratch:

1. Deploy the app. It is reachable on the LAN only, at `https://i.wrenspace.dev`
   (internal wildcard DNS → Traefik at `192.168.200.100`).
2. Complete the setup wizard, creating the admin user.
3. Add `- tunnelbinding.yaml` to `manifests/kustomization.yaml`, commit, push.
   The cloudflared ClusterTunnel then serves the hostname publicly and manages
   the Cloudflare DNS record. LAN clients keep resolving to Traefik via the
   internal wildcard, so both paths stay live.

Check which mode you're in: `curl -s https://i.wrenspace.dev/api/setup` returns
`{"firstSetup":true}` while the admin account still does not exist.

## Getting an upload token

Zipline UI → user menu → **Manage Account** → **Token** → copy. That token goes in
`~/.config/zipline/config` on the desktop (mode 600):

```
ZIPLINE_URL=https://i.wrenspace.dev
ZIPLINE_TOKEN=<token>
```

The API takes the raw token in an `authorization:` header — no `Bearer` prefix:

```bash
curl -sS -X POST https://i.wrenspace.dev/api/upload \
  -H "authorization: $ZIPLINE_TOKEN" \
  -F "file=@screenshot.png" | jq -r '.files[0].url'
```

Per-upload behaviour is set with `x-zipline-*` headers (`x-zipline-deletes-at`,
`x-zipline-max-views`, `x-zipline-format`, `x-zipline-folder`,
`x-zipline-password`, `x-zipline-no-json`, …).

## GNOME integration

`~/.local/share/nautilus/scripts/Upload to Zipline` — right-click any file in
Files → **Scripts** → **Upload to Zipline**. Uploads the selection, copies the
URL(s) to the clipboard, shows a notification. Needs `wl-clipboard` for the
clipboard; notifications go over `notify-send` if present, otherwise straight to
the D-Bus notification daemon via `gdbus`. Run `nautilus -q` after adding or
editing a script.

## Notes

- Cloudflare's free tier caps proxied request bodies at 100 MB, which is the real
  upload ceiling on the public hostname regardless of Zipline's own settings.
- The TunnelBinding points cloudflared straight at the Service, so public traffic
  does not pass through Traefik or the Ingress' HSTS middleware.
- Not wired into Authelia. Zipline supports generic OIDC
  (`OAUTH_OIDC_*`) if SSO is wanted later; it would need an Authelia client and a
  sealed secret for the client secret.
