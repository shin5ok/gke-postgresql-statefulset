#!/usr/bin/env bash
# GKE Standard クラスタが存在することを保証する。
# 存在しなければ config.toml の [cluster] の内容で作成し、
# 最後に kubectl の認証情報 (context) を取得する。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud kubectl

readonly PROJECT="${CFG_GCP_PROJECT}"
readonly CLUSTER="${CFG_CLUSTER_NAME}"
readonly LOCATION="${CFG_CLUSTER_LOCATION}"
readonly LOC_FLAG="${CFG_CLUSTER_LOCATION_FLAG}"

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    return 0
  fi
  local answer
  read -r -p "${prompt} [Y/n] " answer
  [[ -z "${answer}" || "${answer}" =~ ^[Yy] ]]
}

enable_apis() {
  local required=(container.googleapis.com compute.googleapis.com)
  local enabled missing=()
  enabled="$(gcloud services list --enabled --project "${PROJECT}" \
    --format='value(config.name)' 2>/dev/null || true)"
  for api in "${required[@]}"; do
    grep -qx "${api}" <<<"${enabled}" || missing+=("${api}")
  done
  if (( ${#missing[@]} > 0 )); then
    step "API を有効化します: ${missing[*]}"
    gcloud services enable "${missing[@]}" --project "${PROJECT}" \
      || die "API の有効化に失敗しました。プロジェクト ${PROJECT} の権限を確認してください。"
  fi
}

create_cluster() {
  local args=(
    container clusters create "${CLUSTER}"
    --project "${PROJECT}"
    "${LOC_FLAG}" "${LOCATION}"
    --machine-type "${CFG_CLUSTER_MACHINE_TYPE}"
    --num-nodes "${CFG_CLUSTER_NUM_NODES}"
    --disk-type "${CFG_CLUSTER_DISK_TYPE}"
    --disk-size "${CFG_CLUSTER_DISK_SIZE_GB}"
    --image-type "${CFG_CLUSTER_IMAGE_TYPE}"
    --release-channel "${CFG_CLUSTER_RELEASE_CHANNEL}"
    --enable-ip-alias
    --no-enable-basic-auth
    --enable-autorepair
    --enable-shielded-nodes
    # --addons を指定すると「ここに書いていない addon は無効化」されるため、
    # 既定の HttpLoadBalancing / HorizontalPodAutoscaling も明示する。
    # GcePersistentDiskCsiDriver は PVC の動的プロビジョニングに必要。
    --addons HttpLoadBalancing,HorizontalPodAutoscaling,GcePersistentDiskCsiDriver
    --labels "managed-by=gke-postgresql-statefulset"
  )

  # リリースチャンネル利用時は自動アップグレードが必須。None のときのみ無効化できる。
  if [[ "${CFG_CLUSTER_RELEASE_CHANNEL}" == "None" ]]; then
    args+=(--no-enable-autoupgrade)
  else
    args+=(--enable-autoupgrade)
  fi

  [[ -n "${CFG_CLUSTER_CLUSTER_VERSION}" ]] \
    && args+=(--cluster-version "${CFG_CLUSTER_CLUSTER_VERSION}")

  if [[ "${CFG_CLUSTER_AUTOSCALING}" == "true" ]]; then
    args+=(--enable-autoscaling
           --min-nodes "${CFG_CLUSTER_MIN_NODES}"
           --max-nodes "${CFG_CLUSTER_MAX_NODES}")
  fi

  [[ "${CFG_CLUSTER_SPOT}" == "true" ]] && args+=(--spot)
  [[ "${CFG_CLUSTER_WORKLOAD_IDENTITY}" == "true" ]] \
    && args+=(--workload-pool "${PROJECT}.svc.id.goog")

  # ユーザ指定の追加フラグ (空白区切り)
  if [[ -n "${CFG_CLUSTER_EXTRA_CREATE_ARGS}" ]]; then
    read -r -a extra <<<"${CFG_CLUSTER_EXTRA_CREATE_ARGS}"
    args+=("${extra[@]}")
  fi

  local nodes_note=""
  [[ "${CFG_CLUSTER_LOCATION_TYPE}" == "regional" ]] \
    && nodes_note=" x 3 ゾーン = $(( CFG_CLUSTER_NUM_NODES * 3 )) ノード"

  cat <<SUMMARY

  ${C_BOLD}作成する GKE Standard クラスタ${C_RESET}
    プロジェクト  : ${PROJECT}
    クラスタ名    : ${CLUSTER}
    ロケーション  : ${LOCATION} (${CFG_CLUSTER_LOCATION_TYPE})
    マシンタイプ  : ${CFG_CLUSTER_MACHINE_TYPE}
    ノード数      : ${CFG_CLUSTER_NUM_NODES}${nodes_note}
    ディスク      : ${CFG_CLUSTER_DISK_TYPE} ${CFG_CLUSTER_DISK_SIZE_GB}GB
    Spot VM       : ${CFG_CLUSTER_SPOT}
    オートスケール: ${CFG_CLUSTER_AUTOSCALING}

  ${C_YELLOW}このクラスタは課金対象です。作成には 5〜10 分ほどかかります。${C_RESET}

SUMMARY

  confirm "クラスタを作成しますか?" || die "中止しました。"

  step "gcloud ${args[*]}"
  gcloud "${args[@]}" || die "クラスタの作成に失敗しました。"
  ok "クラスタ ${CLUSTER} を作成しました"
}

info "GKE クラスタを確認します (${PROJECT} / ${LOCATION} / ${CLUSTER})"

if gcloud container clusters describe "${CLUSTER}" \
     --project "${PROJECT}" "${LOC_FLAG}" "${LOCATION}" \
     --format='value(name)' >/dev/null 2>&1; then
  ok "クラスタ ${CLUSTER} は既に存在します"

  autopilot="$(gcloud container clusters describe "${CLUSTER}" \
    --project "${PROJECT}" "${LOC_FLAG}" "${LOCATION}" \
    --format='value(autopilot.enabled)' 2>/dev/null || true)"
  if [[ "${autopilot}" == "True" ]]; then
    warn "既存の ${CLUSTER} は Autopilot クラスタです。本ツールは Standard を前提に
       していますが、StatefulSet 自体はそのままデプロイできます。"
  fi
else
  step "クラスタ ${CLUSTER} は存在しません。作成します。"
  enable_apis
  create_cluster
fi

info "kubectl の認証情報を取得します"
gcloud container clusters get-credentials "${CLUSTER}" \
  --project "${PROJECT}" "${LOC_FLAG}" "${LOCATION}" \
  || die "get-credentials に失敗しました。"

kube_context_exists \
  || die "context ${CFG_KUBE_CONTEXT} が見つかりません。kubeconfig を確認してください。"

kc cluster-info >/dev/null 2>&1 \
  || die "クラスタ ${CLUSTER} に接続できません。認証情報を確認してください。"

ok "context ${CFG_KUBE_CONTEXT} で接続できました"
