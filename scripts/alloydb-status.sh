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

info "マネージド接続プーリング"
# インスタンスの有無とプーリングの状態を 1 回の describe で取る
# (プーリング無効時は connectionPoolConfig 自体が無く、空文字が返る)
inst_name=""; live_pooling=""; live_pool_mode=""
# インスタンスが無いと describe の出力が空になり、read は EOF で 1 を返す。
# set -e で落ちないよう最後に || true を付ける。
read -r inst_name live_pooling live_pool_mode < <(gcloud alloydb instances describe "${INSTANCE}" \
  --cluster "${CLUSTER}" --region "${REGION}" --project "${PROJECT}" \
  --format='value(name,connectionPoolConfig.enabled,connectionPoolConfig.flags.pool_mode)' \
  2>/dev/null || true) || true
have="false"; [[ "${live_pooling,,}" == "true" ]] && have="true"
if [[ -z "${inst_name}" ]]; then
  printf '  %s\n' "インスタンスが無いため確認できません"
elif [[ "${have}" == "true" ]]; then
  printf '  %s\n' "有効 (${live_pool_mode:-transaction} モード) — プーラーは 6432、直結は 5432"
else
  printf '  %s\n' "無効 — 5432 に直接接続します"
fi
if [[ -n "${inst_name}" && "${CFG_ALLOYDB_CONNECTION_POOLING}" != "${have}" ]]; then
  warn "config.toml は connection_pooling = ${CFG_ALLOYDB_CONNECTION_POOLING} ですが、
       インスタンスは ${have} です。'make alloydb' で反映できます。"
fi
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
  PSC エンドポイント : ${ip:-(未作成)} (VPC 内からのみ到達可能)
  ポート             : 5432 (直結)$(if [[ "${live_pooling,,}" == "true" ]]; then printf ' / 6432 (プーリング: %s)' "${live_pool_mode:-transaction}"; fi)
  データベース       : ${CFG_ALLOYDB_DATABASE}
  ユーザ             : ${CFG_ALLOYDB_USER}
  パスワード         : $(alloydb_app_password)
  postgres パスワード: $(alloydb_superuser_password)

  ${C_DIM}# クラスタ内 (VPC 内) から (サンプルアプリはこのポートに接続します)${C_RESET}
  postgresql://${CFG_ALLOYDB_USER}@${ip:-<PSC_IP>}:${CFG_ALLOYDB_PORT}/${CFG_ALLOYDB_DATABASE}?sslmode=require

  ${C_DIM}# psql を開く / ダミーデータを投入する / アプリを切り替える${C_RESET}
  make alloydb-psql$(if [[ "${live_pooling,,}" == "true" ]]; then printf '\n  POOLED=1 make alloydb-psql        # プーラー (6432) 経由で確認する'; fi)
  make alloydb-content
  make app-target T=alloydb

INFO
