#!/usr/bin/env bash
# config.toml の [app] target に従って接続先を解決し、サンプルアプリを GKE に
# デプロイして Ready になるまで待つ。何度実行しても安全 (冪等)。
#   RENDER_ONLY=1 … クラスタに触れずに build/app/ にマニフェストを生成するだけ
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud kubectl python3
source "$(dirname "${BASH_SOURCE[0]}")/app-lib.sh"

readonly NS="${CFG_APP_NAMESPACE}"
readonly NAME="${CFG_APP_NAME}"
readonly RENDER_ONLY="${RENDER_ONLY:-0}"
readonly APP_BUILD_DIR="${BUILD_DIR}/app"
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"

if [[ "${RENDER_ONLY}" != "1" ]]; then
  kube_context_exists \
    || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make cluster' を実行してください。"
fi

# ---------------------------------------------------------------------------
# 接続先とイメージの解決
# ---------------------------------------------------------------------------
info "接続先を解決します ([app] target = ${CFG_APP_TARGET})"
if [[ "${RENDER_ONLY}" == "1" ]]; then
  resolve_app_db render
else
  resolve_app_db cluster
fi
resolve_app_image
step "DB: ${APP_DB_USER}@${APP_DB_HOST}:${APP_DB_PORT}/${APP_DB_NAME} (sslmode=${APP_DB_SSLMODE})"
step "イメージ: ${APP_IMAGE}"

if [[ "${RENDER_ONLY}" != "1" && "${SKIP_IMAGE_CHECK:-0}" != "1" ]] \
   && ! gcloud artifacts docker images describe "${APP_IMAGE}" \
          --project "${CFG_GCP_PROJECT}" >/dev/null 2>&1; then
  die "イメージ ${APP_IMAGE} が Artifact Registry にありません。'make app-image' でビルドしてください。"
fi

export CFG_APP_TARGET CFG_APP_IMAGE="${APP_IMAGE}"
export CFG_APP_DB_HOST="${APP_DB_HOST}" CFG_APP_DB_PORT="${APP_DB_PORT}" \
       CFG_APP_DB_NAME="${APP_DB_NAME}" CFG_APP_DB_USER="${APP_DB_USER}" \
       CFG_APP_DB_SSLMODE="${APP_DB_SSLMODE}"
CFG_APP_DB_PASSWORD_B64="$(b64 "${APP_DB_PASSWORD}")"
export CFG_APP_DB_PASSWORD_B64
# 接続先が変わったら Pod を作り直すためのチェックサム (Deployment のアノテーションに入る)
CFG_APP_CONFIG_CHECKSUM="$(printf '%s' \
  "${APP_DB_TARGET}|${APP_DB_HOST}|${APP_DB_PORT}|${APP_DB_NAME}|${APP_DB_USER}|${APP_DB_SSLMODE}|${APP_DB_PASSWORD}" \
  | sha256sum | cut -c1-16)"
export CFG_APP_CONFIG_CHECKSUM

# ---------------------------------------------------------------------------
# マニフェストのレンダリング
# ---------------------------------------------------------------------------
info "マニフェストを ${APP_BUILD_DIR#"${REPO_ROOT}/"}/ にレンダリングします"
rm -rf "${APP_BUILD_DIR}"
mkdir -p "${APP_BUILD_DIR}"

render() {
  local tmpl="${REPO_ROOT}/manifests/app/$1.yaml.tmpl"
  python3 "${REPO_ROOT}/scripts/render.py" "${tmpl}" > "${APP_BUILD_DIR}/$1.yaml" \
    || die "app/$1.yaml.tmpl のレンダリングに失敗しました"
  step "app/$1.yaml"
}
render 00-namespace
render 10-secret
render 20-configmap
render 30-deployment
render 40-service

if [[ "${RENDER_ONLY}" == "1" ]]; then
  ok "レンダリングのみ実行しました: ${APP_BUILD_DIR}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 適用と起動待ち
# ---------------------------------------------------------------------------
info "クラスタに適用します (context: ${CFG_KUBE_CONTEXT})"
for f in 00-namespace 10-secret 20-configmap 30-deployment 40-service; do
  kc apply -f "${APP_BUILD_DIR}/${f}.yaml"
done

info "Pod が Ready になるまで待機します (最大 ${WAIT_TIMEOUT})"
if ! kc -n "${NS}" rollout status "deployment/${NAME}" --timeout="${WAIT_TIMEOUT}"; then
  warn "タイムアウトしました。状況を確認します:"
  kc -n "${NS}" get pods -l "app=${NAME}" -o wide || true
  echo
  warn "詳しいログ: kubectl --context ${CFG_KUBE_CONTEXT} -n ${NS} logs deployment/${NAME}"
  die "Deployment が Ready になりませんでした。"
fi

"${REPO_ROOT}/scripts/app-status.sh" --summary
