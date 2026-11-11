#! /usr/bin/bash
# Pasos comunes a la máquina principal y a los workers. Lo llaman setup-main.sh
# y setup-worker.sh (como root) en el primer arranque.

set -euxo pipefail
. /opt/cms-deploy/lib.sh

"$DEPLOY_DIR/install-dependencies.sh"
usermod -a -G isolate ubuntu

# sudo -u inicializa los grupos desde /etc/group, así que el grupo isolate ya aplica
as_ubuntu env CMS_REF="$CMS_REF" "$DEPLOY_DIR/install-cms.sh"

# Comandos de operación y servicios systemd
"$DEPLOY_DIR/bin/cms-update-scripts"
[[ -f /etc/cms/contest ]] || echo "CONTEST=ALL" > /etc/cms/contest

/usr/local/bin/cms-sync-config
