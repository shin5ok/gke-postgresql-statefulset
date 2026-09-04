#!/usr/bin/env bash
# AlloyDB に psql で接続するための共通処理 (lib.sh と load_config の後に source する)。
#
# PSC エンドポイントは VPC 内からしか到達できないため、GKE クラスタ上に一時的な
# Pod (postgres イメージ) を立て、その中の psql を kubectl exec で使う。
#
#   alloydb_pod_start superuser|app   Pod を作って Ready まで待つ (スクリプト終了時に自動削除)
#   alloydb_pod_wait_ready            DB に接続できるようになるまで待つ
#   alloydb_pod_psql <psql の引数>    Pod 内で psql を実行する (標準入力はそのまま渡る)

ALLOYDB_POD=""
ALLOYDB_POD_NS=""

alloydb_pod_cleanup() {
  if [[ -n "${ALLOYDB_POD}" ]]; then
    kc -n "${ALLOYDB_POD_NS}" delete pod "${ALLOYDB_POD}" --wait=false >/dev/null 2>&1 || true
  fi
}

alloydb_pod_start() {
  local role="$1" user db password ip
  ip="$(alloydb_psc_ip)"
  [[ -n "${ip}" ]] \
    || die "PSC エンドポイント ${CFG_ALLOYDB_PSC_ENDPOINT} がありません。先に 'make alloydb' を実行してください。"

  case "${role}" in
    superuser)
      user="postgres"; db="postgres"
      password="$(alloydb_superuser_password)"
      [[ -n "${password}" ]] \
        || die ".secrets/alloydb_superuser_password がありません。'make alloydb' を実行すると
       postgres ユーザのパスワードを設定し直して保存します。"
      ;;
    app)
      user="${CFG_ALLOYDB_USER}"; db="${CFG_ALLOYDB_DATABASE}"
      password="$(alloydb_app_password)"
      [[ -n "${password}" ]] \
        || die "アプリ用ユーザのパスワードがありません (.secrets/alloydb_app_password)。
       先に 'make alloydb' を実行してください。"
      ;;
    *) die "alloydb_pod_start: superuser か app を指定してください" ;;
  esac

  kube_context_exists \
    || die "context ${CFG_KUBE_CONTEXT} がありません。先に 'make cluster' を実行してください。"

  ALLOYDB_POD_NS="${CFG_APP_NAMESPACE}"
  ALLOYDB_POD="alloydb-psql-$(date +%s)-${RANDOM}"
  trap alloydb_pod_cleanup EXIT

  kc get namespace "${ALLOYDB_POD_NS}" >/dev/null 2>&1 \
    || kc create namespace "${ALLOYDB_POD_NS}" >/dev/null

  step "一時 Pod ${ALLOYDB_POD_NS}/${ALLOYDB_POD} を作成します (psql -> ${ip}:5432, user=${user})"
  # パスワードは引数ではなく環境変数で python に渡し、マニフェストは標準入力で apply する
  # (手元の ps にも kubectl の引数にも平文を出さないため)
  POD_NAME="${ALLOYDB_POD}" POD_NS="${ALLOYDB_POD_NS}" \
  PGHOST="${ip}" PGUSER="${user}" PGDATABASE="${db}" PGPASSWORD="${password}" \
  PG_IMAGE="postgres:${CFG_POSTGRES_VERSION}" \
  NODE_SELECTOR="${CFG_POD_NODE_SELECTOR_JSON}" TOLERATIONS="${CFG_POD_TOLERATIONS_JSON}" \
  python3 - <<'PY' | kc apply -f - >/dev/null || die "一時 Pod の作成に失敗しました"
import json, os
env = {k: os.environ[k] for k in ("PGHOST", "PGUSER", "PGDATABASE", "PGPASSWORD")}
env.update(PGPORT="5432", PGSSLMODE="require", PGCONNECT_TIMEOUT="10")
pod = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {
        "name": os.environ["POD_NAME"],
        "namespace": os.environ["POD_NS"],
        "labels": {"app": "alloydb-psql",
                   "app.kubernetes.io/managed-by": "gke-postgresql-statefulset"},
    },
    "spec": {
        "restartPolicy": "Never",
        # 消し忘れても 1 時間で終了する
        "activeDeadlineSeconds": 3600,
        "terminationGracePeriodSeconds": 5,
        "nodeSelector": json.loads(os.environ["NODE_SELECTOR"]),
        "tolerations": json.loads(os.environ["TOLERATIONS"]),
        "securityContext": {"runAsNonRoot": True, "runAsUser": 999, "runAsGroup": 999},
        "containers": [{
            "name": "psql",
            "image": os.environ["PG_IMAGE"],
            "command": ["sleep", "3600"],
            "env": [{"name": k, "value": v} for k, v in env.items()],
            "resources": {"requests": {"cpu": "250m", "memory": "256Mi"},
                          "limits": {"cpu": "250m", "memory": "256Mi"}},
        }],
    },
}
print(json.dumps(pod))
PY

  if ! kc -n "${ALLOYDB_POD_NS}" wait --for=condition=Ready "pod/${ALLOYDB_POD}" \
         --timeout="${POD_TIMEOUT:-300s}" >/dev/null 2>&1; then
    kc -n "${ALLOYDB_POD_NS}" describe pod "${ALLOYDB_POD}" 2>/dev/null | tail -n 15 >&2 || true
    die "一時 Pod が起動しませんでした (Autopilot ではノードの準備に 1〜2 分かかることがあります)"
  fi
}

# Pod 内で psql を実行する。標準入力はそのまま psql に渡る。
alloydb_pod_psql() {
  local tty_flag=()
  [[ -t 0 && -t 1 ]] && tty_flag=(-t)
  kc -n "${ALLOYDB_POD_NS}" exec -i "${tty_flag[@]}" "${ALLOYDB_POD}" -- psql "$@"
}

# PSC エンドポイント経由で DB に接続できるまで待つ (エンドポイント作成直後は少し時間がかかる)
alloydb_pod_wait_ready() {
  local i
  for i in $(seq 1 "${DB_WAIT_TRIES:-18}"); do
    if kc -n "${ALLOYDB_POD_NS}" exec -i "${ALLOYDB_POD}" -- \
         psql -qAt -c 'SELECT 1' </dev/null >/dev/null 2>&1; then
      return 0
    fi
    (( i == 1 )) && step "AlloyDB に接続できるまで待ちます"
    sleep 10
  done
  kc -n "${ALLOYDB_POD_NS}" exec -i "${ALLOYDB_POD}" -- psql -qAt -c 'SELECT 1' </dev/null >&2 || true
  die "AlloyDB に接続できません。'make alloydb-status' で PSC エンドポイントの状態を確認してください。"
}
