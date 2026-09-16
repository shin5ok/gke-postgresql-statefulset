#!/usr/bin/env bash
# config.toml の内容でマニフェストをレンダリングし、PostgreSQL StatefulSet を
# クラスタに適用して Ready になるまで待つ。何度実行しても安全 (冪等)。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud kubectl python3

readonly NS="${CFG_POSTGRES_NAMESPACE}"
readonly NAME="${CFG_POSTGRES_NAME}"
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-900s}"

# RENDER_ONLY=1 のときはクラスタに一切触れずにマニフェストを生成するだけ (オフライン検証用)
readonly RENDER_ONLY="${RENDER_ONLY:-0}"

if [[ "${RENDER_ONLY}" != "1" ]]; then
  kube_context_exists \
    || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make cluster' を実行してください。"
fi

# ---------------------------------------------------------------------------
# パスワードの解決
#   1. クラスタ上の Secret があればその値を引き継ぐ (PGDATA と食い違わせないため)
#   2. config.toml に明示されていればそれを優先
#   3. どちらも無ければ生成して .secrets/ に保存
# ---------------------------------------------------------------------------
secret_value() {
  local key="$1"
  [[ "${RENDER_ONLY}" == "1" ]] && return 0
  kc -n "${NS}" get secret "${NAME}" -o "jsonpath={.data.${key}}" 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

resolve_password() {
  local key="$1" configured="$2" local_name="$3" existing
  existing="$(secret_value "${key}")"

  if [[ -n "${configured}" ]]; then
    if [[ -n "${existing}" && "${existing}" != "${configured}" ]]; then
      warn "${key}: config.toml の値がクラスタ上の Secret と異なります。
       Secret は更新されますが、初期化済みの PGDATA 内のパスワードは変わりません。
       反映するには 'make psql' から ALTER ROLE ... PASSWORD を実行してください。"
    fi
    printf '%s' "${configured}"
  elif [[ -n "${existing}" ]]; then
    printf '%s' "${existing}"
  else
    persisted_secret "${local_name}"
  fi
}

info "パスワードを解決します"
CFG_RESOLVED_SUPERUSER_PASSWORD="$(resolve_password POSTGRES_PASSWORD "" superuser_password)"
CFG_RESOLVED_APP_PASSWORD="$(resolve_password APP_PASSWORD "${CFG_POSTGRES_PASSWORD}" app_password)"
CFG_RESOLVED_REPLICATION_PASSWORD="$(resolve_password REPLICATION_PASSWORD \
  "${CFG_POSTGRES_REPLICATION_PASSWORD}" replication_password)"
CFG_RESOLVED_SUPERUSER_PASSWORD_B64="$(b64 "${CFG_RESOLVED_SUPERUSER_PASSWORD}")"
CFG_RESOLVED_APP_PASSWORD_B64="$(b64 "${CFG_RESOLVED_APP_PASSWORD}")"
CFG_RESOLVED_REPLICATION_PASSWORD_B64="$(b64 "${CFG_RESOLVED_REPLICATION_PASSWORD}")"
export CFG_RESOLVED_SUPERUSER_PASSWORD_B64 CFG_RESOLVED_APP_PASSWORD_B64 \
       CFG_RESOLVED_REPLICATION_PASSWORD_B64
ok "解決しました (生成した値は .secrets/ に保存されます)"

# ---------------------------------------------------------------------------
# postgres に渡す起動パラメータの組み立て
# ---------------------------------------------------------------------------
pg_params=(
  "listen_addresses=*"
  "max_connections=${CFG_POSTGRES_MAX_CONNECTIONS}"
  "shared_buffers=${CFG_POSTGRES_SHARED_BUFFERS}"
  "effective_cache_size=${CFG_POSTGRES_EFFECTIVE_CACHE_SIZE}"
  "maintenance_work_mem=${CFG_POSTGRES_MAINTENANCE_WORK_MEM}"
  "work_mem=${CFG_POSTGRES_WORK_MEM}"
  "wal_level=${CFG_POSTGRES_WAL_LEVEL}"
  "max_wal_senders=${CFG_POSTGRES_MAX_WAL_SENDERS}"
  "max_replication_slots=${CFG_POSTGRES_MAX_REPLICATION_SLOTS}"
  "hot_standby=on"
  "log_min_duration_statement=${CFG_POSTGRES_LOG_MIN_DURATION_STATEMENT}"
  "log_checkpoints=on"
  "log_connections=off"
  "log_timezone=Asia/Tokyo"
  "timezone=Asia/Tokyo"
)
if [[ -n "${CFG_POSTGRES_EXTRA_PG_PARAMS}" ]]; then
  read -r -a extra_params <<<"${CFG_POSTGRES_EXTRA_PG_PARAMS}"
  pg_params+=("${extra_params[@]}")
fi
# YAML のフローシーケンスとして安全に埋め込む
CFG_PG_ARGS_YAML="$(python3 -c '
import json, sys
args = []
for p in sys.argv[1:]:
    args.extend(["-c", p])
print(json.dumps(args))' "${pg_params[@]}")"
export CFG_PG_ARGS_YAML

# ---------------------------------------------------------------------------
# マニフェストのレンダリング
# ---------------------------------------------------------------------------
info "マニフェストを ${BUILD_DIR#"${REPO_ROOT}/"}/ にレンダリングします"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# ConfigMap を先に作り、そのチェックサムを StatefulSet に埋め込む
# (スクリプトが変わったら Pod がローリング更新されるようにするため)
# stdout=マニフェスト本体, stderr=チェックサム。2>&1 を先に書くことで
# stderr だけをコマンド置換で受け取り、stdout はファイルへ流す。
CFG_SCRIPTS_CHECKSUM="$(python3 "${REPO_ROOT}/scripts/mk-configmap.py" \
  "${NAME}-scripts" "${NS}" "${REPO_ROOT}/manifests/pg-scripts" \
  2>&1 1>"${BUILD_DIR}/20-configmap.yaml")" \
  || die "ConfigMap の生成に失敗しました: ${CFG_SCRIPTS_CHECKSUM}"
export CFG_SCRIPTS_CHECKSUM

render() {
  local tmpl="${REPO_ROOT}/manifests/$1.yaml.tmpl"
  python3 "${REPO_ROOT}/scripts/render.py" "${tmpl}" > "${BUILD_DIR}/$1.yaml" \
    || die "$1.yaml.tmpl のレンダリングに失敗しました"
  step "$1.yaml"
}

if [[ "${CFG_PG_CUSTOM_COMPUTE_CLASS}" == "true" && "${CFG_CLUSTER_SPOT}" == "true" ]]; then
  warn "postgres.compute_class = ${CFG_POSTGRES_COMPUTE_CLASS} はカスタム ComputeClass として扱うため、
       PostgreSQL の Pod には Spot の nodeSelector (cloud.google.com/gke-spot) を付けません
       (ComputeClass と併記すると GKE が Pod を拒否します)。Spot で動かすには ComputeClass の
       priorities に spot: true を書いてください。"
fi

render 00-namespace
[[ "${CFG_HYPERDISK}" == "true" ]] && render 05-storageclass
render 10-secret
step "20-configmap.yaml (checksum: ${CFG_SCRIPTS_CHECKSUM})"
render 30-service
[[ "${CFG_HA}" == "true" ]] && render 31-service-ro
[[ "${CFG_POSTGRES_INTERNAL_LB}" == "true" ]] && render 35-service-lb
render 40-statefulset
[[ "${CFG_HA}" == "true" ]] && render 50-pdb

if [[ "${RENDER_ONLY}" == "1" ]]; then
  ok "レンダリングのみ実行しました: ${BUILD_DIR}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 既存 PVC のサイズ調整 (volumeClaimTemplates は変更不可のため個別に対応)
# ---------------------------------------------------------------------------
reconcile_pvcs() {
  local pvcs
  pvcs="$(kc -n "${NS}" get pvc -l "app=${NAME}" -o name 2>/dev/null || true)"
  [[ -z "${pvcs}" ]] && return 0

  local pvc current current_class desired="${CFG_POSTGRES_STORAGE_SIZE}"
  while read -r pvc; do
    [[ -z "${pvc}" ]] && continue
    # StorageClass は PVC の作成後に変更できない。設定と違うものはそのまま使われることを知らせる。
    current_class="$(kc -n "${NS}" get "${pvc}" \
      -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
    if [[ -n "${current_class}" && "${current_class}" != "${CFG_POSTGRES_STORAGE_CLASS}" ]]; then
      warn "${pvc} は StorageClass ${current_class} のまま使われます (PVC の StorageClass は変更できません)。
       ${CFG_POSTGRES_STORAGE_CLASS} が適用されるのは、これから新しく作られる PVC だけです。
       配置先のノードがこのディスクをアタッチできない場合 (例: N4 ノードに Persistent Disk)、
       その Pod は Pending のままになります。既存のデータごと移行するにはスナップショットから
       ディスクを複製するか、make destroy-db → make db → make db-content で作り直してください。"
    fi
    current="$(kc -n "${NS}" get "${pvc}" \
      -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)"
    [[ -z "${current}" || "${current}" == "${desired}" ]] && continue

    case "$(python3 "${REPO_ROOT}/scripts/qty.py" "${current}" "${desired}")" in
      grow)
        step "${pvc} を ${current} -> ${desired} に拡張します"
        kc -n "${NS}" patch "${pvc}" --type merge \
          -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${desired}\"}}}}" \
          || warn "${pvc} の拡張に失敗しました (StorageClass の allowVolumeExpansion を確認)"
        ;;
      shrink)
        warn "${pvc} は現在 ${current} で、設定値 ${desired} より大きいため縮小しません。
       (PersistentVolume の縮小は Kubernetes ではサポートされていません)"
        ;;
    esac
  done <<<"${pvcs}"
}

# ---------------------------------------------------------------------------
# Hyperdisk Balanced 用 StorageClass の調整
#   parameters (IOPS / スループット) は作成後に変更できず、apply が Forbidden で失敗する。
#   差分があれば削除して作り直す。プロビジョニング済みのボリュームは StorageClass を
#   消しても影響を受けない (作成時の値のまま動き続ける)。
# ---------------------------------------------------------------------------
reconcile_storageclass() {
  local sc="${CFG_POSTGRES_STORAGE_CLASS}" live verdict
  live="$(kc get storageclass "${sc}" -o json 2>/dev/null)" || return 0
  verdict="$(printf '%s' "${live}" | python3 -c '
import json, os, sys
live = json.load(sys.stdin)
want = json.loads(os.environ["CFG_STORAGE_CLASS_PARAMS_JSON"])
labels = live.get("metadata", {}).get("labels") or {}
same = (live.get("provisioner") == "pd.csi.storage.gke.io"
        and live.get("volumeBindingMode") == "WaitForFirstConsumer"
        and (live.get("parameters") or {}) == want)
managed = labels.get("app.kubernetes.io/managed-by") == "gke-postgresql-statefulset"
print("same" if same else ("recreate" if managed else "foreign"))')" \
    || die "StorageClass ${sc} の内容を解釈できませんでした"
  case "${verdict}" in
    same) ;;
    recreate)
      step "StorageClass ${sc} のパラメータが変わりました: ${CFG_STORAGE_CLASS_PARAMS_JSON}"
      step "作り直します (作成済みのボリュームは元のパラメータのまま使われます)"
      kc delete storageclass "${sc}" || die "StorageClass ${sc} を削除できませんでした"
      ;;
    *)
      die "StorageClass ${sc} は既に存在し、このツールが作ったものではなく設定も異なります。
       kubectl --context ${CFG_KUBE_CONTEXT} get storageclass ${sc} -o yaml で内容を確認し、
       手で作ったものなら kubectl --context ${CFG_KUBE_CONTEXT} delete storageclass ${sc} で
       削除してから再実行してください (StorageClass を消しても作成済みのボリュームには影響しません)。
       このツールが作る parameters: ${CFG_STORAGE_CLASS_PARAMS_JSON}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Hyperdisk 対応ノードへの自動配置 (StorageClass の use-allowed-disk-topology) は
# GKE 1.34.1-gke.2541000 以降でしか動かず、古いクラスタでは Pod が Pending のままになる。
# 適用する前にコントロールプレーンと既存ノードのバージョンを確認する。
# ---------------------------------------------------------------------------
# "v1.35.7-gke.1222000" のような GKE のバージョンを比較する ($1 >= $2 なら 0)
gke_version_at_least() {
  python3 - "$1" "$2" <<'PY'
import re, sys
def key(v):
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)(?:-gke\.(\d+))?", v)
    if not m:
        sys.exit(2)
    return tuple(int(x or 0) for x in m.groups())
sys.exit(0 if key(sys.argv[1]) >= key(sys.argv[2]) else 1)
PY
}

check_hyperdisk_support() {
  local min="${CFG_HYPERDISK_MIN_GKE_VERSION}" server nodes name ver old=""
  server="$(kc version -o json 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')" \
    || die "クラスタのバージョンを取得できませんでした"
  gke_version_at_least "${server}" "${min}" \
    || die "GKE ${server} では Hyperdisk 対応ノードへの自動配置 (StorageClass の use-allowed-disk-topology)
       を使えません。クラスタを ${min} 以降にアップグレードしてください。"
  step "GKE ${server}: Hyperdisk 対応ノードへの自動配置を使えます"
  nodes="$(kc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.nodeInfo.kubeletVersion}{"\n"}{end}' \
    2>/dev/null || true)"
  while read -r name ver; do
    [[ -z "${name}" ]] && continue
    gke_version_at_least "${ver}" "${min}" || old+=" ${name} (${ver})"
  done <<<"${nodes}"
  if [[ -n "${old}" ]]; then
    warn "次のノードは ${min} より古いため、Hyperdisk のボリュームを持つ Pod は配置されません:${old}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 適用
# ---------------------------------------------------------------------------
info "クラスタに適用します (context: ${CFG_KUBE_CONTEXT})"
kc apply -f "${BUILD_DIR}/00-namespace.yaml"
if [[ -e "${BUILD_DIR}/05-storageclass.yaml" ]]; then
  check_hyperdisk_support
  reconcile_storageclass
  kc apply -f "${BUILD_DIR}/05-storageclass.yaml"
fi
kc apply -f "${BUILD_DIR}/10-secret.yaml"
kc apply -f "${BUILD_DIR}/20-configmap.yaml"
for f in "${BUILD_DIR}"/3*-service*.yaml; do
  [[ -e "${f}" ]] && kc apply -f "${f}"
done

reconcile_pvcs

# volumeClaimTemplates は更新不可。差分があれば Pod と PVC を残したまま
# (--cascade=orphan) StatefulSet だけを作り直す。
if kc -n "${NS}" get statefulset "${NAME}" >/dev/null 2>&1; then
  live_vct="$(kc -n "${NS}" get statefulset "${NAME}" \
    -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}{" "}{.spec.volumeClaimTemplates[0].spec.storageClassName}' 2>/dev/null || true)"
  want_vct="${CFG_POSTGRES_STORAGE_SIZE} ${CFG_POSTGRES_STORAGE_CLASS}"
  if [[ "${live_vct}" != "${want_vct}" ]]; then
    step "volumeClaimTemplates が変更されました (${live_vct} -> ${want_vct})"
    step "Pod と PVC を保持したまま StatefulSet を再作成します"
    kc -n "${NS}" delete statefulset "${NAME}" --cascade=orphan
  fi
fi

kc apply -f "${BUILD_DIR}/40-statefulset.yaml"
[[ -e "${BUILD_DIR}/50-pdb.yaml" ]] && kc apply -f "${BUILD_DIR}/50-pdb.yaml"

# ---------------------------------------------------------------------------
# 起動待ち
# ---------------------------------------------------------------------------
info "Pod が Ready になるまで待機します (最大 ${WAIT_TIMEOUT})"
if ! kc -n "${NS}" rollout status "statefulset/${NAME}" --timeout="${WAIT_TIMEOUT}"; then
  warn "タイムアウトしました。状況を確認します:"
  kc -n "${NS}" get pods -l "app=${NAME}" -o wide || true
  kc -n "${NS}" get pvc -l "app=${NAME}" || true
  echo
  warn "詳しいログ: kubectl --context ${CFG_KUBE_CONTEXT} -n ${NS} logs ${NAME}-0"
  die "StatefulSet が Ready になりませんでした。"
fi

"${REPO_ROOT}/scripts/status.sh" --summary
