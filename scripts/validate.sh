#!/usr/bin/env bash
# クラスタに接続せずに、設定とレンダリング結果を検証する (オフライン CI 用)。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd python3

info "設定を検証しました (config.py によるスキーマ / 型 / 値のチェック)"

# build/ の YAML がすべて解釈でき、apiVersion / kind / metadata を持つか
check_yaml() {
  if ! python3 -c "import yaml" 2>/dev/null; then
    warn "PyYAML が無いため YAML パースの検証をスキップします (pip install pyyaml)"
    return 0
  fi
  python3 - "${BUILD_DIR}" <<'PY'
import sys, pathlib, yaml
build = pathlib.Path(sys.argv[1])
files = sorted(build.rglob("*.yaml"))
if not files:
    sys.exit("build/ に YAML がありません")
total = 0
for path in files:
    docs = [d for d in yaml.safe_load_all(path.read_text()) if d]
    for doc in docs:
        for key in ("apiVersion", "kind", "metadata"):
            if key not in doc:
                sys.exit(f"{path.name}: {key} がありません")
        total += 1
    print(f"  -> {path.relative_to(build)}: {len(docs)} 個のオブジェクト "
          f"({', '.join(d['kind'] for d in docs)})")
print(f"  合計 {total} オブジェクト")
PY
}

# Hyperdisk Balanced + 専用ノードの構成は config.toml が既定のままだと通らない経路なので、
# 環境変数で上書きして必ず一度レンダリングする (StorageClass と nodeSelector の生成を確認)。
info "Hyperdisk Balanced + 専用ノード構成でレンダリングできるか検証します"
CFG_CLUSTER_MODE=autopilot \
CFG_POSTGRES_STORAGE_CLASS=hyperdisk-balanced CFG_POSTGRES_STORAGE_SIZE=150Gi \
CFG_POSTGRES_HYPERDISK_IOPS=10000 CFG_POSTGRES_HYPERDISK_THROUGHPUT=250 \
CFG_POSTGRES_COMPUTE_CLASS=Performance CFG_POSTGRES_MACHINE_FAMILY=n4 \
RENDER_ONLY=1 SKIP_CONTEXT_CHECK=1 "${REPO_ROOT}/scripts/deploy-db.sh" >/dev/null \
  || die "Hyperdisk Balanced 構成のレンダリングに失敗しました"
grep -q '"provisioned-iops-on-create": "10000"' "${BUILD_DIR}/05-storageclass.yaml" 2>/dev/null \
  || die "05-storageclass.yaml に IOPS の指定がありません"
grep -q '"use-allowed-disk-topology": "true"' "${BUILD_DIR}/05-storageclass.yaml" 2>/dev/null \
  || die "05-storageclass.yaml に use-allowed-disk-topology の指定がありません"
grep -q '"cloud.google.com/machine-family": "n4"' "${BUILD_DIR}/40-statefulset.yaml" \
  || die "40-statefulset.yaml に machine-family の nodeSelector がありません"
check_yaml

info "マニフェストをレンダリングします (config.toml の構成)"
RENDER_ONLY=1 SKIP_CONTEXT_CHECK=1 "${REPO_ROOT}/scripts/deploy-db.sh" >/dev/null \
  || die "レンダリングに失敗しました"
RENDER_ONLY=1 "${REPO_ROOT}/scripts/deploy-app.sh" >/dev/null \
  || die "サンプルアプリのマニフェストのレンダリングに失敗しました"
check_yaml

info "Python スクリプトとサンプルアプリの構文を検証します"
python3 - "${REPO_ROOT}" <<'PY'
import ast, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = sorted(root.glob("scripts/*.py")) + sorted(root.glob("app/*.py"))
for path in files:
    try:
        ast.parse(path.read_text(), filename=str(path))
    except SyntaxError as exc:
        sys.exit(f"{path.relative_to(root)}: {exc}")
    print(f"  -> {path.relative_to(root)}")
PY

info "シェルスクリプトの構文を検証します"
for f in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/manifests/pg-scripts/*.sh; do
  bash -n "${f}" || die "${f} に構文エラーがあります"
  step "$(basename "${f}")"
done

if command -v shellcheck >/dev/null 2>&1; then
  info "shellcheck を実行します"
  shellcheck -x "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/manifests/pg-scripts/*.sh \
    || warn "shellcheck が指摘を出しました"
fi

ok "検証をすべて通過しました"
