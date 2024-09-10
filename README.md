# homelab
repo for gitops-ifying my homelab and publishing my configs.

## infrastructure rundown
my homelab has 3 hosts running as a docker swarm:
- **etheirys** - manager node, 2017 iMac, has dedicated graphics card and 32gb of ram
    - ansible manager w/ semaphore web ui
    - mariadb provider
- **vulcan** - raspberry pi 4 w/ 4gb ram and an 8tb usb hard drive
    - samba/nfs share host
- **gunsmoke** - raspberry pi 3b w/ 1gb ram and a ComBee II

## continuous deployment
testing out [[https://github.com/m-adawi/swarm-cd]] as a continuous deployment tool.