#!/usr/bin/env bash
# 初回 initdb 時にのみ実行される (/docker-entrypoint-initdb.d)。
#   - アプリケーション用のロールを作成し、データベースの所有者にする
#     (POSTGRES_USER = postgres はスーパーユーザなので、アプリには使わせない)
#   - replicas >= 2 のためのレプリケーションロールと pg_hba のエントリを追加する
set -euo pipefail

# SQL の文字列リテラルに埋め込むため、シングルクォートを二重化する。
# (standard_conforming_strings = on なのでバックスラッシュはそのままでよい)
app_pw="${APP_PASSWORD//\'/\'\'}"
repl_pw="${REPLICATION_PASSWORD//\'/\'\'}"

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<SQL
  CREATE ROLE "${APP_USER}" WITH LOGIN PASSWORD '${app_pw}';
  ALTER DATABASE "${POSTGRES_DB}" OWNER TO "${APP_USER}";
  ALTER SCHEMA public OWNER TO "${APP_USER}";
  GRANT ALL PRIVILEGES ON DATABASE "${POSTGRES_DB}" TO "${APP_USER}";
SQL
echo "アプリケーションユーザ ${APP_USER} を作成しました (所有 DB: ${POSTGRES_DB})"

if [[ -n "${REPLICATION_PASSWORD:-}" ]]; then
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<SQL
    CREATE ROLE "${REPLICATION_USER}" WITH REPLICATION LOGIN PASSWORD '${repl_pw}';
SQL
  # initdb 直後の pg_hba.conf にはレプリケーション接続を許可する行がないため追加する。
  # このスクリプトの完了後にエントリポイントが本番用サーバを起動するので反映される。
  echo "host replication ${REPLICATION_USER} all scram-sha-256" >> "${PGDATA}/pg_hba.conf"
  echo "レプリケーションロール ${REPLICATION_USER} を作成しました"
fi
