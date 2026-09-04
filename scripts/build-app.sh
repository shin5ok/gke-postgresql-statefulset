#!/usr/bin/env bash
# app/ のコンテナイメージをビルドして Artifact Registry に push する。
#   - タグは app/ の内容のハッシュ (config.toml の app.image_tag が空の場合)。
#     同じタグのイメージが既にあればビルドしない。FORCE_BUILD=1 で強制的にビルドする。
#   - app.builder = "cloudbuild" なら Cloud Build、"docker" なら手元の docker を使う。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud python3
source "$(dirname "${BASH_SOURCE[0]}")/app-lib.sh"

readonly PROJECT="${CFG_GCP_PROJECT}"
readonly REGION="${CFG_GCP_REGION}"
readonly REPO="${CFG_APP_REGISTRY}"

resolve_app_image
info "イメージ: ${APP_IMAGE}"

# ---- API とリポジトリ ----
required=(artifactregistry.googleapis.com)
[[ "${CFG_APP_BUILDER}" == "cloudbuild" ]] && required+=(cloudbuild.googleapis.com)
enabled="$(gcloud services list --enabled --project "${PROJECT}" \
  --format='value(config.name)' 2>/dev/null || true)"
missing=()
for api in "${required[@]}"; do
  grep -qx "${api}" <<<"${enabled}" || missing+=("${api}")
done
if (( ${#missing[@]} > 0 )); then
  step "API を有効化します: ${missing[*]}"
  gcloud services enable "${missing[@]}" --project "${PROJECT}" \
    || die "API の有効化に失敗しました。"
fi

if ! gcloud artifacts repositories describe "${REPO}" --location "${REGION}" \
       --project "${PROJECT}" >/dev/null 2>&1; then
  step "Artifact Registry リポジトリ ${REPO} (${REGION}) を作成します"
  gcloud artifacts repositories create "${REPO}" --repository-format docker \
    --location "${REGION}" --project "${PROJECT}" \
    --description "gke-postgresql-statefulset sample app" \
    || die "リポジトリの作成に失敗しました。"
fi

# ---- 既にあればスキップ ----
if [[ "${FORCE_BUILD:-0}" != "1" && -z "${CFG_APP_IMAGE_TAG}" ]] \
   && gcloud artifacts docker images describe "${APP_IMAGE}" --project "${PROJECT}" >/dev/null 2>&1; then
  ok "同じ内容のイメージが既にあるためビルドをスキップします (FORCE_BUILD=1 で再ビルド)"
  exit 0
fi

# ---- ビルド ----
case "${CFG_APP_BUILDER}" in
  cloudbuild)
    info "Cloud Build でビルドします (app/ をアップロード)"
    gcloud builds submit "${REPO_ROOT}/app" --tag "${APP_IMAGE}" --project "${PROJECT}" \
      || die "Cloud Build に失敗しました。
       権限エラーの場合は Cloud Build のサービスアカウントに roles/artifactregistry.writer と
       roles/logging.logWriter を付与するか、config.toml で [app] builder = \"docker\" にしてください。"
    ;;
  docker)
    require_cmd docker
    step "docker の認証を設定します (${REGION}-docker.pkg.dev)"
    gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet \
      || die "docker の認証設定に失敗しました。"
    info "docker でビルドします (linux/amd64)"
    docker build --platform linux/amd64 -t "${APP_IMAGE}" "${REPO_ROOT}/app" \
      || die "docker build に失敗しました。"
    docker push "${APP_IMAGE}" || die "docker push に失敗しました。"
    ;;
  *)
    die "app.builder は cloudbuild か docker です (指定値: ${CFG_APP_BUILDER})"
    ;;
esac

ok "push しました: ${APP_IMAGE}"
