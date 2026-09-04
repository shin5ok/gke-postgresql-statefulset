#!/usr/bin/env bash
# AlloyDB に psql を開く。追加引数はそのまま psql に渡る。
# PSC エンドポイントは VPC 内からしか到達できないため、GKE 上の一時 Pod を経由する。
#   make alloydb-psql
#   make alloydb-psql ARGS='-c "SELECT count(*) FROM orders;"'
#   SUPERUSER=1 make alloydb-psql      … postgres ユーザで postgres DB に接続
#   POOLED=1 make alloydb-psql         … マネージド接続プーリング (6432) 経由で接続
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud kubectl python3
source "$(dirname "${BASH_SOURCE[0]}")/alloydb-lib.sh"

role="app"
[[ "${SUPERUSER:-0}" == "1" ]] && role="superuser"

if [[ "${POOLED:-0}" == "1" ]]; then
  [[ "${CFG_ALLOYDB_CONNECTION_POOLING}" == "true" ]] \
    || die "マネージド接続プーリングが無効です。config.toml の [alloydb] connection_pooling を
       true にして 'make alloydb' を実行してから POOLED=1 を使ってください。"
  export ALLOYDB_PSQL_PORT=6432
  warn "プーラー経由で接続します (${CFG_ALLOYDB_POOL_MODE} モード)。
       transaction モードでは SET / LISTEN / PREPARE などが使えません。"
fi

alloydb_pod_start "${role}"
alloydb_pod_psql "$@"
