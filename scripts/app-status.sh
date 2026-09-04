#!/usr/bin/env bash
# デプロイしたサンプルアプリの状態とアクセス方法を表示する。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd kubectl

readonly NS="${CFG_APP_NAMESPACE}"
readonly NAME="${CFG_APP_NAME}"
readonly SUMMARY_ONLY="${1:-}"

kube_context_exists \
  || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make app' を実行してください。"

if [[ "${SUMMARY_ONLY}" != "--summary" ]]; then
  info "Deployment"
  kc -n "${NS}" get deployment "${NAME}" -o wide 2>/dev/null || warn "見つかりません ('make app' でデプロイ)"
  echo
  info "Pod"
  kc -n "${NS}" get pods -l "app=${NAME}" -o wide 2>/dev/null || true
  echo
  info "Service"
  kc -n "${NS}" get svc "${NAME}" 2>/dev/null || true
  echo
fi

target="$(kc -n "${NS}" get configmap "${NAME}-config" -o 'jsonpath={.data.DB_TARGET}' 2>/dev/null || true)"
host="$(kc -n "${NS}" get configmap "${NAME}-config" -o 'jsonpath={.data.DB_HOST}' 2>/dev/null || true)"
ready="$(kc -n "${NS}" get deployment "${NAME}" -o 'jsonpath={.status.readyReplicas}' 2>/dev/null || true)"
svc_type="$(kc -n "${NS}" get svc "${NAME}" -o 'jsonpath={.spec.type}' 2>/dev/null || true)"

lb_ip=""
if [[ "${svc_type}" == "LoadBalancer" ]]; then
  for _ in $(seq 1 24); do
    lb_ip="$(kc -n "${NS}" get svc "${NAME}" \
      -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${lb_ip}" ]] && break
    sleep 5
  done
fi

cat <<INFO

${C_BOLD}サンプルアプリ${C_RESET}
  Namespace       : ${NS}
  Ready レプリカ  : ${ready:-0} / ${CFG_APP_REPLICAS}
  接続先 (稼働中) : ${target:-不明} (${host:-不明})
  接続先 (設定)   : ${CFG_APP_TARGET}$(if [[ -n "${target}" && "${target}" != "${CFG_APP_TARGET}" ]]; then printf '  %s<- config.toml と異なります。make app で反映%s' "${C_YELLOW}" "${C_RESET}"; fi)
$(if [[ -n "${lb_ip}" ]]; then cat <<LB

  ${C_DIM}# ブラウザで開く (外部 IP)${C_RESET}
  http://${lb_ip}/
LB
elif [[ "${svc_type}" == "LoadBalancer" ]]; then cat <<LB

  ${C_YELLOW}外部 IP はまだ割り当てられていません。しばらくしてから 'make app-status' を実行してください。${C_RESET}
LB
fi)
  ${C_DIM}# 手元のポートに転送してブラウザで開く${C_RESET}
  make app-port-forward      # -> http://localhost:8080/

  ${C_DIM}# 接続先を切り替える${C_RESET}
  make app-target T=alloydb
  make app-target T=postgresql

INFO
