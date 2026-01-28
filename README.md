# homelab

my self-hosted infrastructure for **wrenspace.dev**

## what's here

a 3-node kubernetes cluster running on an old imac via proxmox. flux cd watches this repo and keeps everything in sync. most services run as helm releases.

## hardware

- **etheirys** — imac running proxmox, hosts the k8s vms and a few lxcs
- **vulcan** — raspberry pi 4 with a zfs pool, serves files over nfs/samba
- **gunsmoke** — raspberry pi 3b running zigbee2mqtt and matter/thread for home automation

## the stack

- microk8s (v1.33) with cilium
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
