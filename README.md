# homelab
repo for gitops-ifying my homelab and publishing my configs. currenlty greatly overhauling my homelab setup.

- `/ansible` contains playbooks for regular cluster maintenance.
- `/stacks-old` contains old composefiles for services that were run over docker-swarm
- `/gallifrey` contains composefiles and configs for my ingress node.

## infrastructure rundown
- **etheirys** - proxmox host, 2017 iMac, has dedicated graphics card and 32gb of ram
- **vulcan** - raspberry pi 4 w/ 4gb ram and an 8tb usb hard drive
- **gunsmoke** - raspberry pi 3b w/ 1gb ram and a ComBee II
- **gallifrey** - ingress node. nothing other than network access runs here. raspberry pi 4 w/ 2gb ram
    - wireguard vpn
    - adguardhome dns and adblock

## continuous deployment
wip