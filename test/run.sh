#! /usr/bin/env bash
# Prueba el despliegue en VMs de Incus (Ubuntu 24.04 con cloud-init), sin AWS:
# - S3 lo simula moto (en el bridge de Incus).
# - Terraform real (solo los recursos del bucket) genera config, secretos y user_data.
# - Las VMs arrancan con ese user_data, con las mismas IPs que la VPC.
# - Recorre los cambios de modo de un despliegue real: worker creado apagado y
#   con la instalación interrumpida, cambio de scripts/, preparación ↔
#   competencia, concurso específico y un apply sin cambios. Encender/apagar el
#   worker y los comandos de commands.tf (SSM) se imitan con incus.
# - Sube un concurso de ocimatic con cms-task (test/cms-task/), como
#   tools/cms-task-push pero con incus en vez de scp/ssh.
# No se prueba: IAM, security groups, SSM, Cloudflare/HTTPS (cms-https se reemplaza).
#
# Uso:
#   test/run.sh                  todo desde cero (~30 minutos)
#   test/run.sh check            vuelve a correr las verificaciones
#   test/run.sh shell [worker]   consola en la principal (o en el worker)
#   test/run.sh clean            borra VMs, red, moto y archivos temporales
#
# Requiere: incus (con KVM), terraform, aws (CLI v2), uv, node y npm.

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
    -target=aws_s3_object.config -target=aws_s3_object.secrets -target=aws_s3_object.import_users
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

# run_on <vm> <comando...>: lo que hace terraform/run-on-instance.sh vía SSM
run_on() {
  local vm=$1
  shift
  incus exec "$vm" -- bash -c \
    "{ cloud-init status --wait >/dev/null || test \$? -eq 2; } && /usr/local/bin/cms-update-scripts && $*"
}

# contest <id>: los comandos de commands.tf (cms_contest y, si el worker está
# encendido, cms_worker_restart)
contest() {
  run_on "$MAIN" cms-contest "$1"
  if [[ $(cat "$WORK/workers_running") == true ]]; then
    run_on "$WORKER" systemctl restart cms-resource.service
  fi
}

checks() {
  local mode status=0
  mode=$([[ $(cat "$WORK/workers_running") == true ]] && echo contest || echo prep)
  # Se copian a la VM y se ejecutan desde un archivo: si el texto del script
  # quedara en la línea de comandos, `pgrep -f` lo encontraría a sí mismo
  cat "$ROOT/test/lib-check.sh" "$ROOT/test/check-main.sh" | incus exec "$MAIN" -- sh -c 'cat > /root/check-main.sh'
  incus exec "$MAIN" -- bash /root/check-main.sh "$mode" "$(find "$ROOT/ranking/flags" -name '*.png' | wc -l)" || status=1
  if [[ $mode == contest ]]; then
    cat "$ROOT/test/lib-check.sh" "$ROOT/test/check-worker.sh" | incus exec "$WORKER" -- sh -c 'cat > /root/check-worker.sh'
    incus exec "$WORKER" -- bash /root/check-worker.sh || status=1
    if diff <(incus exec "$MAIN" -- cat /home/ubuntu/cms/etc/cms.toml) \
      <(incus exec "$WORKER" -- cat /home/ubuntu/cms/etc/cms.toml) >/dev/null; then
      echo "  OK    el worker tiene el mismo cms.toml que la principal"
    else
      echo "  FALLA el worker tiene el mismo cms.toml que la principal"
      status=1
    fi
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
# El importador, sin node_modules (build.sh hace npm ci)
tar -C "$ROOT" --exclude=node_modules --exclude=dist -c import-users | tar -C "$WORK" -x
# Sin el estado ni los tokens reales
rm -f "$WORK/terraform/terraform.tfstate"* "$WORK/terraform/secrets.auto.tfvars"
cp "$ROOT"/test/terraform/*.tf "$WORK/terraform/"
# Sin Cloudflare: no pedir certificado
printf '#!/bin/bash\necho "cms-https: omitido en la prueba"\n' > "$WORK/scripts/bin/cms-https"
# Archivo que se borra más adelante: debe desaparecer de las máquinas
echo "obsoleto" > "$WORK/scripts/obsoleto.txt"
tf init -input=false >/dev/null

status=0
result() { # result <descripción> <comando...>
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "  OK    $name"; else echo "  FALLA $name"; status=1; fi
}
not() { ! "$@"; }

sql() { incus exec "$MAIN" -- sudo -u postgres psql -d cmsdb -tAc "$1"; }

# export_zip <carpeta> <zip>: arma el zip como `ocimatic export-cms`
export_zip() {
  (cd "$1" && rm -f "$2" && python3 -c 'import shutil, sys; shutil.make_archive(sys.argv[1], "zip", ".")' "${2%.zip}")
}

# cms_task <zip> <nombre del log>: lo que hace tools/cms-task-push. Log en test/.work/
# Cada zip con su propio nombre en la VM, como cms-task-push: incus conserva el dueño
# del archivo (uid 1000 = ubuntu en la VM) y root no puede sobrescribirlo en /tmp
# (fs.protected_regular).
cms_task() {
  if ! incus file push "$1" "$MAIN/tmp/$2.zip" >"$WORK/$2.log" 2>&1; then
    echo "  (no se pudo copiar $1 a la VM, ver $WORK/$2.log)"
    return 2
  fi
  incus exec "$MAIN" -- cms-task start "/tmp/$2.zip" --contest "$CONTEST_ID" >"$WORK/$2.log" 2>&1
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
# Lo que hace terraform_data.import_users al crear la principal
run_on "$MAIN" cms-import-users-update
checks || status=1
result "$MAIN: scripts/obsoleto.txt instalado (se borra más adelante)" \
  incus exec "$MAIN" -- test -f /opt/cms-deploy/obsoleto.txt

echo
echo "== Modo competencia (workers_running = true), con un cambio en scripts/"
MARK="# prueba de actualización $(date +%s)"
echo "$MARK" >> "$WORK/scripts/bin/cms-backup"
echo "$MARK" >> "$WORK/scripts/systemd/cms-log.service"
rm "$WORK/scripts/obsoleto.txt"
apply true
worker_state running
contest ALL
checks || status=1
echo "-- Scripts actualizados en máquinas existentes"
for vm in "$MAIN" "$WORKER"; do
  result "$vm: comando nuevo" incus exec "$vm" -- grep -qxF "$MARK" /usr/local/bin/cms-backup
  result "$vm: servicio nuevo" incus exec "$vm" -- grep -qxF "$MARK" /etc/systemd/system/cms-log.service
  result "$vm: archivo borrado de scripts/ ya no está" incus exec "$vm" -- test ! -e /opt/cms-deploy/obsoleto.txt
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
contest "$CONTEST_ID"
checks || status=1
result "contest_id inexistente se rechaza sin tocar CMS" \
  bash -c "! incus exec $MAIN -- cms-contest 9999 && incus exec $MAIN -- grep -qx CONTEST=$CONTEST_ID /etc/cms/contest"

echo
echo "== Vuelta a modo preparación"
apply false
worker_state stopped
contest "$CONTEST_ID"
checks || status=1
export_zip "$ROOT/test/cms-task" "$WORK/cms-export.zip"
result "cms-task se niega a medir con los workers apagados" not cms_task "$WORK/cms-export.zip" cms-task-prep
result "  y no crea la tarea" test "$(sql "SELECT count(*) FROM tasks WHERE name = 'suma'")" = 0

echo
echo "== De nuevo modo competencia (worker ya instalado)"
apply true
worker_state running
contest "$CONTEST_ID"
checks || status=1

echo
echo "== Subir problemas con cms-task (logs en test/.work/cms-task-*.log)"
tester_submissions() {
  sql "SELECT count(*) FROM submissions s JOIN participations p ON s.participation_id = p.id
       JOIN users u ON p.user_id = u.id JOIN tasks t ON s.task_id = t.id
       WHERE u.username = 'tester' AND t.name = 'suma'"
}
suma_datasets() { # cantidad de datasets|dataset activo
  sql "SELECT count(*), max(t.active_dataset_id) FROM datasets d JOIN tasks t ON d.task_id = t.id WHERE t.name = 'suma'"
}
result "importa el concurso y las soluciones dan lo esperado" cms_task "$WORK/cms-export.zip" cms-task-1
# 0 si no se creó la tarea: así las consultas siguientes fallan sin error de sintaxis
DATASET=$(sql "SELECT coalesce(max(active_dataset_id), 0) FROM tasks WHERE name = 'suma'")
result "  la tarea queda en el concurso, en primer lugar" \
  test "$(sql "SELECT contest_id, num, title FROM tasks WHERE name = 'suma'")" = "$CONTEST_ID|0|Suma"
result "  un dataset, con el límite medido (0.5 s) y 256 MiB" \
  test "$(sql "SELECT count(*), max(time_limit), max(memory_limit) FROM datasets WHERE id = $DATASET")" = "1|0.5|268435456"
result "  casos públicos y checker compilado" \
  test "$(sql "SELECT (SELECT count(*) FROM testcases WHERE dataset_id = $DATASET AND public),
                      (SELECT count(*) FROM managers WHERE dataset_id = $DATASET AND filename = 'checker')")" = "3|1"
result "  el usuario tester es oculto" test "$(sql "SELECT p.hidden FROM participations p JOIN users u
  ON p.user_id = u.id WHERE u.username = 'tester' AND p.contest_id = $CONTEST_ID")" = t
result "  4 envíos del tester" test "$(tester_submissions)" = 4
result "  attach muestra el resultado de la última importación" \
  bash -c "incus exec $MAIN -- cms-task attach | grep -qx 'RESULTADO: OK'"

result "volver a importar reemplaza el dataset" cms_task "$WORK/cms-export.zip" cms-task-2
AFTER=$(suma_datasets)
result "  queda un solo dataset, el nuevo" test "${AFTER%|*}" = 1 -a "$AFTER" != "1|$DATASET"
result "  y solo los envíos nuevos del tester" test "$(tester_submissions)" = 4

# Una solución con un resultado esperado que no se cumple: la importación falla y no cambia nada
cp -r "$ROOT/test/cms-task" "$WORK/cms-task-mal"
sed -i 's/"expected": {"1": "OK", "2": "WA"}/"expected": {"1": "OK", "2": "OK"}/' \
  "$WORK/cms-task-mal/suma/task.json"
export_zip "$WORK/cms-task-mal" "$WORK/cms-export-mal.zip"
BEFORE=$(suma_datasets)
result "una importación con diferencias falla" not cms_task "$WORK/cms-export-mal.zip" cms-task-3
result "  y reporta la diferencia" grep -q "partial/mal.cpp: subtarea 2 dio WA, se esperaba OK" "$WORK/cms-task-3.log"
result "  y no cambia el dataset" test "$(suma_datasets)" = "$BEFORE"
result "  ni los envíos del tester" test "$(tester_submissions)" = 4

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
El ranking (http://ranking.test) pide usuario oci y contraseña: $(tf output -raw ranking_password).
El importador de usuarios está en http://cms-admin.test/import-users/.

Consola: $0 shell [worker]    Borrar todo: $0 clean
EOF
exit $status
