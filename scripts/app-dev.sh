#!/usr/bin/env bash
# サンプルアプリを手元で起動する (開発用)。接続先は config.toml の [app] target:
#   postgresql … 別ターミナルで 'make port-forward' しておき、localhost:15432 に接続する
#   alloydb    … PSC エンドポイントの内部 IP に直接接続する (VPC 内からのみ到達可能。
#                Cloud VPN / IAP トンネルなどが無い手元の PC からは繋がらない)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd python3 kubectl gcloud
source "$(dirname "${BASH_SOURCE[0]}")/app-lib.sh"

readonly APP_DIR="${REPO_ROOT}/app"
readonly VENV="${APP_DIR}/.venv"

if [[ ! -x "${VENV}/bin/python" ]]; then
  info "仮想環境を作成します: ${VENV#"${REPO_ROOT}/"}"
  python3 -m venv "${VENV}" || die "python3 -m venv に失敗しました (python3-venv パッケージが必要です)"
fi
if ! "${VENV}/bin/python" -c 'import flask, psycopg' >/dev/null 2>&1; then
  info "依存パッケージをインストールします"
  "${VENV}/bin/pip" install --quiet --disable-pip-version-check -r "${APP_DIR}/requirements.txt" \
    || die "pip install に失敗しました"
fi

kube_context_exists || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make db' を実行してください。"
resolve_app_db local

cat <<INFO

  接続先: ${CFG_APP_TARGET}  ${APP_DB_USER}@${APP_DB_HOST}:${APP_DB_PORT}/${APP_DB_NAME} (sslmode=${APP_DB_SSLMODE})
$(if [[ "${CFG_APP_TARGET}" == "postgresql" ]]; then cat <<PF
  ${C_DIM}別ターミナルで 'make port-forward' を実行しておいてください (localhost:${APP_DB_PORT} -> postgres-rw)${C_RESET}
PF
else cat <<PSC
  ${C_YELLOW}PSC エンドポイント (${APP_DB_HOST}) は VPC 内からのみ到達できます。手元から届かない場合は 'make app' で GKE 上に起動してください。${C_RESET}
PSC
fi)
  http://localhost:${PORT:-8080}/   ${C_DIM}Ctrl-C で終了${C_RESET}

INFO

cd "${APP_DIR}"
DB_TARGET="${APP_DB_TARGET}" DB_HOST="${APP_DB_HOST}" DB_PORT="${APP_DB_PORT}" \
DB_NAME="${APP_DB_NAME}" DB_USER="${APP_DB_USER}" DB_PASSWORD="${APP_DB_PASSWORD}" \
DB_SSLMODE="${APP_DB_SSLMODE}" PORT="${PORT:-8080}" FLASK_DEBUG="${FLASK_DEBUG:-1}" \
exec "${VENV}/bin/python" main.py
