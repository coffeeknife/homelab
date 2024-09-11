# homelab
repo for gitops-ifying my homelab and publishing my configs.

- `/ansible` contains playbooks for regular cluster maintenance.
- `/stacks` contains composefiles for all my docker services.
- `/gallifrey` contains composefiles and configs for my non-swarm node.

## infrastructure rundown
my homelab has 3 hosts running as a docker swarm:
- **etheirys** - manager node, 2017 iMac, has dedicated graphics card and 32gb of ram
    - ansible manager w/ semaphore web ui
    - mariadb provider
- **vulcan** - raspberry pi 4 w/ 4gb ram and an 8tb usb hard drive
    - samba/nfs share host
- **gunsmoke** - raspberry pi 3b w/ 1gb ram and a ComBee II

finally, I have an extra node running my vpn service and DNS:
- **gallifrey** - raspberry pi 4 w/ 2gb ram
    - wireguard vpn
    - pihole dns and adblock
    - network monitor

## continuous deployment
stacks auto updated using Portainer

## todo
- [ ] move caddy stack from portainer to ansible
- [ ] move extra caddy routing (for external services) from portainer to ansible
- [ ] create set of playbooks to bootstrap the whole cluster (docker swarm + docker node tags, semaphore, portainer)
- [ ] add all gallifrey stacks to repo
