#!/usr/bin/env bash
# GKE クラスタ (Autopilot / Standard) が存在することを保証する。
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

# 破壊的な操作用。非対話環境では自動承認せず、ASSUME_YES=1 を要求する。
# (CI で意図せずノードが作り直されるのを防ぐため)
confirm_destructive() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    warn "ASSUME_YES=1 のため確認を省略します"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "対話端末がないため中断しました。
       この変更はノードを作り直します。意図している場合は ASSUME_YES=1 を付けて
       再実行するか、config.toml の [cluster] を現在の構成に戻してください。"
  fi
  local answer
  read -r -p "${prompt} [y/N] " answer
  [[ "${answer}" =~ ^[Yy] ]]
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

# 同じ名前のクラスタが別ロケーションにある場合に知らせる。
# (mode を変えるとロケーションがゾーン <-> リージョンで変わるため、
#  気付かないうちに 2 つ目のクラスタを作ってしまう事故を防ぐ)
warn_cluster_elsewhere() {
  local others
  others="$(gcloud container clusters list --project "${PROJECT}" \
    --filter="name=${CLUSTER}" --format='value(location)' 2>/dev/null \
    | paste -sd' ' -)" || return 0
  [[ -n "${others}" ]] || return 0
  warn "同じ名前のクラスタが別のロケーションにあります: ${others}
       これから作るのは ${LOCATION} の別のクラスタです。不要であれば
       gcloud container clusters delete ${CLUSTER} --location <上記> で
       削除してください（どちらも課金対象です）。"
}

create_cluster() {
  warn_cluster_elsewhere
  if [[ "${CFG_CLUSTER_MODE}" == "autopilot" ]]; then
    create_autopilot_cluster
  else
    create_standard_cluster
  fi
}

# Autopilot: ノードは GKE に任せるため、渡すのはロケーションとチャンネルだけ。
# (ip-alias / Workload Identity / shielded nodes / 自動修復・自動アップグレードは
#  Autopilot では常に有効なので指定しない)
create_autopilot_cluster() {
  local args=(
    container clusters create-auto "${CLUSTER}"
    --project "${PROJECT}"
    --region "${LOCATION}"
    --release-channel "${CFG_CLUSTER_RELEASE_CHANNEL}"
    --labels "managed-by=gke-postgresql-statefulset"
  )

  [[ -n "${CFG_CLUSTER_CLUSTER_VERSION}" ]] \
    && args+=(--cluster-version "${CFG_CLUSTER_CLUSTER_VERSION}")

  if [[ -n "${CFG_CLUSTER_EXTRA_CREATE_ARGS}" ]]; then
    read -r -a extra <<<"${CFG_CLUSTER_EXTRA_CREATE_ARGS}"
    args+=("${extra[@]}")
  fi

  local spot_note="false"
  if [[ "${CFG_CLUSTER_SPOT}" == "true" ]]; then
    spot_note="true (PostgreSQL の Pod を Spot Pod として起動します)"
  fi

  cat <<SUMMARY

  ${C_BOLD}作成する GKE Autopilot クラスタ${C_RESET}
    プロジェクト      : ${PROJECT}
    クラスタ名        : ${CLUSTER}
    リージョン        : ${LOCATION} (Autopilot は常にリージョナル)
    リリースチャンネル: ${CFG_CLUSTER_RELEASE_CHANNEL}
    Spot Pod          : ${spot_note}

  ${C_DIM}ノードは Pod の要求に応じて GKE が自動で用意します。
  machine_type / num_nodes などノード関連の設定は使われません。${C_RESET}

  ${C_YELLOW}このクラスタは課金対象です。作成には 5〜10 分ほどかかります。${C_RESET}

SUMMARY

  confirm "クラスタを作成しますか?" || die "中止しました。"

  step "gcloud ${args[*]}"
  gcloud "${args[@]}" || die "クラスタの作成に失敗しました。"
  ok "Autopilot クラスタ ${CLUSTER} を作成しました"
}

create_standard_cluster() {
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

# 既存クラスタの設定を config.toml に合わせる。
# Autopilot にはノードプールが無いため、揃えられるのはリリースチャンネルだけ。
# Standard ではノード数 / オートスケール / リリースチャンネルを無停止で適用し、
# マシンタイプやディスクの変更はノードを作り直すため確認を挟む。
reconcile_cluster() {
  local live facts
  live="$(gcloud container clusters describe "${CLUSTER}" \
            --project "${PROJECT}" "${LOC_FLAG}" "${LOCATION}" \
            --format=json 2>/dev/null)" || {
    warn "クラスタ情報を取得できませんでした。設定差分の確認をスキップします。"
    return 0
  }
  facts="$(printf '%s' "${live}" | python3 "${REPO_ROOT}/scripts/cluster-facts.py")" || {
    warn "クラスタ情報を解釈できませんでした。設定差分の確認をスキップします。"
    return 0
  }
  local LIVE_POOL LIVE_POOL_COUNT LIVE_NODES LIVE_MACHINE_TYPE LIVE_DISK_TYPE \
        LIVE_DISK_SIZE_GB LIVE_IMAGE_TYPE LIVE_SPOT LIVE_AUTOSCALING \
        LIVE_MIN_NODES LIVE_MAX_NODES LIVE_RELEASE_CHANNEL LIVE_MASTER_VERSION \
        LIVE_AUTOPILOT
  eval "${facts}"

  # ---- config.toml が Autopilot のとき ----
  if [[ "${CFG_CLUSTER_MODE}" == "autopilot" ]]; then
    if [[ "${LIVE_AUTOPILOT}" != "true" ]]; then
      warn "config.toml は mode = \"autopilot\" ですが、既存の ${CLUSTER} は
       Standard クラスタです。既存クラスタを Autopilot に変換することはできません。
       Autopilot で作り直す場合は 'make destroy-cluster' の後に 'make db' を
       実行してください。このまま既存の Standard クラスタにデプロイします。"
      return 0
    fi
    if [[ "${CFG_CLUSTER_RELEASE_CHANNEL,,}" != "${LIVE_RELEASE_CHANNEL}" ]]; then
      echo
      printf '  %sクラスタ設定の差分%s\n' "${C_BOLD}" "${C_RESET}"
      printf '    - リリースチャンネル: %s -> %s\n' \
        "${LIVE_RELEASE_CHANNEL}" "${CFG_CLUSTER_RELEASE_CHANNEL,,}"
      echo
      step "リリースチャンネルを ${CFG_CLUSTER_RELEASE_CHANNEL} に変更します"
      gcloud container clusters update "${CLUSTER}" --project "${PROJECT}" \
        "${LOC_FLAG}" "${LOCATION}" \
        --release-channel "${CFG_CLUSTER_RELEASE_CHANNEL}" --quiet \
        || die "リリースチャンネルの変更に失敗しました。"
    fi
    if [[ -n "${CFG_CLUSTER_CLUSTER_VERSION}" \
          && "${CFG_CLUSTER_CLUSTER_VERSION}" != "${LIVE_MASTER_VERSION}" ]]; then
      warn "バージョン (${LIVE_MASTER_VERSION} -> ${CFG_CLUSTER_CLUSTER_VERSION}):
       gcloud container clusters upgrade で明示的に実施してください"
    fi
    ok "Autopilot クラスタ ${CLUSTER} を確認しました (ノードは GKE が管理します)"
    return 0
  fi

  # ---- config.toml が Standard のとき ----
  if [[ "${LIVE_AUTOPILOT}" == "true" ]]; then
    warn "config.toml は mode = \"standard\" ですが、既存の ${CLUSTER} は
       Autopilot クラスタです。Autopilot を Standard に変換することはできません。
       ノード関連の設定調整はスキップし、このままデプロイします。"
    return 0
  fi
  if (( LIVE_POOL_COUNT > 1 )); then
    warn "ノードプールが ${LIVE_POOL_COUNT} 個あります。先頭の ${LIVE_POOL} のみを対象にします。"
  fi

  local -a safe=() disruptive=() manual=() nodepool_args=()
  local do_channel=false do_autoscaling=false do_resize=false

  # ---- 無停止で適用できるもの ----
  local want_channel="${CFG_CLUSTER_RELEASE_CHANNEL,,}"
  if [[ "${want_channel}" != "${LIVE_RELEASE_CHANNEL}" ]]; then
    do_channel=true
    safe+=("リリースチャンネル: ${LIVE_RELEASE_CHANNEL} -> ${want_channel}")
  fi

  if [[ "${CFG_CLUSTER_AUTOSCALING}" != "${LIVE_AUTOSCALING}" ]]; then
    do_autoscaling=true
    if [[ "${CFG_CLUSTER_AUTOSCALING}" == "true" ]]; then
      safe+=("オートスケール: 無効 -> 有効 (${CFG_CLUSTER_MIN_NODES}〜${CFG_CLUSTER_MAX_NODES})")
    else
      safe+=("オートスケール: 有効 -> 無効")
    fi
  elif [[ "${CFG_CLUSTER_AUTOSCALING}" == "true" ]] \
       && [[ "${CFG_CLUSTER_MIN_NODES}" != "${LIVE_MIN_NODES}" \
             || "${CFG_CLUSTER_MAX_NODES}" != "${LIVE_MAX_NODES}" ]]; then
    do_autoscaling=true
    safe+=("オートスケール範囲: ${LIVE_MIN_NODES}〜${LIVE_MAX_NODES} -> ${CFG_CLUSTER_MIN_NODES}〜${CFG_CLUSTER_MAX_NODES}")
  fi

  # オートスケール有効時のノード数はオートスケーラに任せる
  if [[ "${CFG_CLUSTER_AUTOSCALING}" != "true" \
        && "${CFG_CLUSTER_NUM_NODES}" != "${LIVE_NODES}" ]]; then
    do_resize=true
    local suffix=""
    [[ "${CFG_CLUSTER_LOCATION_TYPE}" == "regional" ]] && suffix=" (ゾーンあたり)"
    safe+=("ノード数${suffix}: ${LIVE_NODES} -> ${CFG_CLUSTER_NUM_NODES}")
  fi

  # ---- ノードを作り直すもの ----
  if [[ "${CFG_CLUSTER_MACHINE_TYPE}" != "${LIVE_MACHINE_TYPE}" ]]; then
    nodepool_args+=(--machine-type "${CFG_CLUSTER_MACHINE_TYPE}")
    disruptive+=("マシンタイプ: ${LIVE_MACHINE_TYPE} -> ${CFG_CLUSTER_MACHINE_TYPE}")
  fi
  if [[ "${CFG_CLUSTER_DISK_TYPE}" != "${LIVE_DISK_TYPE}" ]]; then
    nodepool_args+=(--disk-type "${CFG_CLUSTER_DISK_TYPE}")
    disruptive+=("ディスク種別: ${LIVE_DISK_TYPE} -> ${CFG_CLUSTER_DISK_TYPE}")
  fi
  if [[ "${CFG_CLUSTER_DISK_SIZE_GB}" != "${LIVE_DISK_SIZE_GB}" ]]; then
    nodepool_args+=(--disk-size "${CFG_CLUSTER_DISK_SIZE_GB}")
    disruptive+=("ディスク容量: ${LIVE_DISK_SIZE_GB}GB -> ${CFG_CLUSTER_DISK_SIZE_GB}GB")
  fi

  # ---- 既存クラスタには適用できないもの ----
  if [[ "${CFG_CLUSTER_SPOT}" != "${LIVE_SPOT}" ]]; then
    manual+=("Spot VM (${LIVE_SPOT} -> ${CFG_CLUSTER_SPOT}): ノードプールの作り直しが必要です")
  fi
  if [[ "${CFG_CLUSTER_IMAGE_TYPE}" != "${LIVE_IMAGE_TYPE}" ]]; then
    manual+=("イメージタイプ (${LIVE_IMAGE_TYPE} -> ${CFG_CLUSTER_IMAGE_TYPE}): gcloud container node-pools update --image-type で変更してください")
  fi
  if [[ -n "${CFG_CLUSTER_CLUSTER_VERSION}" \
        && "${CFG_CLUSTER_CLUSTER_VERSION}" != "${LIVE_MASTER_VERSION}" ]]; then
    manual+=("バージョン (${LIVE_MASTER_VERSION} -> ${CFG_CLUSTER_CLUSTER_VERSION}): gcloud container clusters upgrade で明示的に実施してください")
  fi

  if (( ${#safe[@]} == 0 && ${#disruptive[@]} == 0 )); then
    ok "クラスタ設定は config.toml と一致しています"
    local item
    for item in "${manual[@]}"; do warn "${item}"; done
    return 0
  fi

  echo
  printf '  %sクラスタ設定の差分%s\n' "${C_BOLD}" "${C_RESET}"
  local item
  for item in "${safe[@]}"; do
    printf '    - %s\n' "${item}"
  done
  for item in "${disruptive[@]}"; do
    printf '    - %s %s← ノードを作り直します%s\n' "${item}" "${C_YELLOW}" "${C_RESET}"
  done
  for item in "${manual[@]}"; do
    printf '    - %s(自動適用しません)%s %s\n' "${C_DIM}" "${C_RESET}" "${item}"
  done
  echo

  if (( ${#disruptive[@]} > 0 )); then
    warn "ノードのローリング置換が発生します。PostgreSQL の Pod は退避・再作成され、
       ノードが 1 台の構成では一時的に停止します。データ (PVC) は保持されます。"
    confirm_destructive "クラスタ設定を更新しますか?" || die "中止しました。"
  fi

  if [[ "${do_channel}" == "true" ]]; then
    step "リリースチャンネルを ${CFG_CLUSTER_RELEASE_CHANNEL} に変更します"
    gcloud container clusters update "${CLUSTER}" --project "${PROJECT}" \
      "${LOC_FLAG}" "${LOCATION}" \
      --release-channel "${CFG_CLUSTER_RELEASE_CHANNEL}" --quiet \
      || die "リリースチャンネルの変更に失敗しました。"
  fi

  if [[ "${do_autoscaling}" == "true" ]]; then
    if [[ "${CFG_CLUSTER_AUTOSCALING}" == "true" ]]; then
      step "オートスケールを有効化します (${CFG_CLUSTER_MIN_NODES}〜${CFG_CLUSTER_MAX_NODES})"
      gcloud container clusters update "${CLUSTER}" --project "${PROJECT}" \
        "${LOC_FLAG}" "${LOCATION}" --node-pool "${LIVE_POOL}" \
        --enable-autoscaling \
        --min-nodes "${CFG_CLUSTER_MIN_NODES}" \
        --max-nodes "${CFG_CLUSTER_MAX_NODES}" --quiet \
        || die "オートスケールの設定に失敗しました。"
    else
      step "オートスケールを無効化します"
      gcloud container clusters update "${CLUSTER}" --project "${PROJECT}" \
        "${LOC_FLAG}" "${LOCATION}" --node-pool "${LIVE_POOL}" \
        --no-enable-autoscaling --quiet \
        || die "オートスケールの無効化に失敗しました。"
    fi
  fi

  if [[ "${do_resize}" == "true" ]]; then
    step "ノード数を ${CFG_CLUSTER_NUM_NODES} に変更します"
    gcloud container clusters resize "${CLUSTER}" --project "${PROJECT}" \
      "${LOC_FLAG}" "${LOCATION}" --node-pool "${LIVE_POOL}" \
      --num-nodes "${CFG_CLUSTER_NUM_NODES}" --quiet \
      || die "ノード数の変更に失敗しました。"
  fi

  if (( ${#nodepool_args[@]} > 0 )); then
    step "ノードプール ${LIVE_POOL} を更新します (ローリング置換のため時間がかかります)"
    gcloud container node-pools update "${LIVE_POOL}" --cluster "${CLUSTER}" \
      --project "${PROJECT}" "${LOC_FLAG}" "${LOCATION}" \
      "${nodepool_args[@]}" --quiet \
      || die "ノードプールの更新に失敗しました。"
  fi

  ok "クラスタ設定を config.toml に合わせました"
}

info "GKE クラスタを確認します (${PROJECT} / ${LOCATION} / ${CLUSTER} / ${CFG_CLUSTER_MODE})"

if gcloud container clusters describe "${CLUSTER}" \
     --project "${PROJECT}" "${LOC_FLAG}" "${LOCATION}" \
     --format='value(name)' >/dev/null 2>&1; then
  ok "クラスタ ${CLUSTER} は既に存在します"

  # config.toml の [cluster] と実際のクラスタの差分を解消する
  # (Autopilot かどうかもこの中で判定して警告する)
  reconcile_cluster
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
