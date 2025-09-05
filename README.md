# homelab

infrastructure automation

## ported-in services

- [homepage](gethomepage.dev)
- [lldap](https://github.com/lldap/lldap)
- [authelia](https://www.authelia.com/)
- [nextcloud](https://nextcloud.com/)

## useful snippets

generate authelia client secret pair:

```bash
docker run --rm authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
```