#! /usr/bin/env bash
# Prueba el despliegue en VMs de Incus (Ubuntu 24.04 con cloud-init), sin AWS:
# - S3 lo simula moto (en el bridge de Incus).
# - Terraform real (solo los recursos del bucket) genera config, secretos y user_data.
# - Las VMs arrancan con ese user_data, con las mismas IPs que la VPC.
# No se prueba: IAM, security groups, Cloudflare/HTTPS (cms-https se reemplaza).
#
# Uso:
#   test/run.sh                  todo desde cero (~20 minutos)
#   test/run.sh check            vuelve a correr las verificaciones
#   test/run.sh shell [worker]   consola en la principal (o en el worker)
#   test/run.sh clean            borra VMs, red, moto y archivos temporales
#
# Requiere: incus (con KVM), terraform, aws (CLI v2), uv.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/test/.work
NET=cms-test
MAIN=cms-test-main
WORKER=cms-test-worker
MOTO=http://10.20.0.1:5000

tf() {
  env -u AWS_PROFILE CLOUDFLARE_API_TOKEN=test terraform -chdir="$WORK/terraform" "$@"
}

s3() {
  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url "$MOTO" --region us-east-2 s3 "$@"
}

# apply <workers_running>: sube a moto lo que en AWS sube Terraform
apply() {
  tf apply -auto-approve -input=false \
    -var workers_running="$1" -var worker_count=1 -var domain=test -var cloudflare_certbot_token=test \
    -var letsencrypt_email=test@example.com -var cloudflare_zone_id=00000000000000000000000000000000 \
    -target=aws_s3_object.scripts -target=aws_s3_object.ranking \
    -target=aws_s3_object.config -target=aws_s3_object.secrets >/dev/null
  # Sin Cloudflare: no pedir certificado
  printf '#!/bin/bash\necho "cms-https: omitido en la prueba"\n' \
    | s3 cp - "s3://$(tf output -raw test_assets_bucket)/scripts/bin/cms-https"
  echo "$1" > "$WORK/workers_running"
}

checks() {
  local mode status=0
  mode=$([[ $(cat "$WORK/workers_running") == true ]] && echo contest || echo prep)
  # El script va como argumento (no por stdin, que consumirían ssh/psql)
  incus exec "$MAIN" -- bash -c "$(cat "$ROOT/test/lib-check.sh" "$ROOT/test/check-main.sh")" check "$mode" || status=1
  if [[ $mode == contest ]]; then
    incus exec "$MAIN" -- bash -c "$(cat "$ROOT/test/lib-check.sh" "$ROOT/test/check-worker.sh")" check || status=1
  fi
  return $status
}

clean() {
  incus delete -f "$MAIN" "$WORKER" 2>/dev/null || true
  incus network delete "$NET" 2>/dev/null || true
  pkill -f "[m]oto_server -H 10.20.0.1" || true
  rm -rf "$WORK"
}

# launch <nombre> <ip> <memoria> <disco> <user_data>
launch() {
  incus init images:ubuntu/24.04/cloud "$1" --vm \
    -c limits.cpu=2 -c limits.memory="$3" \
    -c cloud-init.user-data="$5" \
    -c cloud-init.vendor-data="$(cat "$ROOT/test/vendor-data.yaml")"
  incus config device add "$1" eth0 nic network="$NET" ipv4.address="$2"
  incus config device override "$1" root size="$4"
  incus start "$1"
}

# wait_boot <nombre>: espera a que cloud-init termine (user_data incluido)
wait_boot() {
  until incus exec "$1" -- true 2>/dev/null; do sleep 5; done
  # Código 1 = error; 2 = terminó con advertencias
  if [[ $(incus exec "$1" -- cloud-init status --wait >/dev/null; echo $?) -eq 1 ]]; then
    echo "FALLÓ el primer arranque de $1. Últimas líneas:"
    incus exec "$1" -- tail -40 /var/log/cloud-init-output.log
    return 1
  fi
  echo "$1: primer arranque completo"
}

case ${1:-run} in
  clean) clean; exit ;;
  check) checks; exit ;;
  shell) exec incus exec "$([[ ${2:-} == worker ]] && echo "$WORKER" || echo "$MAIN")" -- bash ;;
  run) ;;
  *) echo "Uso: $0 [run|check|shell [worker]|clean]" >&2; exit 1 ;;
esac

clean
mkdir -p "$WORK"

# Red con el mismo rango que la VPC (10.20.0.0/16)
incus network create "$NET" ipv4.address=10.20.0.1/16 ipv4.nat=true ipv6.address=none

# S3 local
nohup uvx --from 'moto[server]' moto_server -H 10.20.0.1 -p 5000 > "$WORK/moto.log" 2>&1 &
until curl -s -o /dev/null "$MOTO"; do sleep 1; done

# Terraform real sobre una copia del repo, con el proveedor apuntando a moto
cp -r "$ROOT/terraform" "$ROOT/scripts" "$ROOT/ranking" "$WORK/"
rm -f "$WORK/terraform/terraform.tfstate"*
cp "$ROOT"/test/terraform/*.tf "$WORK/terraform/"
tf init -input=false >/dev/null
apply false # modo preparación (workers_running = false)

echo "Lanzando VMs. La instalación tarda ~15-20 minutos (log: /var/log/cloud-init-output.log en cada VM)."
launch "$MAIN" 10.20.1.10 4GiB 20GiB "$(tf output -raw test_user_data_main)"
launch "$WORKER" 10.20.1.11 2GiB 12GiB "$(tf output -raw test_user_data_worker)"
wait_boot "$MAIN"
wait_boot "$WORKER"

status=0
checks || status=1

echo
echo "== Cambio a modo competencia (workers_running = true + cms-contest ALL)"
apply true
incus exec "$MAIN" -- cms-contest ALL
checks || status=1

cat <<EOF

Para ver la web, agrega a /etc/hosts:
  10.20.1.10 cms.test cms-admin.test ranking.test
y abre http://cms-admin.test (usuario admin, contraseña: $(tf output -raw admin_password)).

Consola: $0 shell [worker]    Borrar todo: $0 clean
EOF
exit $status
