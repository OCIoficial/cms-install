#! /usr/bin/env bash
# Prueba el despliegue en VMs de Incus (Ubuntu 24.04 con cloud-init), sin AWS:
# - S3 lo simula moto (en el bridge de Incus).
# - Terraform real (solo los recursos del bucket) genera config, secretos y user_data.
# - Las VMs arrancan con ese user_data, con las mismas IPs que la VPC.
# - Recorre los cambios de modo de un despliegue real: worker creado apagado y
#   con la instalación interrumpida, cambio de scripts/, preparación ↔
#   competencia, concurso específico y un apply sin cambios. Encender/apagar el
#   worker y los comandos de commands.tf (SSM) se imitan con incus.
# No se prueba: IAM, security groups, SSM, Cloudflare/HTTPS (cms-https se reemplaza).
#
# Uso:
#   test/run.sh                  todo desde cero (~30 minutos)
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

# Solo los recursos del bucket: lo demás (EC2, DNS, commands.tf) se imita con incus
tf_args() {
  echo -var workers_running="$1" -var worker_count=1 -var domain=test -var cloudflare_certbot_token=test \
    -var letsencrypt_email=test@example.com -var cloudflare_zone_id=00000000000000000000000000000000 \
    -target=aws_s3_object.scripts -target=aws_s3_object.ranking \
    -target=aws_s3_object.config -target=aws_s3_object.secrets
}

# apply <workers_running>: sube a moto lo que en AWS sube Terraform
apply() {
  # shellcheck disable=SC2046
  tf apply -auto-approve -input=false $(tf_args "$1") >/dev/null
  echo "$1" > "$WORK/workers_running"
}

# worker_state <running|stopped>: lo que hace aws_ec2_instance_state
worker_state() {
  if [[ $1 == running ]]; then
    incus start "$WORKER"
    wait_boot "$WORKER"
  else
    incus stop --timeout 120 "$WORKER" || incus stop -f "$WORKER"
  fi
}

# run_on_main <comando...>: lo que hace terraform/run-on-main.sh vía SSM
run_on_main() {
  incus exec "$MAIN" -- bash -c \
    "{ cloud-init status --wait >/dev/null || test \$? -eq 2; } && /usr/local/bin/cms-update-scripts && $*"
}

checks() {
  local mode status=0
  mode=$([[ $(cat "$WORK/workers_running") == true ]] && echo contest || echo prep)
  # Se copian a la VM y se ejecutan desde un archivo: si el texto del script
  # quedara en la línea de comandos, `pgrep -f` lo encontraría a sí mismo
  cat "$ROOT/test/lib-check.sh" "$ROOT/test/check-main.sh" | incus exec "$MAIN" -- sh -c 'cat > /root/check-main.sh'
  cat "$ROOT/test/lib-check.sh" "$ROOT/test/check-worker.sh" | incus exec "$MAIN" -- sh -c 'cat > /root/check-worker.sh'
  incus exec "$MAIN" -- bash /root/check-main.sh "$mode" || status=1
  if [[ $mode == contest ]]; then
    incus exec "$MAIN" -- bash /root/check-worker.sh || status=1
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

# wait_boot <nombre>: espera a que cloud-init termine en este arranque (user_data incluido)
wait_boot() {
  until incus exec "$1" -- true 2>/dev/null; do sleep 5; done
  # Código 1 = error; 2 = terminó con advertencias
  if [[ $(incus exec "$1" -- cloud-init status --wait >/dev/null; echo $?) -eq 1 ]]; then
    echo "FALLÓ el primer arranque de $1. Últimas líneas:"
    incus exec "$1" -- tail -40 /var/log/cloud-init-output.log
    return 1
  fi
  echo "$1: arranque completo"
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

# Red con el mismo rango que la VPC (10.20.0.0/16). Las VMs resuelven nombres con
# DNS públicos, no con el de tu red (que puede filtrar o tener caché vencido).
incus network create "$NET" ipv4.address=10.20.0.1/16 ipv4.nat=true ipv6.address=none \
  raw.dnsmasq="$(printf 'no-resolv\nserver=8.8.8.8\nserver=1.1.1.1')"

# S3 local
nohup uvx --from 'moto[server]' moto_server -H 10.20.0.1 -p 5000 > "$WORK/moto.log" 2>&1 &
until curl -s -o /dev/null "$MOTO"; do sleep 1; done

# Terraform real sobre una copia del repo, con el proveedor apuntando a moto
cp -r "$ROOT/terraform" "$ROOT/scripts" "$ROOT/ranking" "$WORK/"
rm -f "$WORK/terraform/terraform.tfstate"*
cp "$ROOT"/test/terraform/*.tf "$WORK/terraform/"
# Sin Cloudflare: no pedir certificado
printf '#!/bin/bash\necho "cms-https: omitido en la prueba"\n' > "$WORK/scripts/bin/cms-https"
tf init -input=false >/dev/null

status=0
result() { # result <descripción> <comando...>
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "  OK    $name"; else echo "  FALLA $name"; status=1; fi
}

echo "== Modo preparación (workers_running = false)"
apply false
echo "Lanzando VMs. La instalación tarda ~15-20 minutos (log: /var/log/cloud-init-output.log en cada VM)."
launch "$MAIN" 10.20.1.10 4GiB 20GiB "$(tf output -raw test_user_data_main)"
launch "$WORKER" 10.20.1.11 2GiB 12GiB "$(tf output -raw test_user_data_worker)"
# Con workers_running = false, AWS apaga el worker apenas se crea: se apaga a
# mitad de la instalación y debe terminarla en el próximo arranque
until incus exec "$WORKER" -- test -f /opt/cms-deploy/setup-common.sh 2>/dev/null; do sleep 5; done
sleep 30
echo "Apagando $WORKER a mitad de la instalación"
# Forzado: durante la instalación la VM no atiende el apagado ordenado a tiempo
incus stop -f "$WORKER"
wait_boot "$MAIN"
checks || status=1

echo
echo "== Modo competencia (workers_running = true), con un cambio en scripts/"
MARK="# prueba de actualización $(date +%s)"
echo "$MARK" >> "$WORK/scripts/bin/cms-backup"
echo "$MARK" >> "$WORK/scripts/systemd/cms-log.service"
apply true
worker_state running
run_on_main cms-contest ALL
checks || status=1
echo "-- Scripts actualizados en máquinas existentes"
for vm in "$MAIN" "$WORKER"; do
  result "$vm: comando nuevo" incus exec "$vm" -- grep -qxF "$MARK" /usr/local/bin/cms-backup
  result "$vm: servicio nuevo" incus exec "$vm" -- grep -qxF "$MARK" /etc/systemd/system/cms-log.service
  result "$vm: systemd recargado" \
    bash -c "[[ \$(incus exec $vm -- systemctl show -p NeedDaemonReload --value cms-log) == no ]]"
done

echo
echo "== Concurso específico (contest_id)"
# Con el importador de CMS (formato italy_yaml), sin tareas ni usuarios
incus exec "$MAIN" -- sudo -u ubuntu -H bash -c 'mkdir -p /tmp/prueba && cat > /tmp/prueba/contest.yaml' <<'YAML'
name: prueba
description: Concurso de prueba
tasks: []
users: []
YAML
incus exec "$MAIN" -- sudo -u ubuntu -H /home/ubuntu/cms/bin/cmsImportContest -L italy_yaml /tmp/prueba
CONTEST_ID=$(incus exec "$MAIN" -- sudo -u postgres psql -d cmsdb -tAc "SELECT id FROM contests WHERE name = 'prueba'")
echo "Concurso creado: $CONTEST_ID"
run_on_main cms-contest "$CONTEST_ID"
checks || status=1
result "contest_id inexistente se rechaza sin tocar CMS" \
  bash -c "! incus exec $MAIN -- cms-contest 9999 && incus exec $MAIN -- grep -qx CONTEST=$CONTEST_ID /etc/cms/contest"

echo
echo "== Vuelta a modo preparación"
apply false
worker_state stopped
run_on_main cms-contest "$CONTEST_ID"
checks || status=1

echo
echo "== De nuevo modo competencia (worker ya instalado)"
apply true
worker_state running
run_on_main cms-contest "$CONTEST_ID"
checks || status=1

echo
echo "== Un apply sin cambios no cambia nada"
# shellcheck disable=SC2046
result "terraform plan sin cambios" tf plan -detailed-exitcode -input=false $(tf_args true)

echo
if [[ $status -eq 0 ]]; then echo "RESULTADO: TODO OK"; else echo "RESULTADO: HAY FALLAS (ver arriba)"; fi

cat <<EOF

Para ver la web, agrega a /etc/hosts:
  10.20.1.10 cms.test cms-admin.test ranking.test
y abre http://cms-admin.test (usuario admin, contraseña: $(tf output -raw admin_password)).

Consola: $0 shell [worker]    Borrar todo: $0 clean
EOF
exit $status
