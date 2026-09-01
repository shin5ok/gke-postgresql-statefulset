#!/usr/bin/env bash
# 作成したリソースを削除する。
#   destroy.sh db       … StatefulSet / PVC / Namespace を削除 (クラスタは残す)
#   destroy.sh cluster  … GKE クラスタごと削除
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud kubectl

readonly TARGET="${1:-}"
readonly NS="${CFG_POSTGRES_NAMESPACE}"
readonly NAME="${CFG_POSTGRES_NAME}"

confirm() {
  local prompt="$1" expect="$2" answer
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    warn "ASSUME_YES=1 のため確認を省略します"
    return 0
  fi
  [[ -t 0 ]] || die "対話端末がありません。意図的に削除する場合は ASSUME_YES=1 を付けてください。"
  read -r -p "${prompt} 続行するには '${expect}' と入力してください: " answer
  [[ "${answer}" == "${expect}" ]] || die "入力が一致しません。中止しました。"
}

case "${TARGET}" in
  db)
    kube_context_exists || die "context ${CFG_KUBE_CONTEXT} がありません。"
    cat <<WARN

  ${C_YELLOW}${C_BOLD}Namespace ${NS} を削除します。${C_RESET}
  ${C_YELLOW}PersistentVolumeClaim も削除され、データベースの中身は失われます。${C_RESET}
  クラスタ ${CFG_CLUSTER_NAME} 自体は残ります。

WARN
    confirm "本当に削除しますか?" "${NS}"
    info "Namespace ${NS} を削除します"
    kc delete namespace "${NS}" --wait=true || warn "削除に失敗、または既に存在しません"
    # StatefulSet の PVC は Retain 設定なので明示的に消す
    kc -n "${NS}" delete pvc -l "app=${NAME}" --ignore-not-found >/dev/null 2>&1 || true
    ok "削除しました"
    ;;

  cluster)
    cat <<WARN

  ${C_YELLOW}${C_BOLD}GKE クラスタ ${CFG_CLUSTER_NAME} (${CFG_CLUSTER_LOCATION}) を削除します。${C_RESET}
  ${C_YELLOW}クラスタ上のすべてのデータと永続ディスクが失われます。${C_RESET}

WARN
    confirm "本当に削除しますか?" "${CFG_CLUSTER_NAME}"
    info "クラスタを削除します (数分かかります)"
    gcloud container clusters delete "${CFG_CLUSTER_NAME}" \
      --project "${CFG_GCP_PROJECT}" \
      "${CFG_CLUSTER_LOCATION_FLAG}" "${CFG_CLUSTER_LOCATION}" \
      --quiet || die "削除に失敗しました"
    kubectl config delete-context "${CFG_KUBE_CONTEXT}" >/dev/null 2>&1 || true
    ok "クラスタを削除しました"
    ;;

  *)
    die "使い方: destroy.sh <db|cluster>"
    ;;
esac
