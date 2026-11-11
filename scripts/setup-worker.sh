#! /usr/bin/bash
# Primer arranque de un worker (lo ejecuta el user_data como root).
# Log: /var/log/cloud-init-output.log

set -euxo pipefail
. /opt/cms-deploy/lib.sh

"$DEPLOY_DIR/setup-common.sh"

# Permitir SSH desde la máquina principal
install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
grep -qxF "$WORKER_SSH_PUBKEY" /home/ubuntu/.ssh/authorized_keys 2>/dev/null \
  || echo "$WORKER_SSH_PUBKEY" >> /home/ubuntu/.ssh/authorized_keys
chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys

# El ResourceService levanta el Worker que corresponde a la IP de esta máquina.
# Reintenta solo hasta que la base de datos de la principal esté disponible.
systemctl enable --now cms-resource.service

echo "setup-worker: listo"
