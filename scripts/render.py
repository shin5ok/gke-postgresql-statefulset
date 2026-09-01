#!/usr/bin/env python3
"""manifests/*.yaml.tmpl の ${VAR} を環境変数で置換して標準出力に書き出す。

未定義の変数が残っている場合はエラーにする（空文字で壊れたマニフェストを
apply してしまう事故を防ぐため）。
"""
import os
import sys
from pathlib import Path
from string import Template


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: render.py <template>", file=sys.stderr)
        sys.exit(2)

    path = Path(sys.argv[1])
    try:
        body = path.read_text()
    except OSError as exc:
        print(f"render error: {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        sys.stdout.write(Template(body).substitute(os.environ))
    except KeyError as exc:
        print(f"render error: {path.name}: 変数 {exc} が未定義です", file=sys.stderr)
        sys.exit(1)
    except ValueError as exc:
        print(f"render error: {path.name}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
