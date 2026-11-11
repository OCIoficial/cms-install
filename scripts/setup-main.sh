#! /usr/bin/bash
# Primer arranque de la máquina principal (lo ejecuta el user_data como root).
# Log: /var/log/cloud-init-output.log

set -euxo pipefail
. /opt/cms-deploy/lib.sh

"$DEPLOY_DIR/setup-common.sh"

# PostgreSQL
set +x
DB_PASSWORD=$(s3_get secrets/db_password -)
export DB_PASSWORD
set -x
"$DEPLOY_DIR/setup-postgres.sh"
unset DB_PASSWORD

# Inicializar la base de datos y crear el administrador (solo si faltan; este
# script se repite si la instalación se interrumpe)
mkdir -p /var/lib/cms-deploy
if [[ ! -f /var/lib/cms-deploy/db-initialized ]]; then
  as_ubuntu "$CMS_BIN/cmsInitDB"
  touch /var/lib/cms-deploy/db-initialized
fi
. "$CMS_HOME/etc/cluster.env"
if [[ -z $(sudo -u postgres psql -d cmsdb -tAc "SELECT 1 FROM admins WHERE username = '$ADMIN_USERNAME'") ]]; then
  set +x
  as_ubuntu "$CMS_BIN/cmsAddAdmin" "$ADMIN_USERNAME" -p "$(s3_get secrets/admin_password -)"
  set -x
fi

# Imágenes del ranking (logo y banderas)
as_ubuntu "$AWS" --region "$AWS_REGION" s3 sync --only-show-errors "s3://$ASSETS_BUCKET/ranking" "$CMS_HOME/lib/ranking"

# Llave SSH para conectarse a los workers (ssh worker-1, ssh worker-2, ...)
install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
set +x
s3_get secrets/worker_ssh_key - | install -m 600 -o ubuntu -g ubuntu /dev/stdin /home/ubuntu/.ssh/id_cms_workers
set -x

# Servicios de CMS
systemctl enable --now cms-log.service cms-resource.service cms-ranking.service

# nginx (solo HTTP; el certificado lo pide Terraform con cms-https, ver commands.tf,
# para que un error de certbot no deje el primer arranque marcado como fallido)
export DEBIAN_FRONTEND=noninteractive
apt-get install -y nginx certbot python3-certbot-nginx python3-certbot-dns-cloudflare
s3_get config/cms.nginx /etc/nginx/sites-available/cms
ln -sf /etc/nginx/sites-available/cms /etc/nginx/sites-enabled/cms
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx.service
systemctl reload nginx.service

install -d -m 700 /etc/letsencrypt
set +x
s3_get secrets/cloudflare.ini - | install -m 600 /dev/stdin /etc/letsencrypt/cloudflare.ini
set -x

echo "setup-main: listo"
