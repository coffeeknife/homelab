# homelab

infrastructure automation

## ported-in services

- [homepage](gethomepage.dev)
- [lldap](https://github.com/lldap/lldap)
- [authelia](https://www.authelia.com/)
- [nextcloud](https://nextcloud.com/)
- [paperless-ngx](https://docs.paperless-ngx.com/) with FTP server for network scanner

## services remaining stateful on proxmox

- [gitea](https://about.gitea.com/) - git host. needs to be outside cluster for argo to pull them uninterrupted. repos are mirrored to public providers for data loss prevention

## useful snippets

generate authelia client secret pair:

```bash
docker run --rm authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
```