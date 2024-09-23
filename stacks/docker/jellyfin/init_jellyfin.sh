#!/bin/bash

apt install curl -y

if [ $(dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -c "ok installed") -eq 0 ];
then
  bash <(curl -fsSL https://get.docker.com)
else
  echo 'docker already installed, skipping'
fi

if [$(systemctl is-active jellyfin) == "active"]; then
  systemctl restart jellyfin
  systemctl status jellyfin
  exit 0
else
  # create service file for jellyfin
  COMPOSEFILE="$(pwd)/docker-compose.yaml"
  cat > /etc/systemd/system/jellyfin.service << EOF
  [Unit]
  Description=Jellyfin Docker Compose Stack
  After=docker.service
  Requires=docker.service
  
  [Service]
  Type=oneshot
  RemainAfterExit=yes
  ExecStart=/bin/bash -c "docker compose -f $COMPOSEFILE up --detach"
  ExecStop=/bin/bash -c "docker compose -f $COMPOSEFILE stop"

  [Install]
  WantedBy=multi-user.target
  EOF

  echo 'file made'
fi

exit 0
