#! /usr/bin/bash
# Corre en la principal (como root, en modo contest), precedido de lib-check.sh.
# Verifica la comunicación entre la principal y el worker remoto. Ver test/run.sh.

set -uo pipefail
# IPs fijas de terraform/config.tf
MAIN_IP=10.20.1.10
WORKER_IP=10.20.1.11

db_from_worker() { # mismas credenciales que usa CMS (url de [database] en cms.toml)
  local url
  url=$(grep -oP 'psycopg2://\K[^"]+' /home/ubuntu/cms/etc/cms.toml)
  on_worker "psql 'postgresql://$url' -tAc 'SELECT 1'" | grep -qx 1
}
es_connected() { # conexión establecida desde la principal al puerto del Worker
  on_worker "ss -Htn state established '( sport = :26000 )'" | grep -qF "$MAIN_IP"
}

# '[c]msWorker' evita que pgrep encuentre su propio comando
echo "== Worker remoto ($WORKER_IP)"
check "SSH desde la principal (ssh worker-1)" on_worker true
check "cms-resource activo en el worker" on_worker systemctl is-active --quiet cms-resource
check "el worker tiene el mismo cms.toml que la principal" \
  bash -c 'diff /home/ubuntu/cms/etc/cms.toml <(sudo -u ubuntu ssh worker-1 cat cms/etc/cms.toml)'
check "cms.toml lista el worker remoto" grep -qF "[\"$WORKER_IP\",26000]" /home/ubuntu/cms/etc/cms.toml

echo "-- PostgreSQL acepta conexiones desde el worker"
check "psql desde el worker a $MAIN_IP:5432" db_from_worker
check "PostgreSQL escucha en $MAIN_IP" bash -c "ss -Hltn | grep -qF '$MAIN_IP:5432'"

echo "-- CMS usa el worker remoto"
check "cmsWorker corre en el worker" wait_for 120 on_worker "pgrep -f '[c]msWorker'"
check "EvaluationService conectado al worker" wait_for 120 es_connected
check "la principal ya no ejecuta un Worker" wait_for 60 bash -c '! pgrep -f "[c]msWorker"'

summary "Worker"
