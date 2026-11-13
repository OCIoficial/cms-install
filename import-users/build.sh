#! /usr/bin/env bash
# Uso: import-users/build.sh <carpeta de salida>
#
# Arma el importador de usuarios en <carpeta>: el backend (server/), los datos
# (data/) y el frontend compilado (static/). Lo ejecuta Terraform en cada plan
# (data "external" en terraform/storage.tf), que después lo sube como
# import-users.zip. Requiere Node.js y npm.
#
# Como programa de data "external": la salida de los comandos va a stderr y
# en stdout queda solo el JSON con la carpeta.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "$1")

cd "$HERE/frontend"
# npm ci solo si cambiaron las dependencias (o no están instaladas)
if [[ ! -f node_modules/.package-lock.json || package-lock.json -nt node_modules/.package-lock.json ]]; then
  npm ci --no-audit --no-fund >&2
fi

rm -rf "$OUT"
mkdir -p "$OUT"
OUT_DIR="$OUT/static" npm run --silent build -- --logLevel warn >&2
cp "$HERE"/server/app.py "$HERE"/server/rules.py "$OUT/"
cp -r "$HERE/data" "$OUT/data"

printf '{"dir": "%s"}\n' "$OUT"
