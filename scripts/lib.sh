# Funciones comunes para los scripts de despliegue. Se incluye con `source`.
#
# /etc/cms/deploy.env lo escribe el user_data de Terraform al crear la instancia
# (ROLE, AWS_REGION, ASSETS_BUCKET, CMS_REF, MAIN_IP, VPC_CIDR). Lo que puede
# cambiar después vive en S3 (config/) y se baja con cms-sync-config.

set -a
# shellcheck disable=SC1091
. /etc/cms/deploy.env
set +a

DEPLOY_DIR=/opt/cms-deploy
AWS=/usr/local/bin/aws
CMS_HOME=/home/ubuntu/cms
CMS_BIN=$CMS_HOME/bin

# Copia un objeto del bucket de assets: s3_get <key> <destino|->
s3_get() { "$AWS" --region "$AWS_REGION" s3 cp --only-show-errors "s3://$ASSETS_BUCKET/$1" "$2"; }

# Baja un zip del bucket y lo extrae en <dir>, sobrescribiendo: s3_unzip <key> <dir>
s3_unzip() {
  local zip
  zip=$(mktemp)
  s3_get "$1" "$zip"
  unzip -q -o "$zip" -d "$2"
  rm -f "$zip"
}

as_ubuntu() { sudo -u ubuntu -H "$@"; }

# Si se corre como root, vuelve a ejecutar el script como ubuntu
reexec_as_ubuntu() {
  if [[ $EUID -eq 0 ]]; then
    exec sudo -u ubuntu -H "$0" "$@"
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
  fi
}
