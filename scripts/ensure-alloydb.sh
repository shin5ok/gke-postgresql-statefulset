#!/usr/bin/env bash
# AlloyDB クラスタ + プライマリインスタンス (最小構成) + PSC エンドポイントを用意し、
# アプリ用のデータベースとユーザを初期化する。何度実行しても安全 (冪等)。
#
#   1. AlloyDB / Compute API の有効化
#   2. クラスタ (Private Service Connect 有効) の作成 … 無ければ
#   3. プライマリインスタンスの作成 (--allowed-psc-projects に自プロジェクト) … 無ければ
#   4. PSC エンドポイント = 予約 IP + 転送ルールを GKE クラスタと同じ VPC に作成 … 無ければ
#   5. GKE 上の一時 Pod から psql で接続し、アプリ用ロールとデータベースを作成
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_cmd gcloud kubectl python3
source "$(dirname "${BASH_SOURCE[0]}")/alloydb-lib.sh"

readonly PROJECT="${CFG_GCP_PROJECT}"
readonly REGION="${CFG_ALLOYDB_REGION}"
readonly CLUSTER="${CFG_ALLOYDB_CLUSTER}"
readonly INSTANCE="${CFG_ALLOYDB_INSTANCE}"
readonly ENDPOINT="${CFG_ALLOYDB_PSC_ENDPOINT}"

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    return 0
  fi
  local answer
  read -r -p "${prompt} [Y/n] " answer
  [[ -z "${answer}" || "${answer}" =~ ^[Yy] ]]
}

enable_apis() {
  local required=(alloydb.googleapis.com compute.googleapis.com)
  local enabled missing=()
  enabled="$(gcloud services list --enabled --project "${PROJECT}" \
    --format='value(config.name)' 2>/dev/null || true)"
  for api in "${required[@]}"; do
    grep -qx "${api}" <<<"${enabled}" || missing+=("${api}")
  done
  if (( ${#missing[@]} > 0 )); then
    step "API を有効化します: ${missing[*]}"
    gcloud services enable "${missing[@]}" --project "${PROJECT}" \
      || die "API の有効化に失敗しました。プロジェクト ${PROJECT} の権限を確認してください。"
  fi
}

# パスワードを gcloud に渡すときは --flags-file を使い、コマンドライン (ps) に平文を出さない。
gcloud_with_password() {
  local password="$1"; shift
  local flags rc=0
  flags="$(mktemp)"
  chmod 600 "${flags}"
  PW="${password}" python3 -c 'import json, os; print(json.dumps({"--password": os.environ["PW"]}))' \
    > "${flags}"
  gcloud "$@" --flags-file "${flags}" || rc=$?
  rm -f "${flags}"
  return "${rc}"
}

cluster_field() {
  gcloud alloydb clusters describe "${CLUSTER}" --region "${REGION}" --project "${PROJECT}" \
    --format="value($1)" 2>/dev/null || true
}

instance_field() {
  gcloud alloydb instances describe "${INSTANCE}" --cluster "${CLUSTER}" \
    --region "${REGION}" --project "${PROJECT}" --format="value($1)" 2>/dev/null || true
}

# READY 以外 (CREATING / MAINTENANCE など) なら READY になるまで待つ
wait_ready() {
  local kind="$1" state i
  for i in $(seq 1 90); do
    case "${kind}" in
      cluster)  state="$(cluster_field state)" ;;
      instance) state="$(instance_field state)" ;;
    esac
    [[ "${state}" == "READY" ]] && return 0
    [[ "${state}" == "FAILED" ]] && die "${kind} ${state} です。Cloud Console で状態を確認してください。"
    (( i == 1 )) && step "${kind} が READY になるまで待ちます (現在: ${state:-不明})"
    sleep 20
  done
  die "${kind} が READY になりません。'make alloydb-status' で確認してください。"
}

# ---------------------------------------------------------------------------
# 何を作るかを先に確認する
# ---------------------------------------------------------------------------
info "AlloyDB を確認します (${PROJECT} / ${REGION} / ${CLUSTER} / ${INSTANCE})"
enable_apis

cluster_state="$(cluster_field state)"
instance_state=""
[[ -n "${cluster_state}" ]] && instance_state="$(instance_field state)"
endpoint_ip="$(alloydb_psc_ip)"

to_create=()
[[ -z "${cluster_state}" ]]  && to_create+=("AlloyDB クラスタ ${CLUSTER} (PSC 有効, ${CFG_ALLOYDB_DATABASE_VERSION})")
[[ -z "${instance_state}" ]] && to_create+=("プライマリインスタンス ${INSTANCE}")
[[ -z "${endpoint_ip}" ]]    && to_create+=("PSC エンドポイント ${ENDPOINT} (予約 IP + 転送ルール)")

if (( ${#to_create[@]} > 0 )); then
  size_note="N2 ${CFG_ALLOYDB_CPU_COUNT} vCPU (n2-highmem-${CFG_ALLOYDB_CPU_COUNT})"
  [[ -n "${CFG_ALLOYDB_MACHINE_TYPE}" ]] \
    && size_note="${CFG_ALLOYDB_MACHINE_TYPE} (${CFG_ALLOYDB_CPU_COUNT} vCPU)"
  cat <<SUMMARY

  ${C_BOLD}作成する AlloyDB リソース${C_RESET}
    プロジェクト      : ${PROJECT}
    リージョン        : ${REGION}
    クラスタ          : ${CLUSTER} (${CFG_ALLOYDB_DATABASE_VERSION}, Private Service Connect)
    インスタンス      : ${INSTANCE}  ${size_note}, ${CFG_ALLOYDB_AVAILABILITY_TYPE}
    PSC エンドポイント: ${ENDPOINT} (GKE クラスタ ${CFG_CLUSTER_NAME} と同じ VPC)
    データベース      : ${CFG_ALLOYDB_DATABASE} (所有者: ${CFG_ALLOYDB_USER})

  ${C_DIM}今回作成するもの:$(printf '\n    - %s' "${to_create[@]}")${C_RESET}

  ${C_YELLOW}AlloyDB は課金対象です (インスタンスは停止中も課金されます)。
  作成には 10〜15 分ほどかかります。${C_RESET}

SUMMARY
  confirm "作成しますか?" || die "中止しました。"
fi

# ---------------------------------------------------------------------------
# 1. クラスタ
# ---------------------------------------------------------------------------
if [[ -n "${cluster_state}" ]]; then
  ok "AlloyDB クラスタ ${CLUSTER} は既に存在します (${cluster_state})"
  if [[ "$(cluster_field pscConfig.pscEnabled)" != "True" ]]; then
    die "クラスタ ${CLUSTER} は Private Service Connect が有効ではありません。
       このツールは PSC 前提です。config.toml の [alloydb] cluster を別の名前にして
       新しく作成するか、既存クラスタを削除してから再実行してください。"
  fi
  wait_ready cluster
  if [[ -z "$(alloydb_superuser_password)" ]]; then
    warn ".secrets/alloydb_superuser_password が無いため、postgres ユーザのパスワードを設定し直します"
    superuser_pw="$(persisted_secret alloydb_superuser_password)"
    gcloud_with_password "${superuser_pw}" alloydb users set-password postgres \
      --cluster "${CLUSTER}" --region "${REGION}" --project "${PROJECT}" --quiet \
      || die "postgres ユーザのパスワード設定に失敗しました。"
    ok "postgres ユーザのパスワードを .secrets/alloydb_superuser_password に保存しました"
  fi
else
  superuser_pw="$(persisted_secret alloydb_superuser_password)"
  args=(
    alloydb clusters create "${CLUSTER}"
    --project "${PROJECT}"
    --region "${REGION}"
    --enable-private-service-connect
    --database-version "${CFG_ALLOYDB_DATABASE_VERSION}"
  )
  if [[ -n "${CFG_ALLOYDB_EXTRA_CLUSTER_ARGS}" ]]; then
    read -r -a extra <<<"${CFG_ALLOYDB_EXTRA_CLUSTER_ARGS}"
    args+=("${extra[@]}")
  fi
  step "gcloud ${args[*]} --password ***"
  gcloud_with_password "${superuser_pw}" "${args[@]}" \
    || die "AlloyDB クラスタの作成に失敗しました。"
  ok "AlloyDB クラスタ ${CLUSTER} を作成しました (postgres のパスワード: .secrets/alloydb_superuser_password)"
fi

# ---------------------------------------------------------------------------
# 2. プライマリインスタンス
# ---------------------------------------------------------------------------
if [[ -n "${instance_state}" ]]; then
  ok "インスタンス ${INSTANCE} は既に存在します (${instance_state})"
  wait_ready instance
  allowed="$(instance_field pscInstanceConfig.allowedConsumerProjects)"
  project_number="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)' 2>/dev/null || true)"
  if [[ ";${allowed//[[:space:]]/;};" != *";${PROJECT};"* \
        && ( -z "${project_number}" || ";${allowed//[[:space:]]/;};" != *";${project_number};"* ) ]]; then
    warn "インスタンス ${INSTANCE} の allowed-psc-projects に ${PROJECT} が含まれていません (現在: ${allowed:-なし})。
       PSC エンドポイントが ACCEPTED にならない場合は次を実行してください:
       gcloud alloydb instances update ${INSTANCE} --cluster ${CLUSTER} --region ${REGION} \\
         --project ${PROJECT} --allowed-psc-projects ${PROJECT}"
  fi
else
  args=(
    alloydb instances create "${INSTANCE}"
    --project "${PROJECT}"
    --region "${REGION}"
    --cluster "${CLUSTER}"
    --instance-type PRIMARY
    --availability-type "${CFG_ALLOYDB_AVAILABILITY_TYPE}"
    --cpu-count "${CFG_ALLOYDB_CPU_COUNT}"
    --allowed-psc-projects "${PROJECT}"
    --labels "managed-by=gke-postgresql-statefulset"
  )
  [[ -n "${CFG_ALLOYDB_MACHINE_TYPE}" ]] && args+=(--machine-type "${CFG_ALLOYDB_MACHINE_TYPE}")
  if [[ -n "${CFG_ALLOYDB_EXTRA_INSTANCE_ARGS}" ]]; then
    read -r -a extra <<<"${CFG_ALLOYDB_EXTRA_INSTANCE_ARGS}"
    args+=("${extra[@]}")
  fi
  step "gcloud ${args[*]}"
  step "(インスタンスの作成には 10 分前後かかります)"
  gcloud "${args[@]}" || die "インスタンスの作成に失敗しました。"
  ok "インスタンス ${INSTANCE} を作成しました"
fi

# ---------------------------------------------------------------------------
# 3. PSC エンドポイント (GKE クラスタと同じ VPC に、予約 IP + 転送ルール)
# ---------------------------------------------------------------------------
sa_link="$(instance_field pscInstanceConfig.serviceAttachmentLink)"
[[ -n "${sa_link}" ]] \
  || die "インスタンス ${INSTANCE} にサービスアタッチメントがありません (PSC が有効なクラスタか確認してください)。"

# GKE クラスタの VPC とサブネットを使う (Pod から到達できる必要があるため)
gke_network=""; gke_subnet=""
read -r gke_network gke_subnet <<<"$(gcloud container clusters describe "${CFG_CLUSTER_NAME}" \
  --project "${PROJECT}" "${CFG_CLUSTER_LOCATION_FLAG}" "${CFG_CLUSTER_LOCATION}" \
  --format='value(network,subnetwork)' 2>/dev/null || true)"
[[ -n "${gke_network}" ]] \
  || die "GKE クラスタ ${CFG_CLUSTER_NAME} の VPC を取得できません。先に 'make cluster' を実行してください。"

if [[ "${REGION}" == "${CFG_GCP_REGION}" && -n "${gke_subnet}" ]]; then
  subnet="${gke_subnet}"
else
  # AlloyDB が別リージョンなら、同じ VPC のそのリージョンのサブネットを使う
  subnet="$(gcloud compute networks subnets list --project "${PROJECT}" \
    --filter="network:${gke_network##*/} AND region:${REGION}" \
    --format='value(name)' 2>/dev/null | head -n 1)"
  [[ -n "${subnet}" ]] \
    || die "VPC ${gke_network##*/} にリージョン ${REGION} のサブネットがありません。
       PSC エンドポイントは AlloyDB と同じリージョンに作る必要があります。"
fi

if [[ -z "${endpoint_ip}" ]]; then
  args=(
    compute addresses create "${ENDPOINT}"
    --project "${PROJECT}"
    --region "${REGION}"
    --subnet "${subnet}"
    --description "AlloyDB PSC endpoint for ${CLUSTER}/${INSTANCE}"
  )
  [[ -n "${CFG_ALLOYDB_PSC_IP}" ]] && args+=(--addresses "${CFG_ALLOYDB_PSC_IP}")
  step "gcloud ${args[*]}"
  gcloud "${args[@]}" || die "内部 IP の予約に失敗しました。"
  endpoint_ip="$(alloydb_psc_ip)"
  ok "内部 IP ${endpoint_ip} を予約しました (${ENDPOINT})"
else
  ok "予約済みの内部 IP を使います: ${endpoint_ip} (${ENDPOINT})"
  if [[ -n "${CFG_ALLOYDB_PSC_IP}" && "${CFG_ALLOYDB_PSC_IP}" != "${endpoint_ip}" ]]; then
    warn "alloydb.psc_ip (${CFG_ALLOYDB_PSC_IP}) と予約済みの IP (${endpoint_ip}) が異なります。予約済みの IP を使います。"
  fi
fi

fr_target="$(gcloud compute forwarding-rules describe "${ENDPOINT}" --project "${PROJECT}" \
  --region "${REGION}" --format='value(target)' 2>/dev/null || true)"
if [[ -z "${fr_target}" ]]; then
  args=(
    compute forwarding-rules create "${ENDPOINT}"
    --project "${PROJECT}"
    --region "${REGION}"
    --network "${gke_network}"
    --address "${ENDPOINT}"
    --target-service-attachment "${sa_link}"
    --allow-psc-global-access
  )
  step "gcloud ${args[*]}"
  gcloud "${args[@]}" || die "PSC エンドポイント (転送ルール) の作成に失敗しました。"
  ok "PSC エンドポイント ${ENDPOINT} を作成しました"
elif [[ "${fr_target#*projects/}" != "${sa_link#*projects/}" ]]; then
  die "転送ルール ${ENDPOINT} は別のサービスアタッチメントを指しています:
         ${fr_target}
       'make destroy-alloydb' で削除してから再実行するか、[alloydb] psc_endpoint を別の名前にしてください。"
else
  ok "PSC エンドポイント ${ENDPOINT} は既に存在します"
fi

psc_status=""
for i in $(seq 1 24); do
  psc_status="$(gcloud compute forwarding-rules describe "${ENDPOINT}" --project "${PROJECT}" \
    --region "${REGION}" --format='value(pscConnectionStatus)' 2>/dev/null || true)"
  [[ "${psc_status}" == "ACCEPTED" ]] && break
  (( i == 1 )) && step "PSC 接続が受け入れられるまで待ちます (現在: ${psc_status:-不明})"
  sleep 5
done
[[ "${psc_status}" == "ACCEPTED" ]] \
  || die "PSC 接続が ACCEPTED になりません (現在: ${psc_status})。
       インスタンスの allowed-psc-projects に ${PROJECT} が含まれているか確認してください。"
ok "PSC 接続: ${psc_status} (${endpoint_ip} -> ${sa_link#*serviceAttachments/})"

# ---------------------------------------------------------------------------
# 4. アプリ用ロールとデータベース (GKE 上の一時 Pod から psql で)
# ---------------------------------------------------------------------------
info "アプリ用のロールとデータベースを初期化します"
if [[ -n "${CFG_ALLOYDB_PASSWORD}" ]]; then
  app_pw="${CFG_ALLOYDB_PASSWORD}"
else
  app_pw="$(persisted_secret alloydb_app_password)"
fi
# SQL の文字列リテラル用にシングルクォートを二重化する (名前は config.py で検証済み)
app_pw_sql="${app_pw//\'/\'\'}"

alloydb_pod_start superuser
alloydb_pod_wait_ready
# \gexec: SELECT の結果 (文字列) を SQL として実行する。行が無ければ何もしない。
# AlloyDB の postgres は本物のスーパーユーザではないので、他ロール所有の DB を作るには
# 先にそのロールのメンバーになる (GRANT ... TO current_user) 必要がある。
alloydb_pod_psql --quiet --set ON_ERROR_STOP=1 <<SQL
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', '${CFG_ALLOYDB_USER}', '${app_pw_sql}')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${CFG_ALLOYDB_USER}') \\gexec
SELECT format('ALTER ROLE %I PASSWORD %L', '${CFG_ALLOYDB_USER}', '${app_pw_sql}') \\gexec
SELECT format('GRANT %I TO %I', '${CFG_ALLOYDB_USER}', current_user)
 WHERE NOT EXISTS (
   SELECT 1 FROM pg_auth_members m
     JOIN pg_roles r ON r.oid = m.roleid
     JOIN pg_roles u ON u.oid = m.member
    WHERE r.rolname = '${CFG_ALLOYDB_USER}' AND u.rolname = current_user) \\gexec
SELECT format('CREATE DATABASE %I OWNER %I', '${CFG_ALLOYDB_DATABASE}', '${CFG_ALLOYDB_USER}')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${CFG_ALLOYDB_DATABASE}') \\gexec
SQL
# AlloyDB の template では public スキーマの所有者が pg_database_owner ではなく
# alloydbsuperuser (ACL: alloydbsuperuser=UC, PUBLIC は USAGE のみ) なので、
# データベースの所有者にしただけではテーブルを作れない。StatefulSet 側の
# init-01-app-user.sh と同じく所有者をアプリ用ロールに移す (再実行しても無害)。
alloydb_pod_psql --quiet --set ON_ERROR_STOP=1 --dbname "${CFG_ALLOYDB_DATABASE}" <<SQL
ALTER SCHEMA public OWNER TO "${CFG_ALLOYDB_USER}";
SQL
ok "ロール ${CFG_ALLOYDB_USER} とデータベース ${CFG_ALLOYDB_DATABASE} (public スキーマの所有者: ${CFG_ALLOYDB_USER}) を用意しました"

cat <<INFO

${C_BOLD}AlloyDB 接続情報${C_RESET}
  クラスタ / インスタンス : ${CLUSTER} / ${INSTANCE} (${REGION})
  PSC エンドポイント      : ${endpoint_ip}:5432 (${ENDPOINT}, VPC 内からのみ到達可能)
  データベース            : ${CFG_ALLOYDB_DATABASE}
  ユーザ                  : ${CFG_ALLOYDB_USER}
  パスワード              : $(if [[ -n "${CFG_ALLOYDB_PASSWORD}" ]]; then echo "config.toml の値"; else echo ".secrets/alloydb_app_password"; fi)
  postgres ユーザ         : .secrets/alloydb_superuser_password

  ${C_DIM}# クラスタ内 (VPC 内) から${C_RESET}
  postgresql://${CFG_ALLOYDB_USER}@${endpoint_ip}:5432/${CFG_ALLOYDB_DATABASE}?sslmode=require

  ${C_DIM}# スキーマとダミーデータを投入する${C_RESET}
  make alloydb-content

  ${C_DIM}# psql を開く (GKE 上の一時 Pod 経由)${C_RESET}
  make alloydb-psql

  ${C_DIM}# サンプルアプリの接続先を AlloyDB に切り替える${C_RESET}
  make app-target T=alloydb

INFO
