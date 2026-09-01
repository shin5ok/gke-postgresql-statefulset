#!/usr/bin/env python3
"""ディレクトリ内のファイルから ConfigMap のマニフェストを生成する。

kubectl create configmap --from-file 相当だが、クラスタへの接続を一切
必要としないので `make render` をオフラインで実行できる。
"""
import hashlib
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 4:
        print("usage: mk-configmap.py <name> <namespace> <dir>", file=sys.stderr)
        sys.exit(2)

    name, namespace, directory = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    files = sorted(p for p in directory.iterdir() if p.is_file())
    if not files:
        print(f"mk-configmap error: {directory} にファイルがありません", file=sys.stderr)
        sys.exit(1)

    out = [
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        f"  name: {name}",
        f"  namespace: {namespace}",
        "  labels:",
        f"    app: {name.rsplit('-scripts', 1)[0]}",
        "    app.kubernetes.io/managed-by: gke-postgresql-statefulset",
        "data:",
    ]
    digest = hashlib.sha256()
    for path in files:
        body = path.read_text()
        digest.update(path.name.encode())
        digest.update(body.encode())
        # リテラルブロックスカラー。インデント量を明示 (|2) して、
        # 先頭行が空白で始まるファイルでも正しく解釈されるようにする。
        out.append(f"  {path.name}: |2")
        for line in body.splitlines():
            out.append(f"    {line}" if line else "")
    out.append("")

    # 呼び出し側が Pod のアノテーションに使えるようチェックサムを stderr に出す
    print(digest.hexdigest()[:16], file=sys.stderr)
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
