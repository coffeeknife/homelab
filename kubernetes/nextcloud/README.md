# Nextcloud deployment
Nextcloud can't be fully configured from the helm chart and requires manual intervention to complete setup.

If you open Nextcloud before it's done installing, it may interrupt itself. To fix this enter the pod's shell and run `./occ maintenance:install`.

- **Collabora:** Nextcloud Office must be installed from the app store and the url must be set to `https://docs.wrenspace.dev/`.