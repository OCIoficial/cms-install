#! /usr/bin/env bash
# Uso: run-on-main.sh <instance_id> <region> <comando...>
#
# Lo llama Terraform (terraform_data en commands.tf). Ejecuta un comando como
# root en la principal vía SSM, después de que termine su primer arranque, y
# espera el resultado. Requiere la AWS CLI y las credenciales de Terraform.

set -euo pipefail

ID=$1
REGION=$2
shift 2

ssm() { aws --region "$REGION" ssm "$@"; }

# Primero esperar el primer arranque (1 = error; 2 = terminó con advertencias)
PARAMS="{\"commands\":[\"cloud-init status --wait >/dev/null || test \$? -eq 2 || { echo El primer arranque falló, ver /var/log/cloud-init-output.log; exit 1; }\",\"$*\"],\"executionTimeout\":[\"3600\"]}"

# El agente de SSM tarda en registrarse después de que arranca la máquina
for _ in $(seq 60); do
  if CID=$(ssm send-command --instance-ids "$ID" --document-name AWS-RunShellScript \
    --parameters "$PARAMS" --query Command.CommandId --output text 2>/dev/null); then
    break
  fi
  sleep 10
done
if [[ -z ${CID:-} ]]; then
  echo "No se pudo enviar el comando por SSM a $ID" >&2
  exit 1
fi

echo "Ejecutando en la principal: $* (espera a que termine el primer arranque)"
while true; do
  STATUS=$(ssm get-command-invocation --command-id "$CID" --instance-id "$ID" \
    --query Status --output text 2>/dev/null || echo Pending)
  case $STATUS in
    Pending | InProgress | Delayed) sleep 15 ;;
    *) break ;;
  esac
done

ssm get-command-invocation --command-id "$CID" --instance-id "$ID" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
[[ $STATUS == Success ]]
