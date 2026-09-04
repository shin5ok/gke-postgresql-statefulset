#!/usr/bin/env bash
# AlloyDB に psql を開く。追加引数はそのまま psql に渡る。
# PSC エンドポイントは VPC 内からしか到達できないため、GKE 上の一時 Pod を経由する。
#   make alloydb-psql
#   make alloydb-psql ARGS='-c "SELECT count(*) FROM orders;"'
#   SUPERUSER=1 make alloydb-psql      … postgres ユーザで postgres DB に接続
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud kubectl python3
source "$(dirname "${BASH_SOURCE[0]}")/alloydb-lib.sh"

role="app"
[[ "${SUPERUSER:-0}" == "1" ]] && role="superuser"

alloydb_pod_start "${role}"
alloydb_pod_psql "$@"
