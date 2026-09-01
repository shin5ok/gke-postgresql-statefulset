#!/usr/bin/env bash
# pg_dump 形式のファイル (既定: sql/dump.sql) をプライマリに流し込む。
# パスワードは Pod 内の環境変数を参照するので、手元や Pod の ps に露出しない。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd kubectl python3

readonly NS="${CFG_POSTGRES_NAMESPACE}"
readonly NAME="${CFG_POSTGRES_NAME}"
readonly PRIMARY="${NAME}-0"

dump_file="${CFG_CONTENT_DUMP_FILE}"
[[ "${dump_file}" != /* ]] && dump_file="${REPO_ROOT}/${dump_file}"

kube_context_exists \
  || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make db' を実行してください。"

if [[ ! -f "${dump_file}" ]]; then
  warn "${dump_file} がありません。ダミーデータを生成します。"
  python3 "${REPO_ROOT}/scripts/gen-dump.py" "${dump_file}" \
    --customers "${CFG_CONTENT_ROWS_CUSTOMERS}" \
    --products "${CFG_CONTENT_ROWS_PRODUCTS}" \
    --orders "${CFG_CONTENT_ROWS_ORDERS}" \
    --seed "${CFG_CONTENT_SEED}" \
    || die "ダミーデータの生成に失敗しました"
fi

info "プライマリ ${PRIMARY} が Ready になるまで待ちます"
kc -n "${NS}" wait --for=condition=Ready "pod/${PRIMARY}" --timeout="${WAIT_TIMEOUT:-600s}" \
  || die "${PRIMARY} が Ready になりません。'make status' で確認してください。"

size="$(du -h "${dump_file}" | cut -f1)"
info "${dump_file#"${REPO_ROOT}/"} (${size}) を ${CFG_POSTGRES_DATABASE} に投入します"

# -o /dev/null: 実行結果の表 (setval など) を捨てる。エラーは stderr に出る。
# ON_ERROR_STOP=1: 途中でエラーが出たら中断して非ゼロ終了する。
if ! kc -n "${NS}" exec -i "${PRIMARY}" -c postgresql -- bash -c '
    PGPASSWORD="${APP_PASSWORD}" exec psql \
      --quiet \
      --set ON_ERROR_STOP=1 \
      --output /dev/null \
      --username "${APP_USER}" \
      --dbname "${POSTGRES_DB}" \
      --host 127.0.0.1 \
      --file -' < "${dump_file}"; then
  die "投入に失敗しました。上のエラーを確認してください。"
fi

ok "投入が完了しました"

info "投入結果"
kc -n "${NS}" exec -i "${PRIMARY}" -c postgresql -- bash -c '
  PGPASSWORD="${APP_PASSWORD}" exec psql \
    --username "${APP_USER}" --dbname "${POSTGRES_DB}" --host 127.0.0.1' <<'SQL'
-- pg_stat_user_tables.n_live_tup は投入直後は不正確なので、
-- query_to_xml で各テーブルの実際の件数を数える。
SELECT relname AS "テーブル",
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, relname),
                           false, true, '')))[1]::text::bigint AS "行数"
  FROM pg_stat_user_tables
 ORDER BY relname;
SQL

cat <<NEXT

  ${C_DIM}# 中身を見る${C_RESET}
  make psql

NEXT
