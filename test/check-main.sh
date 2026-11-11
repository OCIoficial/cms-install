#! /usr/bin/bash
# Corre en la principal (como root), precedido de lib-check.sh. Ver test/run.sh.
# Argumento: prep | contest. Verifica que la máquina principal quedó funcionando.

set -uo pipefail
MODE=$1

http_ok() { # http_ok <host> -> 2xx/3xx a través de nginx
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" http://127.0.0.1/)
  [[ $code =~ ^[23] ]]
}

echo "== Principal (modo $MODE)"
echo "-- Servicios systemd"
for unit in postgresql cms-log cms-resource cms-ranking nginx; do
  check "$unit activo" systemctl is-active --quiet "$unit"
done

echo "-- Servicios de CMS levantados por el ResourceService"
services=(ScoringService Checker EvaluationService ContestWebServer AdminWebServer)
[[ $MODE == prep ]] && services+=(Worker)
for svc in "${services[@]}"; do
  check "cms$svc" wait_for 90 pgrep -f "cms$svc"
done

echo "-- Base de datos"
check "administrador 'admin' creado" \
  bash -c "sudo -u postgres psql -d cmsdb -tAc \"SELECT 1 FROM admins WHERE username='admin'\" | grep -q 1"

echo "-- Web (nginx)"
check "ContestWebServer (cms.test)" wait_for 30 http_ok cms.test
check "AdminWebServer (cms-admin.test)" wait_for 30 http_ok cms-admin.test
check "Ranking (ranking.test)" wait_for 30 http_ok ranking.test
check "logo del ranking" test -f /home/ubuntu/cms/lib/ranking/logo.png

echo "-- Sandbox (isolate como ubuntu)"
check "isolate ejecuta un programa" sudo -u ubuntu bash -c \
  'isolate --cg -b 99 --cleanup; isolate --cg -b 99 --init && isolate --cg -b 99 --run -- /bin/true; r=$?; isolate --cg -b 99 --cleanup; exit $r'

echo "-- Comandos de operación"
check "cms-contest ALL" cms-contest ALL
check "cms-resource activo después de cms-contest" wait_for 30 systemctl is-active --quiet cms-resource
check "cms-ranking-reset" cms-ranking-reset
check "logo restaurado después del reset" test -f /home/ubuntu/cms/lib/ranking/logo.png
check "cms-backup" cms-backup
check "respaldo en ~/cms-backups" bash -c 'ls /home/ubuntu/cms-backups/cms-dump-*.tar.gz'
if [[ $MODE == prep ]]; then
  check "Worker vuelve a levantarse" wait_for 90 pgrep -f cmsWorker
fi

summary "Principal"
