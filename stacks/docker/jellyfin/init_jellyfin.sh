#!/bin/bash

if [ $(dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -c "ok installed") -eq 0 ];
then
  bash <(curl -fsSL https://get.docker.com)
fi

