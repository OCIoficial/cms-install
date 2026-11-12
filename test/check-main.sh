#! /usr/bin/bash
# Corre en la principal (como root), precedido de lib-check.sh. Ver test/run.sh.
# Argumentos: prep | contest, y cuántas banderas tiene ranking/flags en el repo.
# Verifica que la máquina principal quedó funcionando.

set -uo pipefail
MODE=$1
FLAGS=$2
RANKING=/home/ubuntu/cms/lib/ranking
CONTEST=$(sed -n 's/^CONTEST=//p' /etc/cms/contest)

http_ok() { # http_ok <host> -> 2xx/3xx a través de nginx
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" http://127.0.0.1/)
  [[ $code =~ ^[23] ]]
}

ranking_images() { # logo y todas las banderas del zip, de ubuntu (el ranking escribe ahí)
  test -f $RANKING/logo.png \
    && [[ $(find $RANKING/flags -name '*.png' | wc -l) -eq $FLAGS ]] \
    && [[ -z $(find $RANKING ! -user ubuntu) ]]
}

echo "== Principal (modo $MODE, concurso $CONTEST)"
echo "-- Servicios systemd"
for unit in postgresql cms-log cms-resource cms-ranking nginx; do
  check "$unit activo" systemctl is-active --quiet "$unit"
done

echo "-- Servicios de CMS levantados por el ResourceService"
check "ResourceService con -a $CONTEST" pgrep -f "[c]msResourceService -a $CONTEST\$"
services=(ScoringService Checker EvaluationService ContestWebServer AdminWebServer)
[[ $MODE == prep ]] && services+=(Worker)
[[ $CONTEST != ALL ]] && services+=(ProxyService)
for svc in "${services[@]}"; do
  check "cms$svc" wait_for 90 pgrep -f "cms$svc"
done
if [[ $MODE == contest ]]; then
  check "la principal no ejecuta un Worker" wait_for 60 bash -c '! pgrep -f "[c]msWorker"'
fi

echo "-- Base de datos"
check "PostgreSQL escucha en la IP privada" bash -c "ss -Hltn | grep -qF '10.20.1.10:5432'"
check "administrador 'admin' creado" \
  bash -c "sudo -u postgres psql -d cmsdb -tAc \"SELECT 1 FROM admins WHERE username='admin'\" | grep -q 1"

echo "-- Web (nginx)"
check "ContestWebServer (cms.test)" wait_for 30 http_ok cms.test
check "AdminWebServer (cms-admin.test)" wait_for 30 http_ok cms-admin.test
check "Ranking (ranking.test)" wait_for 30 http_ok ranking.test
check "logo y $FLAGS banderas del ranking, de ubuntu" ranking_images

echo "-- Sandbox (isolate como ubuntu)"
check "isolate ejecuta un programa" sudo -u ubuntu bash -c \
  'isolate --cg -b 99 --cleanup; isolate --cg -b 99 --init && isolate --cg -b 99 --run -- /bin/true; r=$?; isolate --cg -b 99 --cleanup; exit $r'

echo "-- Comandos de operación"
check "cms-contest $CONTEST" cms-contest "$CONTEST"
check "cms-resource activo después de cms-contest" wait_for 30 systemctl is-active --quiet cms-resource
check "cms-ranking-reset" cms-ranking-reset
check "logo y banderas restaurados después del reset" ranking_images
check "cms-backup" cms-backup
check "respaldo en ~/cms-backups" bash -c 'ls /home/ubuntu/cms-backups/cms-dump-*.tar.gz'
if [[ $MODE == prep ]]; then
  check "Worker vuelve a levantarse" wait_for 90 pgrep -f cmsWorker
fi

summary "Principal"
