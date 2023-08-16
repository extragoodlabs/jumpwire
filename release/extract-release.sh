#!/bin/bash
set -euo pipefail

mkdir -p /etc/jumpwire.d

TARBALLS=(/tmp/jumpwire-*.tar.gz)

echo "Extracting ${TARBALLS[-1]} to /opt/jumpwire"
tar -C /opt/jumpwire --overwrite -xf "${TARBALLS[-1]}"
chown -R jumpwire:jumpwire /opt/jumpwire /etc/jumpwire.d/
