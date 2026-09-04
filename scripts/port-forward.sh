#!/usr/bin/env bash
# 手元のポートをプライマリの 5432 に転送する。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd kubectl

readonly NS="${CFG_POSTGRES_NAMESPACE}"
readonly NAME="${CFG_POSTGRES_NAME}"
readonly LOCAL_PORT="${LOCAL_PORT:-15432}"

require_db_deployed

password="$(kc -n "${NS}" get secret "${NAME}" \
  -o jsonpath='{.data.APP_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"

cat <<INFO

  localhost:${LOCAL_PORT} -> ${NAME}-rw.${NS}.svc.cluster.local:5432

  ${C_DIM}# 別のターミナルから${C_RESET}
  PGPASSWORD='${password}' psql -h 127.0.0.1 -p ${LOCAL_PORT} \\
    -U ${CFG_POSTGRES_USER} -d ${CFG_POSTGRES_DATABASE}

  ${C_DIM}Ctrl-C で終了${C_RESET}

INFO

# kc はシェル関数なので exec できない。kubectl を直接 exec する。
exec kubectl --context "${CFG_KUBE_CONTEXT}" -n "${NS}" port-forward "svc/${NAME}-rw" "${LOCAL_PORT}:5432"
