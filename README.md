# README
repo to hold k3s and docker configs for my homelab. this is an incredibly WIP setup.

## Nodes

| Hostname | Hardware | OS | Role | Reference |
| --- | --- | --- | ---| --- |
| `etheirys` | 2017 iMac, modded w/ 32gb RAM | CentOS 7 | Kubernetes controller | Final Fantasy XIV |
| `vulcan` | RPi 4, 4GB RAM | Raspbian (bullseye) | Kubernetes node | Star Trek |
| `gunsmoke` | RPi 3B, 1GB RAM | Raspbian (bullseye) | Kubernetes node | Trigun |
| `gallifrey` | RPi 4, 2GB RAM | Raspbian (bullseye) | Dedicated VPN + PiHole DNS | Doctor Who |

I'm slowly collecting hardware to build a rack server, which will serve as another control-plane node. All four nodes are running docker standalone for when I need to use dedicated hardware on the machine. (I'll figure out how to roll this all into k3s eventually.) 

Why is `etheirys` on CentOS? Entirely so I can put it on my resume.

Yes, all of my nodes are named after planets even though my local domain is `bird.nest`.

## General config notes

- cluster is running k3s bare metal
- MetalLB load balancer
- i'm very heavily referencing http://rpi4cluster.com for my configs

## Service IPs

Including here for personal reference - these are the public IPs of services deployed on K3S with MetalLB. My router's DHCP does not assign anything higher than `.199` to anything joining the network, and MetalLB uses `.200-.250`.

| IP | Service | Port | Purpose |
| --- | --- | --- | --- |
| `192.168.1.202` | Local Docker registry | `5000` | Will hold self-built images |
| `192.168.1.203` | ArgoCD | `80` | Continuous deployment from Git (migration from portainer in progress) |
| `192.168.1.204` | Uptime Kuma | `3001` | Uptime monitor w/ Discord notifications |
| `192.168.1.205` | Homebridge | `8581` | Home automation |
| `192.168.1.206` | LinkerD UI | `80` | Secure inter-pod communication |
| `192.168.1.207` | Fasten | `8080` | Health dashboard |
| `192.168.1.208` | Prometheus | `9090` | Monitoring |
| `192.168.1.209` | Grafana | `3000` | Monitoring | 

## Todo

- [ ] Local HTTPS (i have no idea what i'm doing)
    - i'm still very traefik illiterate, but once i figure out how to restrict ingresses to LAN i can just use my owned domain
- [x] ~~service mesh for intercommunication~~ **LinkerD successfully installed**
- [ ] SSO provider
- [ ] Figure out networked `ffmpeg` so Jellyfin can run on k3s
- [ ] calibre web for ebooks, kavita for comics/manga/graphic novels
- [ ] Nextcloud
- [ ] paperless-ngx
- [ ] network backup service
- [ ] mqtt broker
- [ ] network SANE interface for scanning + CUPS server?
- [ ] MySQL provider for cluster w/ backups and management UI
