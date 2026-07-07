# homelab

my self-hosted infrastructure for **wrenspace.dev**

## what's here

a 3-node kubernetes cluster running on an old imac via proxmox. flux cd watches this repo and keeps everything in sync. most services run as helm releases.

## hardware

- **etheirys** — imac running proxmox, hosts the k8s vms and a few lxcs
- **amphoreus** — dell optiplex running proxmox, hosts an openmediavault vm serving the `birdpool` zfs pool over nfs (the cluster's storage backend)
- **vulcan** — raspberry pi 4, former nas — idle/standby since `birdpool` moved to amphoreus
- **gunsmoke** — raspberry pi 3b, decommissioned (zigbee2mqtt + matter/thread moved to gallifrey)
- **gallifrey** — raspberry pi 4 running nixos, arm64 k3s worker + home-automation compose stacks

## the stack

- microk8s (v1.33) with calico
- traefik for ingress, metallb for load balancing
- longhorn for block storage, nfs for bulk data
- lldap + authelia for sso/oidc
- sealed secrets for keeping secrets in git

## services

**media:** jellyfin, the arr suite (radarr, sonarr, lidarr, prowlarr, bazarr), qbittorrent, komga

**productivity:** nextcloud, paperless-ngx, grocy

**home:** home assistant, immich

**monitoring:** prometheus, grafana, loki

**infra:** traefik, cert-manager, mariadb, postgres, vaultwarden

## outside the cluster

gitea runs on a proxmox lxc — it has to stay external so flux can pull from it without circular dependencies

## repo layout

```
apps/           # all the kubernetes manifests
flux-system/    # flux bootstrap stuff
proxmox/        # lxc provisioning configs
```

see [CLAUDE.md](CLAUDE.md) for the nitty-gritty details
