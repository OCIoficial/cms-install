#! /usr/bin/bash
# Primer arranque de un worker (lo ejecuta el user_data como root).
# Log: /var/log/cloud-init-output.log

set -euxo pipefail
. /opt/cms-deploy/lib.sh

"$DEPLOY_DIR/setup-common.sh"

# El ResourceService levanta el Worker que corresponde a la IP de esta máquina.
# Reintenta solo hasta que la base de datos de la principal esté disponible.
systemctl enable --now cms-resource.service

echo "setup-worker: listo"
