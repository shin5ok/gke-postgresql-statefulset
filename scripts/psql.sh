#!/usr/bin/env bash
# プライマリ Pod 内で psql を対話的に開く。追加引数はそのまま psql に渡る。
#   make psql
#   make psql ARGS='-c "SELECT count(*) FROM orders;"'
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd kubectl

readonly NS="${CFG_POSTGRES_NAMESPACE}"
readonly POD="${POD_OVERRIDE:-${CFG_POSTGRES_NAME}-0}"

kube_context_exists \
  || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make db' を実行してください。"

# 対話端末があるときだけ TTY を割り当てる (CI などでは -t を付けない)
tty_flag=()
[[ -t 0 && -t 1 ]] && tty_flag=(-t)

exec kubectl --context "${CFG_KUBE_CONTEXT}" -n "${NS}" exec -i "${tty_flag[@]}" \
  "${POD}" -c postgresql -- bash -c '
    PGPASSWORD="${APP_PASSWORD}" exec psql \
      --username "${APP_USER}" --dbname "${POSTGRES_DB}" --host 127.0.0.1 "$@"' \
  -- "$@"
