#! /usr/bin/bash
# Corre en el worker (como root, en modo contest), precedido de lib-check.sh.
# Verifica la comunicación entre el worker y la principal. Ver test/run.sh.

set -uo pipefail
# IPs fijas de terraform/config.tf
MAIN_IP=10.20.1.10
WORKER_IP=10.20.1.11
CMS_TOML=/home/ubuntu/cms/etc/cms.toml

db_from_worker() { # mismas credenciales que usa CMS (url de [database] en cms.toml)
  local url
  url=$(grep -oP 'psycopg2://\K[^"]+' $CMS_TOML)
  psql "postgresql://$url" -tAc 'SELECT 1' | grep -qx 1
}
es_connected() { # conexión establecida desde la principal al puerto del Worker
  ss -Htn state established '( sport = :26000 )' | grep -qF "$MAIN_IP"
}

# '[c]msWorker' evita que pgrep encuentre su propio comando
echo "== Worker remoto ($WORKER_IP)"
check "cms-resource activo en el worker" systemctl is-active --quiet cms-resource
check "cms.toml lista el worker remoto" grep -qF "[\"$WORKER_IP\",26000]" $CMS_TOML

echo "-- PostgreSQL acepta conexiones desde el worker"
check "psql desde el worker a $MAIN_IP:5432" db_from_worker

echo "-- CMS usa el worker remoto"
check "cmsWorker corre en el worker" wait_for 120 pgrep -f '[c]msWorker'
check "EvaluationService conectado al worker" wait_for 120 es_connected

summary "Worker"
