#!/usr/bin/env python3
"""AlloyDB / PostgreSQL (StatefulSet) のどちらにも同じコードで接続できることを示す、
最小のサンプル Web アプリ (レコードの一覧と作成)。

接続先は環境変数だけで決まります。`make app` が config.toml の [app] target から
これらを生成して Kubernetes の ConfigMap / Secret に入れ、Pod に渡します。

    DB_TARGET    "alloydb" | "postgresql"  (画面上部の表示にだけ使う)
    DB_HOST      ホスト名または IP (AlloyDB なら PSC エンドポイントの内部 IP)
    DB_PORT      既定 5432
    DB_NAME      データベース名
    DB_USER      ユーザ名
    DB_PASSWORD  パスワード
    DB_SSLMODE   AlloyDB は "require" (SSL 必須)、StatefulSet は "prefer"
"""
from __future__ import annotations

import os
import socket
import threading

import psycopg
from flask import Flask, redirect, render_template, request, url_for
from psycopg.rows import dict_row

# 画面上部のバナーに使う表示名と色
TARGETS = {
    "alloydb": {"label": "AlloyDB", "detail": "Private Service Connect 経由", "color": "#188038"},
    "postgresql": {"label": "PostgreSQL", "detail": "GKE StatefulSet", "color": "#336791"},
}

TARGET = os.environ.get("DB_TARGET", "postgresql").strip().lower()
if TARGET not in TARGETS:
    raise SystemExit(f"DB_TARGET は alloydb か postgresql です (指定値: {TARGET!r})")

DB = {
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("DB_PORT", "5432")),
    "dbname": os.environ.get("DB_NAME", "appdb"),
    "user": os.environ.get("DB_USER", "app"),
    "sslmode": os.environ.get("DB_SSLMODE", "prefer"),
}
# AlloyDB のマネージド接続プーリングはプーラーが 6432 で待ち受ける (直結は 5432)。
# 6432 で接続できているなら、その経路には必ずプーラーが挟まっている
# (直結のサーバは 5432 でしか待ち受けないため)。
POOLER_PORT = 6432
POOLED = DB["port"] == POOLER_PORT

CONNINFO = psycopg.conninfo.make_conninfo(
    **DB,
    password=os.environ.get("DB_PASSWORD", ""),
    connect_timeout=5,
    application_name="sample-app",
)

# サンプル用のテーブル。初回アクセス時に無ければ作る (dump.sql には依存しない)。
SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS notes (
    id         bigserial PRIMARY KEY,
    title      text        NOT NULL,
    body       text        NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
)
"""

app = Flask(__name__)
_schema_lock = threading.Lock()
_schema_ready = False


def connect() -> psycopg.Connection:
    return psycopg.connect(CONNINFO, row_factory=dict_row)


def ensure_schema(conn: psycopg.Connection) -> None:
    global _schema_ready
    if _schema_ready:
        return
    with _schema_lock:
        if not _schema_ready:
            conn.execute(SCHEMA_SQL)
            conn.commit()
            _schema_ready = True


def server_info(conn: psycopg.Connection) -> dict:
    """接続先サーバの情報。alloydb.* パラメータの有無で AlloyDB かどうかも判定する。"""
    version = conn.execute("SELECT version()").fetchone()["version"]
    alloydb_params = conn.execute(
        "SELECT count(*) AS n FROM pg_settings WHERE name LIKE 'alloydb.%'"
    ).fetchone()["n"]
    return {
        "version": version.split(" on ")[0],   # "PostgreSQL 17.x" の部分だけ
        "version_full": version,
        "alloydb_detected": alloydb_params > 0,
        "server_addr": conn.execute("SELECT inet_server_addr()::text AS a").fetchone()["a"],
        # プーラー経由 (transaction モード) だとリクエストごとに別のサーバ接続が
        # 割り当てられ得るので、画面を再読み込みするとこの値が変わることがある。
        "backend_pid": conn.execute("SELECT pg_backend_pid() AS p").fetchone()["p"],
        "ssl": conn.execute(
            "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
        ).fetchone()["ssl"],
    }


def render_index(error: str | None = None, status: int = 200):
    info, notes = None, []
    try:
        with connect() as conn:
            ensure_schema(conn)
            info = server_info(conn)
            notes = conn.execute(
                "SELECT id, title, body, created_at FROM notes ORDER BY id DESC LIMIT 100"
            ).fetchall()
    except psycopg.Error as exc:
        error = error or f"データベースに接続できません: {str(exc).strip()}"
    return render_template(
        "index.html",
        target=TARGET,
        targets=TARGETS,
        db=DB,
        pooled=POOLED,
        pooler_port=POOLER_PORT,
        info=info,
        notes=notes,
        error=error,
        hostname=socket.gethostname(),
    ), status


@app.get("/")
def index():
    return render_index()


@app.post("/notes")
def create_note():
    title = request.form.get("title", "").strip()
    body = request.form.get("body", "").strip()
    if not title:
        return render_index(error="タイトルを入力してください", status=400)
    try:
        with connect() as conn:
            ensure_schema(conn)
            conn.execute(
                "INSERT INTO notes (title, body) VALUES (%s, %s)",
                (title[:200], body[:2000]),
            )
    except psycopg.Error as exc:
        return render_index(error=f"登録に失敗しました: {str(exc).strip()}", status=500)
    return redirect(url_for("index"), code=303)


@app.get("/healthz")
def healthz():
    """プロセスの生存確認。DB が落ちていても画面でエラーを見せたいので DB は見ない。"""
    return "ok\n", 200, {"Content-Type": "text/plain; charset=utf-8"}


@app.get("/readyz")
def readyz():
    """DB まで到達できるかの確認 (監視や手動確認用)。"""
    try:
        with connect() as conn:
            conn.execute("SELECT 1")
    except psycopg.Error as exc:
        return {"ok": False, "target": TARGET, "error": str(exc).strip()}, 503
    return {"ok": True, "target": TARGET, "host": DB["host"],
            "port": DB["port"], "pooled": POOLED}, 200


if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        debug=os.environ.get("FLASK_DEBUG") == "1",
    )
