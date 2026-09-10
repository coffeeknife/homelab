# Traefik: migrated out of the cluster

> **Done 2026-09-09/10.** Traefik no longer runs in-cluster. It runs as a
> standalone binary on an LXC (**traefik-lxc**, `192.168.1.146`, LXC ID 103 on
> **tau-ceti**/`vmbr2`), configured from a separate repo (`~/Dev/traefik` on the
> dev machine, not this one), and reaches cluster state and cluster backends
> over the Kubernetes API and a Tailscale tunnel respectively.

## Why this repo changed

`apps/infrastructure/traefik/manifests/` used to deploy Traefik itself via a
`HelmRelease` (chart values injected from a `configMapGenerator`). That's gone.
The directory now only holds the pieces the *external* Traefik instance needs
the cluster to expose:

| File | Purpose |
|------|---------|
| `namespace.yaml` | `traefik` namespace (kept for the RBAC objects below) |
| `middlewares.yaml` | Traefik `Middleware` CRDs still used by in-cluster apps |
| `ingressclass.yaml` | Standalone `IngressClass` (`traefik`, cluster-default). Every app's `Ingress` relies on this being the default since none set `ingressClassName` explicitly — kept so ingress-class resolution doesn't change now that the real controller lives off-cluster |
| `external-rbac.yaml` | `ServiceAccount` + durable token `Secret` + `ClusterRole`/`ClusterRoleBinding` granting `traefik-external` read access so the off-cluster Traefik process can watch `Ingress`/`IngressRoute` state |

No Traefik pod runs in the cluster anymore. `flux get helmreleases -A` should
not show a `traefik` release.

## How external Traefik sees the cluster

- **Kubernetes API access:** the `kubernetes` and `kubernetesCRD` providers on
  the LXC authenticate to `https://192.168.200.102:6443` (the MetalLB API VIP)
  using the `traefik-external` ServiceAccount token from `external-rbac.yaml`.
  On the LXC this lives at `/etc/traefik/traefik.env`
  (`KUBE_API_ENDPOINT`, `KUBE_TOKEN`) plus the cluster CA at
  `/etc/traefik/kube-ca.crt`.
- **Known RBAC gotcha:** `kubernetesCRD`/`kubernetesIngress` providers also
  watch `configmaps` and `nodes` at **cluster scope** to sync their informer
  caches. Missing that RBAC is a *silent* failure mode — the provider can
  still `list`/`get` `Ingress`/`IngressRoute` objects fine, but the informer
  cache never finishes syncing and **zero routers get built**, with no error
  in the logs. `external-rbac.yaml`'s `ClusterRole` already grants
  `services`, `endpoints`, `secrets`, `configmaps`, `nodes`, `endpointslices`,
  and the `traefik.io` CRDs — don't trim those thinking they're unused.
- **Reaching pod/service backends:** annotations only give Traefik the
  *routing rules*; it still has to dial the actual pod IPs
  (`10.42.0.0/16`) and ClusterIPs (`10.43.0.0/16`). traefik-lxc reaches those
  over a **Tailscale tunnel**, tagged `tag:traefik`, with a
  **grants-based** ACL policy (the legacy `action`-based ACL format is
  deprecated — see https://tailscale.com/docs/reference/migrate-acls-grants).
  The existing **unbound LXC** (`192.168.1.156`) advertises the pod/service
  CIDRs into the tailnet; traefik-lxc just accepts routes, it doesn't
  advertise any itself.
- **DNS:** unbound (`192.168.1.156`) split-horizons `*.wrenspace.dev` to
  traefik-lxc's LAN IP (`192.168.1.146`) directly — LAN/local clients never
  need Tailscale to reach it. Tailscale MagicDNS separately carries
  `wrenspace.dev` as a tailnet search domain for remote/tailnet-only clients.

### LXC networking pitfalls hit during setup (for the next time this needs touching)

- **Unprivileged LXCs don't expose `/dev/net/tun` by default** —
  `tailscaled` fails immediately (`status=1`, no TUN device) until the
  container config grants it (a `dev0`-style passthrough, same pattern as the
  ConBee II passthrough on the hass LXC — see the main `CLAUDE.md`).
- **Overlapping-LAN route black hole:** traefik-lxc's own LAN
  (`192.168.1.0/24`) also gets advertised as a Tailscale subnet route from
  another node. When a node accepts a route matching its *own* local subnet,
  Tailscale's policy routing table (52) can outrank the main table, silently
  cutting the node off from its own LAN — symptom is that only Traefik loses
  local connectivity, everything else on the box is fine. Fixed with a
  higher-priority policy rule pinning local traffic to the main table:
  `ip rule add to 192.168.1.0/24 priority 2500 lookup main`, made persistent
  via a `lan-route-priority.service` unit (not in this repo — lives with the
  rest of the LXC's OS config).

## What moved out of this repo: `apps/external-ingress/`

That category used to hold `Service` + `Endpoints` (+ occasionally
`Middleware`/`ServersTransport`) + `Ingress` objects for backends that live
entirely **outside** the cluster — gitea, home-assistant, proxmox, vaultwarden
(all LXCs/hosts on the LAN, not pods). The `Endpoints` objects hardcoded those
hosts' static IPs so the old **in-cluster** Traefik could reach them through
the Kubernetes Service abstraction.

Now that Traefik itself runs on the LAN outside the cluster, that indirection
is pointless — traefik-lxc can just dial `192.168.200.52:3000` (gitea),
`192.168.1.123:8123` (home-assistant), `192.168.1.119:8006` (proxmox), or
`192.168.100.6:8000` (vaultwarden) directly. Those four routes (host rules,
TLS, and — for vaultwarden — the CORS `Middleware`) are now defined as static
routers/middlewares in traefik-lxc's own config (`~/Dev/traefik`), **not** as
Kubernetes objects, and **not** reconciled by Flux. `apps/external-ingress/`
was deleted from this repo 2026-09-10.

If one of those four external services' backend IP or port ever changes, the
fix is on the Traefik LXC side, not in this repo.

## What did *not* change

- **cert-manager** still issues/renews TLS certs for the `Ingress` objects
  that remain in this repo (the cluster-native apps) — external Traefik just
  reads those `Ingress` objects and their `cert-manager.io/cluster-issuer`
  annotation the same as before; it doesn't do its own ACME.
- **Cloudflare Tunnel** (`cloudflare-operator`, `TunnelBinding` CRs) is a
  fully separate public-ingress path for `auth.wrenspace.dev`,
  `drive.wrenspace.dev`, `docs.wrenspace.dev`, and `i.wrenspace.dev` —
  `cloudflared` targets those Kubernetes `Service`s **directly** and does not
  traverse Traefik at all, in or out of cluster. Don't assume every public
  hostname goes through traefik-lxc.

## Operational notes

- Every in-cluster `Ingress`/Helm `ingress.annotations` block is expected to
  set `traefik.ingress.kubernetes.io/router.entrypoints: websecure` explicitly
  (audited/backfilled repo-wide 2026-09-10) — external Traefik has no
  in-cluster default to fall back on the way an in-cluster deployment's static
  config might.
- To validate the LXC is actually picking up cluster state:
  `curl http://localhost:8080/api/http/routers` and
  `.../api/http/services` on traefik-lxc — router/service names ending in
  `@kubernetes` or `@kubernetescrd` confirm the provider is live; backend
  addresses in the `10.42.x.x`/`10.43.x.x` range confirm the Tailscale path to
  pods is working.
