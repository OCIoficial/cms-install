#! /usr/bin/bash
# Instala PostgreSQL y crea la base de datos de CMS. Correr como root.
# Variables: DB_PASSWORD (obligatoria), MAIN_IP (IP privada donde escuchar),
# VPC_CIDR (red desde la que se aceptan conexiones), DBNAME, DBUSER.

set -e

: "${DB_PASSWORD:?Definir DB_PASSWORD}"
: "${MAIN_IP:?Definir MAIN_IP}"
: "${VPC_CIDR:?Definir VPC_CIDR}"
DBNAME=${DBNAME:-cmsdb}
DBUSER=${DBUSER:-cmsuser}

set -x
export DEBIAN_FRONTEND=noninteractive
apt-get install -y postgresql
systemctl enable --now postgresql.service

psql_postgres() { sudo -u postgres psql -v ON_ERROR_STOP=1 -qtA "$@"; }

CONFIG_FILE=$(psql_postgres -c 'show config_file')
HBA_FILE=$(psql_postgres -c 'show hba_file')

# Escuchar en localhost y en la IP privada (para los workers)
sed -i "s/^#\?listen_addresses.*/listen_addresses = '127.0.0.1,$MAIN_IP'/" "$CONFIG_FILE"
# Aceptar usuario y contraseña desde la VPC (el acceso lo restringen además los security groups)
HBA_LINE="host $DBNAME $DBUSER $VPC_CIDR scram-sha-256"
grep -qxF "$HBA_LINE" "$HBA_FILE" || echo "$HBA_LINE" >> "$HBA_FILE"

# Crear usuario y base de datos (https://cms.readthedocs.io/en/latest/Running%20CMS.html#configuring-the-db)
set +x  # no imprimir la contraseña
if [[ -z $(psql_postgres -c "SELECT 1 FROM pg_roles WHERE rolname='$DBUSER'") ]]; then
  psql_postgres -v pw="$DB_PASSWORD" <<SQL
CREATE ROLE $DBUSER LOGIN PASSWORD :'pw';
SQL
fi
set -x
if [[ -z $(psql_postgres -c "SELECT 1 FROM pg_database WHERE datname='$DBNAME'") ]]; then
  sudo -u postgres createdb --owner="$DBUSER" "$DBNAME"
  psql_postgres --dbname="$DBNAME" -c "ALTER SCHEMA public OWNER TO $DBUSER"
  psql_postgres --dbname="$DBNAME" -c "GRANT SELECT ON pg_largeobject TO $DBUSER"
fi

systemctl restart postgresql.service
