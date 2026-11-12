# Funciones para las verificaciones. Se incluye con `source`.

FAILED=0
pass() { echo "  OK    $1"; }
fail() { echo "  FALLA $1"; FAILED=1; }

# check <descripción> <comando...>
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# wait_for <segundos> <comando...>: reintenta hasta que el comando tenga éxito
wait_for() {
  local timeout=$1
  shift
  for ((i = 0; i < timeout; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

summary() {
  echo
  if [[ $FAILED -eq 0 ]]; then
    echo "$1: TODO OK"
  else
    echo "$1: HAY FALLAS. Revisar: journalctl -u cms-resource, /home/ubuntu/cms/log/"
  fi
  return $FAILED
}
