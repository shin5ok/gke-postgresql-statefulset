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

render 00-namespace
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

  local pvc current desired="${CFG_POSTGRES_STORAGE_SIZE}"
  while read -r pvc; do
    [[ -z "${pvc}" ]] && continue
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
# 適用
# ---------------------------------------------------------------------------
info "クラスタに適用します (context: ${CFG_KUBE_CONTEXT})"
kc apply -f "${BUILD_DIR}/00-namespace.yaml"
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
