#!/usr/bin/env bash
# サンプルアプリの接続先を解決する共通処理 (lib.sh と load_config の後に source する)。
# ここで設定する APP_* は source 元のスクリプトが使う。
# shellcheck disable=SC2034
#
#   resolve_app_image           APP_IMAGE (Artifact Registry 上のイメージ名:タグ) を決める
#   resolve_app_db <mode>       APP_DB_* を config.toml の [app] target から決める
#                               mode: cluster … GKE 上の Pod から接続する値
#                                     local   … 手元から接続する値 (StatefulSet は port-forward 経由)
#                                     render  … クラスタに触れないダミー値 (make validate 用)

resolve_app_image() {
  local tag="${CFG_APP_IMAGE_TAG}"
  if [[ -z "${tag}" ]]; then
    tag="$(python3 "${REPO_ROOT}/scripts/app-tag.py")" || die "イメージタグを決められません"
  fi
  APP_IMAGE="${CFG_APP_IMAGE_REPO}:${tag}"
}

resolve_app_db() {
  local mode="$1"
  APP_DB_TARGET="${CFG_APP_TARGET}"
  APP_DB_PORT="5432"

  case "${CFG_APP_TARGET}" in
    postgresql)
      APP_DB_HOST="${CFG_APP_DB_HOST_POSTGRESQL}"
      APP_DB_NAME="${CFG_POSTGRES_DATABASE}"
      APP_DB_USER="${CFG_POSTGRES_USER}"
      APP_DB_SSLMODE="prefer"       # 公式イメージの postgres は既定で SSL 無効
      case "${mode}" in
        render)
          APP_DB_PASSWORD="render-only"
          ;;
        cluster|local)
          if [[ "${mode}" == "local" ]]; then
            APP_DB_HOST="127.0.0.1"
            APP_DB_PORT="${LOCAL_PORT:-15432}"
          fi
          # クラスタ上の Secret が正 (deploy-db.sh が解決した値)。無ければ .secrets/ を使う。
          APP_DB_PASSWORD="$(kc -n "${CFG_POSTGRES_NAMESPACE}" get secret "${CFG_POSTGRES_NAME}" \
            -o 'jsonpath={.data.APP_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
          if [[ -z "${APP_DB_PASSWORD}" && -n "${CFG_POSTGRES_PASSWORD}" ]]; then
            APP_DB_PASSWORD="${CFG_POSTGRES_PASSWORD}"
          fi
          if [[ -z "${APP_DB_PASSWORD}" && -s "${SECRETS_DIR}/app_password" ]]; then
            APP_DB_PASSWORD="$(cat "${SECRETS_DIR}/app_password")"
          fi
          [[ -n "${APP_DB_PASSWORD}" ]] \
            || die "PostgreSQL の Secret ${CFG_POSTGRES_NAMESPACE}/${CFG_POSTGRES_NAME} がありません。
       先に 'make db' で StatefulSet を構築してください。"
          ;;
      esac
      ;;
    alloydb)
      # connection_pooling = true なら 6432 (プーラー)、そうでなければ 5432 (直結)
      APP_DB_PORT="${CFG_ALLOYDB_PORT}"
      APP_DB_NAME="${CFG_ALLOYDB_DATABASE}"
      APP_DB_USER="${CFG_ALLOYDB_USER}"
      APP_DB_SSLMODE="require"      # AlloyDB は既定で SSL 必須 (ENCRYPTED_ONLY)
      case "${mode}" in
        render)
          APP_DB_HOST="10.0.0.2"
          APP_DB_PASSWORD="render-only"
          ;;
        cluster|local)
          APP_DB_HOST="$(alloydb_psc_ip)"
          [[ -n "${APP_DB_HOST}" ]] \
            || die "AlloyDB の PSC エンドポイント ${CFG_ALLOYDB_PSC_ENDPOINT} がありません。
       先に 'make alloydb' を実行してください。"
          APP_DB_PASSWORD="$(alloydb_app_password)"
          [[ -n "${APP_DB_PASSWORD}" ]] \
            || die "AlloyDB のアプリ用パスワードがありません (.secrets/alloydb_app_password)。
       先に 'make alloydb' を実行してください。"
          ;;
      esac
      ;;
    *)
      die "app.target は postgresql か alloydb です (指定値: ${CFG_APP_TARGET})"
      ;;
  esac
}
