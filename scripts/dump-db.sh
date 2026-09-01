#!/usr/bin/env bash
# 稼働中の DB から pg_dump を取得して config.toml の content.dump_file に保存する。
# make db-content で流し込めるのと同じ形式 (plain text) で出力する。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd kubectl

readonly NS="${CFG_POSTGRES_NAMESPACE}"
readonly PRIMARY="${CFG_POSTGRES_NAME}-0"

out="${1:-${CFG_CONTENT_DUMP_FILE}}"
[[ "${out}" != /* ]] && out="${REPO_ROOT}/${out}"

kube_context_exists \
  || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make db' を実行してください。"

info "${PRIMARY} から pg_dump を取得します -> ${out#"${REPO_ROOT}/"}"

# --no-owner / --no-privileges: 別のロール名でもそのまま復元できるようにする
tmp="${out}.tmp.$$"
if ! kc -n "${NS}" exec -i "${PRIMARY}" -c postgresql -- bash -c '
      PGPASSWORD="${APP_PASSWORD}" exec pg_dump \
        --clean --if-exists --no-owner --no-privileges \
        --username "${APP_USER}" --dbname "${POSTGRES_DB}" --host 127.0.0.1' > "${tmp}"; then
  rm -f "${tmp}"
  die "pg_dump に失敗しました"
fi

if [[ ! -s "${tmp}" ]]; then
  rm -f "${tmp}"
  die "pg_dump の出力が空でした"
fi

mv "${tmp}" "${out}"
ok "$(du -h "${out}" | cut -f1) を保存しました: ${out#"${REPO_ROOT}/"}"
