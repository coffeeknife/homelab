# README
repo to hold k3s and docker configs for my homelab. this is an incredibly WIP setup.

# Service IPs

Including here for personal reference - these are the public IPs of services deployed on K3S with MetalLB. My router's DHCP does not assign anything higher than `.199` to anything joining the network, and MetalLB uses `.200-.250`.

| IP | Service | Port |
| --- | --- | --- |
| `192.168.1.202` | Local Docker registry | `5000` |
| `192.168.1.203` | Portainer | `9000` |
| `192.168.1.204` | Uptime Kuma | `3001` |
| `192.168.1.205` | Homebridge | `8581` |