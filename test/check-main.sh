#! /usr/bin/bash
# Corre en la principal (como root), precedido de lib-check.sh. Ver test/run.sh.
# Argumentos: prep | contest, y cuántas banderas tiene ranking/flags en el repo.
# Verifica que la máquina principal quedó funcionando.

set -uo pipefail
MODE=$1
FLAGS=$2
RANKING=/home/ubuntu/cms/lib/ranking
CONTEST=$(sed -n 's/^CONTEST=//p' /etc/cms/contest)
# Usuario y contraseña para ver el ranking (ranking_public = false, el valor por defecto).
# Siempre con ":": sin él, `curl -u` pide la contraseña por la terminal y la prueba se cuelga.
RANKING_AUTH=$(sed -n 's/^\(oci\):{PLAIN}/\1:/p' /etc/nginx/ranking.htpasswd 2>/dev/null)
RANKING_AUTH=${RANKING_AUTH:-oci:}

http_code() { # http_code <host> [opciones de curl] -> código HTTP a través de nginx
  local host=$1
  shift
  curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "$@" http://127.0.0.1/
}

http_ok() { # http_ok <host> [opciones de curl] -> 2xx/3xx
  [[ $(http_code "$@") =~ ^[23] ]]
}

http_unauthorized() { # http_unauthorized <host> [opciones de curl] -> 401
  [[ $(http_code "$@") == 401 ]]
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
check "Ranking (ranking.test) con usuario y contraseña" wait_for 30 http_ok ranking.test -u "$RANKING_AUTH"
check "Ranking sin contraseña: 401" http_unauthorized ranking.test
check "Ranking con otra contraseña: 401" http_unauthorized ranking.test -u oci:otra
check "contraseñas del ranking legibles solo por root y nginx" \
  bash -c "[[ \$(stat -c '%U:%G %a' /etc/nginx/ranking.htpasswd) == 'root:www-data 640' ]]"
check "logo y $FLAGS banderas del ranking, de ubuntu" ranking_images

echo "-- Importador de usuarios (/import-users)"
# curl con sesión del panel de administración (cookie awslogin)
JAR=$(mktemp)
ADMIN=(-s --resolve cms-admin.test:80:127.0.0.1 -b "$JAR" -c "$JAR")
API=http://cms-admin.test/import-users/api

admin_login() {
  local password xsrf
  password=$(. /opt/cms-deploy/lib.sh && s3_get secrets/admin_password -)
  curl "${ADMIN[@]}" -o /dev/null http://cms-admin.test/login
  xsrf=$(awk '$6 == "_xsrf" {print $7}' "$JAR")
  curl "${ADMIN[@]}" -o /dev/null --data-urlencode "_xsrf=$xsrf" --data-urlencode username=admin \
    --data-urlencode "password=$password" --data-urlencode next=/ http://cms-admin.test/login
}

redirects_to_login() {
  [[ $(curl -s --resolve cms-admin.test:80:127.0.0.1 -o /dev/null -w '%{http_code} %{redirect_url}' \
    http://cms-admin.test/import-users/) =~ ^302\ .*/login\?next=/import-users/$ ]]
}

page_and_assets() { # la página y los JS/CSS que referencia
  local html asset
  html=$(curl "${ADMIN[@]}" -f http://cms-admin.test/import-users/) || return 1
  for asset in $(grep -o '/import-users/assets/[^"]*' <<<"$html"); do
    curl "${ADMIN[@]}" -f -o /dev/null "http://cms-admin.test$asset" || return 1
  done
  grep -q /import-users/assets/ <<<"$html"
}

meta_ok() {
  curl "${ADMIN[@]}" -f "$API/meta" | python3 -c \
    'import json, sys; d = json.load(sys.stdin); assert d["admin"] == "admin" and len(d["teams"]) == 16'
}

import_post() { # import_post <ruta> <json>
  curl "${ADMIN[@]}" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -H 'X-Requested-With: cms-import-users' -d "$2" "$API/$1"
}

IMPORT_BODY='{"contest_id": '"${CONTEST/ALL/null}"', "mapped": ["username", "first_name", "last_name", "password", "region"],
  "rows": [{"username": "prueba-import", "first_name": "  ana  MARÍA", "last_name": "soto",
            "password": "clave1", "region": "Concepción"}]}'

imported_in_db() {
  [[ $(sudo -u postgres psql -d cmsdb -tAc "SELECT u.first_name || '|' || t.code FROM participations p
    JOIN users u ON u.id = p.user_id JOIN teams t ON t.id = p.team_id
    WHERE u.username = 'prueba-import' AND p.contest_id = $CONTEST") == 'Ana María|biobio' ]]
}

csrf_rejected() {
  [[ $(curl "${ADMIN[@]}" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{}' "$API/preview") == 403 ]]
}

import_ok() { [[ $(import_post import "$IMPORT_BODY") == 200 ]]; }

other_password_rejected() {
  local body=${IMPORT_BODY/clave1/otra}
  [[ $(import_post preview "$body") == 200 && $(import_post import "$body") == 400 ]]
}

ranking_has_user() {
  # El ProxyService codifica los ids para el ranking: "-" queda como "_2d"
  curl -s -u "$RANKING_AUTH" -H 'Host: ranking.test' http://127.0.0.1/users/ | grep -q prueba_2dimport \
    && curl -s -u "$RANKING_AUTH" -H 'Host: ranking.test' http://127.0.0.1/teams/ | grep -q biobio
}

check "cms-import-users activo" systemctl is-active --quiet cms-import-users
check "sin sesión redirige al login del panel" wait_for 30 redirects_to_login
admin_login
check "con sesión de admin: página y assets" page_and_assets
check "con sesión de admin: concursos y 16 regiones" meta_ok
check "POST sin encabezado CSRF se rechaza" csrf_rejected
if [[ $CONTEST != ALL ]]; then
  # En otra pasada de checks el usuario ya existe con los mismos datos: no es error
  check "importa un usuario con región (ciudad) al concurso" import_ok
  check "usuario en la base de datos, normalizado y con equipo biobio" imported_in_db
  check "el ranking recibe el usuario y su región" wait_for 30 ranking_has_user
  check "un usuario existente con otra contraseña es un error" other_password_rejected
fi
rm -f "$JAR"

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
