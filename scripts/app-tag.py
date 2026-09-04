#!/usr/bin/env python3
"""app/ の内容からコンテナイメージのタグを決める (内容の sha256 の先頭 12 桁)。

内容が同じなら同じタグになるので、build-app.sh は既に push 済みのイメージの
ビルドを省略でき、deploy-app.sh はビルド結果を保存しなくても同じタグを再計算できる。
"""
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "app"
SKIP_DIRS = {".venv", "__pycache__", ".git", ".pytest_cache", ".mypy_cache"}


def main() -> None:
    if not APP_DIR.is_dir():
        print(f"app-tag error: {APP_DIR} がありません", file=sys.stderr)
        sys.exit(1)
    digest = hashlib.sha256()
    for path in sorted(APP_DIR.rglob("*")):
        rel = path.relative_to(APP_DIR)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        if not path.is_file() or path.suffix == ".pyc":
            continue
        digest.update(rel.as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    print(digest.hexdigest()[:12])


if __name__ == "__main__":
    main()
