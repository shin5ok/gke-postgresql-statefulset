#!/usr/bin/env bash
# 手元のポートをサンプルアプリの Service に転送する。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd kubectl

readonly NS="${CFG_APP_NAMESPACE}"
readonly NAME="${CFG_APP_NAME}"
readonly LOCAL_PORT="${APP_LOCAL_PORT:-8080}"

kube_context_exists \
  || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make app' を実行してください。"

cat <<INFO

  http://localhost:${LOCAL_PORT}/  ->  svc/${NAME}.${NS}:80

  ${C_DIM}Ctrl-C で終了${C_RESET}

INFO

# kc はシェル関数なので exec できない。kubectl を直接 exec する。
exec kubectl --context "${CFG_KUBE_CONTEXT}" -n "${NS}" port-forward "svc/${NAME}" "${LOCAL_PORT}:80"
