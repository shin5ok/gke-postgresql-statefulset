#!/usr/bin/env bash
# initContainer として全 Pod で実行される。
# ordinal 0 (プライマリ) では何もせず、1 以降のスタンバイでデータ未初期化のときだけ
# プライマリから pg_basebackup でベースバックアップを取得する。
set -euo pipefail

ordinal="${HOSTNAME##*-}"

if [[ "${ordinal}" == "0" ]]; then
  echo "[bootstrap] ${HOSTNAME} はプライマリです。何もしません。"
  exit 0
fi

if [[ -s "${PGDATA}/PG_VERSION" ]]; then
  echo "[bootstrap] ${PGDATA} は初期化済みです。ベースバックアップをスキップします。"
  exit 0
fi

echo "[bootstrap] プライマリ ${PRIMARY_HOST}:5432 の起動を待機します..."
deadline=$(( SECONDS + 600 ))
until pg_isready --quiet --host "${PRIMARY_HOST}" --port 5432 --username postgres; do
  if (( SECONDS >= deadline )); then
    echo "[bootstrap] プライマリが 600 秒以内に応答しませんでした" >&2
    exit 1
  fi
  sleep 3
done

echo "[bootstrap] ${PRIMARY_HOST} からベースバックアップを取得します..."
rm -rf "${PGDATA:?}"
mkdir -p "${PGDATA}"
chmod 0700 "${PGDATA}"

# -R: standby.signal と primary_conninfo を書き出す (スタンバイとして起動する)
# -X stream: バックアップ中の WAL を並行して受信する
PGPASSWORD="${REPLICATION_PASSWORD}" pg_basebackup \
  --host "${PRIMARY_HOST}" \
  --port 5432 \
  --username "${REPLICATION_USER}" \
  --pgdata "${PGDATA}" \
  --format=plain \
  --wal-method=stream \
  --checkpoint=fast \
  --write-recovery-conf \
  --progress \
  --verbose

echo "[bootstrap] ベースバックアップが完了しました。スタンバイとして起動します。"
