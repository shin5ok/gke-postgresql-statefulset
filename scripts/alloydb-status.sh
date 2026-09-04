#!/usr/bin/env bash
# AlloyDB クラスタ / インスタンス / PSC エンドポイントの状態と接続情報を表示する。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud

readonly PROJECT="${CFG_GCP_PROJECT}"
readonly REGION="${CFG_ALLOYDB_REGION}"
readonly CLUSTER="${CFG_ALLOYDB_CLUSTER}"
readonly INSTANCE="${CFG_ALLOYDB_INSTANCE}"
readonly ENDPOINT="${CFG_ALLOYDB_PSC_ENDPOINT}"

info "AlloyDB クラスタ (${PROJECT} / ${REGION})"
gcloud alloydb clusters describe "${CLUSTER}" --region "${REGION}" --project "${PROJECT}" \
  --format='table(name.basename():label=NAME,state:label=STATE,databaseVersion:label=VERSION,pscConfig.pscEnabled:label=PSC,createTime.date():label=CREATED)' \
  2>/dev/null || warn "クラスタ ${CLUSTER} が見つかりません ('make alloydb' で作成)"
echo

info "インスタンス"
gcloud alloydb instances describe "${INSTANCE}" --cluster "${CLUSTER}" --region "${REGION}" \
  --project "${PROJECT}" \
  --format='table(name.basename():label=NAME,state:label=STATE,instanceType:label=TYPE,availabilityType:label=AVAILABILITY,machineConfig.cpuCount:label=VCPU,machineConfig.machineType:label=MACHINE_TYPE,pscInstanceConfig.allowedConsumerProjects.list():label=ALLOWED_PSC_PROJECTS)' \
  2>/dev/null || warn "インスタンス ${INSTANCE} が見つかりません"
echo

info "PSC エンドポイント (${ENDPOINT})"
ip="$(alloydb_psc_ip)"
if [[ -n "${ip}" ]]; then
  gcloud compute forwarding-rules describe "${ENDPOINT}" --project "${PROJECT}" --region "${REGION}" \
    --format='table(name:label=NAME,IPAddress:label=IP,pscConnectionStatus:label=PSC_STATUS,allowPscGlobalAccess:label=GLOBAL_ACCESS,network.basename():label=NETWORK)' \
    2>/dev/null || warn "転送ルール ${ENDPOINT} がありません (予約 IP ${ip} のみ存在)"
else
  warn "予約 IP ${ENDPOINT} がありません ('make alloydb' で作成)"
fi

cat <<INFO

${C_BOLD}接続情報${C_RESET}
  PSC エンドポイント : ${ip:-(未作成)}:5432 (VPC 内からのみ到達可能)
  データベース       : ${CFG_ALLOYDB_DATABASE}
  ユーザ             : ${CFG_ALLOYDB_USER}
  パスワード         : $(alloydb_app_password)
  postgres パスワード: $(alloydb_superuser_password)

  ${C_DIM}# クラスタ内 (VPC 内) から${C_RESET}
  postgresql://${CFG_ALLOYDB_USER}@${ip:-<PSC_IP>}:5432/${CFG_ALLOYDB_DATABASE}?sslmode=require

  ${C_DIM}# psql を開く / ダミーデータを投入する / アプリを切り替える${C_RESET}
  make alloydb-psql
  make alloydb-content
  make app-target T=alloydb

INFO
