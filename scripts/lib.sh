#!/usr/bin/env bash
# 各スクリプトから source される共通処理。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
SECRETS_DIR="${REPO_ROOT}/.secrets"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info()  { printf '%s==>%s %s\n'      "${C_BLUE}${C_BOLD}" "${C_RESET}" "$*"; }
step()  { printf '%s  ->%s %s\n'     "${C_DIM}"           "${C_RESET}" "$*"; }
ok()    { printf '%s  OK%s %s\n'     "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*"; }
warn()  { printf '%s警告:%s %s\n'    "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2; }
die()   { printf '%sエラー:%s %s\n'  "${C_RED}${C_BOLD}"  "${C_RESET}" "$*" >&2; exit 1; }

require_cmd() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    die "次のコマンドが見つかりません: ${missing[*]}
       gcloud / kubectl は Google Cloud SDK に含まれます:
       https://cloud.google.com/sdk/docs/install
       kubectl: gcloud components install kubectl"
  fi
}

# config.toml (+ テンプレートの既定値 + 環境変数) を CFG_* 変数として読み込む。
load_config() {
  require_cmd python3
  local resolved
  resolved="$(python3 "${REPO_ROOT}/scripts/config.py" sh)" \
    || die "設定の読み込みに失敗しました"
  # set -a: マニフェストのレンダリングで使うため CFG_* をすべて export する
  set -a
  eval "${resolved}"
  set +a
}

# 常に対象クラスタの context を明示して kubectl を実行する（別クラスタへの誤操作防止）。
kc() {
  kubectl --context "${CFG_KUBE_CONTEXT}" "$@"
}

# context が kubeconfig に登録されているか。
# `kubectl ... | grep -q` にすると、grep が一致した時点で終了して kubectl が SIGPIPE で
# 落ち、pipefail のせいで「無い」と誤判定することがあるため、出力を受けてから照合する。
kube_context_exists() {
  local contexts
  contexts="$(kubectl config get-contexts -o name 2>/dev/null || true)"
  grep -qx "${CFG_KUBE_CONTEXT}" <<<"${contexts}"
}

# StatefulSet がこのクラスタにデプロイ済みか確認し、無ければ案内して終了する。
# (make alloydb / make app は GKE クラスタは用意するが StatefulSet はデプロイしないため、
#  その後に make db-content などを実行すると Namespace ごと存在しないことがある)
require_db_deployed() {
  kube_context_exists \
    || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make db' を実行してください。"
  kc -n "${CFG_POSTGRES_NAMESPACE}" get statefulset "${CFG_POSTGRES_NAME}" >/dev/null 2>&1 \
    || die "StatefulSet ${CFG_POSTGRES_NAMESPACE}/${CFG_POSTGRES_NAME} がクラスタ ${CFG_CLUSTER_NAME} にありません。
       先に 'make db' で PostgreSQL をデプロイしてください。"
}

# 文字列を base64 (改行なし) にする。引数ではなく環境変数で渡して
# ローカルの ps に平文が出ないようにする。
b64() {
  B64_INPUT="$1" python3 -c 'import base64, os, sys
sys.stdout.write(base64.b64encode(os.environ["B64_INPUT"].encode()).decode())'
}

# 値がなければ生成し、.secrets/<name> に保存して標準出力に返す（冪等）。
persisted_secret() {
  local name="$1" preset="${2:-}"
  local file="${SECRETS_DIR}/${name}"
  if [[ -n "${preset}" ]]; then
    printf '%s' "${preset}"
    return
  fi
  if [[ ! -s "${file}" ]]; then
    mkdir -p "${SECRETS_DIR}"
    # 記号なしの英数字 24 文字（接続 URL や psql 引数で扱いやすくするため）。
    # tr + head のパイプは SIGPIPE で pipefail に引っかかるため python3 で生成する。
    python3 -c 'import secrets, string, sys
alphabet = string.ascii_letters + string.digits
sys.stdout.write("".join(secrets.choice(alphabet) for _ in range(24)))' > "${file}"
    chmod 600 "${file}"
  fi
  cat "${file}"
}

# ---------------------------------------------------------------------------
# AlloyDB
# ---------------------------------------------------------------------------

# PSC エンドポイント (予約した内部 IP) のアドレス。無ければ空。
alloydb_psc_ip() {
  gcloud compute addresses describe "${CFG_ALLOYDB_PSC_ENDPOINT}" \
    --project "${CFG_GCP_PROJECT}" --region "${CFG_ALLOYDB_REGION}" \
    --format='value(address)' 2>/dev/null || true
}

# アプリ用ユーザのパスワード (config.toml の値 > .secrets/ の保存値)。無ければ空。
alloydb_app_password() {
  if [[ -n "${CFG_ALLOYDB_PASSWORD}" ]]; then
    printf '%s' "${CFG_ALLOYDB_PASSWORD}"
  elif [[ -s "${SECRETS_DIR}/alloydb_app_password" ]]; then
    cat "${SECRETS_DIR}/alloydb_app_password"
  fi
}

# postgres ユーザのパスワード (クラスタ作成時に自動生成して保存したもの)。無ければ空。
alloydb_superuser_password() {
  if [[ -s "${SECRETS_DIR}/alloydb_superuser_password" ]]; then
    cat "${SECRETS_DIR}/alloydb_superuser_password"
  fi
}
