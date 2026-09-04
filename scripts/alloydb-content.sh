#!/usr/bin/env bash
# pg_dump 形式のファイル (既定: sql/dump.sql) を AlloyDB に流し込む。
# make db-content の AlloyDB 版。GKE 上の一時 Pod の psql を経由する。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud kubectl python3
source "$(dirname "${BASH_SOURCE[0]}")/alloydb-lib.sh"

dump_file="${CFG_CONTENT_DUMP_FILE}"
[[ "${dump_file}" != /* ]] && dump_file="${REPO_ROOT}/${dump_file}"

if [[ ! -f "${dump_file}" ]]; then
  warn "${dump_file} がありません。ダミーデータを生成します。"
  python3 "${REPO_ROOT}/scripts/gen-dump.py" "${dump_file}" \
    --customers "${CFG_CONTENT_ROWS_CUSTOMERS}" \
    --products "${CFG_CONTENT_ROWS_PRODUCTS}" \
    --orders "${CFG_CONTENT_ROWS_ORDERS}" \
    --seed "${CFG_CONTENT_SEED}" \
    || die "ダミーデータの生成に失敗しました"
fi

alloydb_pod_start app
alloydb_pod_wait_ready

size="$(du -h "${dump_file}" | cut -f1)"
info "${dump_file#"${REPO_ROOT}/"} (${size}) を AlloyDB の ${CFG_ALLOYDB_DATABASE} に投入します"

# -o /dev/null: 実行結果の表 (setval など) を捨てる。エラーは stderr に出る。
# ON_ERROR_STOP=1: 途中でエラーが出たら中断して非ゼロ終了する。
if ! alloydb_pod_psql --quiet --set ON_ERROR_STOP=1 --output /dev/null --file - < "${dump_file}"; then
  die "投入に失敗しました。上のエラーを確認してください。"
fi
ok "投入が完了しました"

info "投入結果"
alloydb_pod_psql <<'SQL'
-- pg_stat_user_tables.n_live_tup は投入直後は不正確なので、
-- query_to_xml で各テーブルの実際の件数を数える。
-- AlloyDB 組み込みのテーブル (google_ml スキーマなど) が混ざらないよう public に限る。
SELECT relname AS "テーブル",
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, relname),
                           false, true, '')))[1]::text::bigint AS "行数"
  FROM pg_stat_user_tables
 WHERE schemaname = 'public'
 ORDER BY relname;
SQL

cat <<NEXT

  ${C_DIM}# 中身を見る${C_RESET}
  make alloydb-psql

NEXT
