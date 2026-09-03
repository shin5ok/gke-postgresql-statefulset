#!/usr/bin/env bash
# デプロイした PostgreSQL の状態と接続情報を表示する。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd kubectl

readonly NS="${CFG_POSTGRES_NAMESPACE}"
readonly NAME="${CFG_POSTGRES_NAME}"
readonly SUMMARY_ONLY="${1:-}"

kube_context_exists \
  || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make db' を実行してください。"

app_password() {
  kc -n "${NS}" get secret "${NAME}" -o jsonpath='{.data.APP_PASSWORD}' 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

if [[ "${SUMMARY_ONLY}" != "--summary" ]]; then
  info "StatefulSet"
  kc -n "${NS}" get statefulset "${NAME}" -o wide 2>/dev/null || warn "見つかりません"
  echo
  info "Pod"
  kc -n "${NS}" get pods -l "app=${NAME}" -o wide 2>/dev/null || true
  echo
  info "PersistentVolumeClaim"
  kc -n "${NS}" get pvc -l "app=${NAME}" 2>/dev/null || true
  echo
  info "Service"
  kc -n "${NS}" get svc -l "app=${NAME}" 2>/dev/null || true
  echo

  if [[ "${CFG_HA}" == "true" ]]; then
    info "レプリケーションの状態 (プライマリから見た接続中のスタンバイ)"
    kc -n "${NS}" exec "${NAME}-0" -c postgresql -- \
      psql -U postgres -x -c \
      'SELECT application_name, client_addr, state, sync_state, replay_lag FROM pg_stat_replication;' \
      2>/dev/null || warn "取得できませんでした"
    echo
  fi
fi

lb_ip=""
if [[ "${CFG_POSTGRES_INTERNAL_LB}" == "true" ]]; then
  lb_ip="$(kc -n "${NS}" get svc "${NAME}-lb" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
fi

ready="$(kc -n "${NS}" get statefulset "${NAME}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"

cat <<INFO

${C_BOLD}接続情報${C_RESET}
  クラスタ        : ${CFG_CLUSTER_NAME} (${CFG_CLUSTER_LOCATION} / ${CFG_CLUSTER_MODE})
  Namespace       : ${NS}
  Ready レプリカ  : ${ready:-0} / ${CFG_POSTGRES_REPLICAS}
  データベース    : ${CFG_POSTGRES_DATABASE}
  ユーザ          : ${CFG_POSTGRES_USER}
  パスワード      : $(app_password)

  ${C_DIM}# クラスタ内から (書き込み)${C_RESET}
  postgresql://${CFG_POSTGRES_USER}@${NAME}-rw.${NS}.svc.cluster.local:5432/${CFG_POSTGRES_DATABASE}
$(if [[ "${CFG_HA}" == "true" ]]; then cat <<HA

  ${C_DIM}# クラスタ内から (読み取り: 全レプリカに分散)${C_RESET}
  postgresql://${CFG_POSTGRES_USER}@${NAME}-ro.${NS}.svc.cluster.local:5432/${CFG_POSTGRES_DATABASE}
HA
fi)
$(if [[ -n "${lb_ip}" ]]; then cat <<LB

  ${C_DIM}# 同一 VPC 内から (内部 LoadBalancer)${C_RESET}
  postgresql://${CFG_POSTGRES_USER}@${lb_ip}:5432/${CFG_POSTGRES_DATABASE}
LB
fi)
  ${C_DIM}# 手元から psql を開く${C_RESET}
  make psql

  ${C_DIM}# 手元のポートに転送する (別ターミナルで psql などを使う場合)${C_RESET}
  make port-forward

  ${C_DIM}# スキーマとダミーデータを投入する${C_RESET}
  make db-content

INFO
