# Nextcloud deployment
Nextcloud can't be fully configured from the helm chart and requires manual intervention to complete setup.

- **HSTS Warnings:** Nextcloud will yell about HSTS even though the header is set in traefik. Shell into the nextcloud pod and add the following to `.htaccess`:
    ```xml
    <IfModule mod_headers.c>
      Header set Strict-Transport-Security "max-age=63072000; always"
      Options -Indexes
    </IfModule>
    ```
- **Mimetype Migrations:** This warning crops up on every install. Shell into the pod and run the following:
    ```bash
    ./occ maintenance:repair --include-expensive
    ```
- **MariaDB Version:** The version of MariaDB running in the cluster is probably newer than the version Nextcloud was built against. Unless this is a corporate environment, this can be ignored fairly safely.
- **Collabora:** Nextcloud Office must be installed from the app store and the url must be set to `https://docs.wrenspace.dev/` (or your domain, if you're using this config and you're not me).