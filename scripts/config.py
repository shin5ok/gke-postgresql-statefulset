#!/usr/bin/env python3
"""config.toml.template をデフォルト値として config.toml をマージし、
シェルから source できる形式 (KEY='value') で出力する。

  - config.toml.template が「スキーマ兼デフォルト値」の唯一の情報源。
  - config.toml には変更したいキーだけ書けばよい。
  - 環境変数 CFG_<SECTION>_<KEY> が最優先で上書きする。
  - 未知のキー / 型不一致はエラーにする（設定ミスの握りつぶしを防ぐため）。
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "config.toml.template"
CONFIG = ROOT / "config.toml"


def die(msg: str) -> None:
    print(f"config error: {msg}", file=sys.stderr)
    sys.exit(1)


def load(path: Path) -> dict:
    try:
        with path.open("rb") as fh:
            return tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        die(f"{path.name} をパースできません: {exc}")
    except OSError as exc:
        die(f"{path} を読めません: {exc}")


def merge(defaults: dict, override: dict, origin: str) -> dict:
    """defaults を override で上書き。未知キー・型不一致はエラー。"""
    out = {sec: dict(vals) for sec, vals in defaults.items()}
    for section, values in override.items():
        if section not in defaults:
            die(f"{origin}: 未知のセクション [{section}] "
                f"(有効: {', '.join(sorted(defaults))})")
        if not isinstance(values, dict):
            die(f"{origin}: [{section}] はテーブルである必要があります")
        for key, value in values.items():
            if key not in defaults[section]:
                die(f"{origin}: [{section}] に未知のキー '{key}' "
                    f"(有効: {', '.join(sorted(defaults[section]))})")
            want = type(defaults[section][key])
            # bool は int のサブクラスなので厳密に区別する
            if isinstance(value, bool) != isinstance(defaults[section][key], bool) \
                    or not isinstance(value, want):
                die(f"{origin}: [{section}].{key} は {want.__name__} 型である必要が"
                    f"あります (指定値: {value!r})")
            out[section][key] = value
    return out


def apply_env_overrides(cfg: dict) -> dict:
    for section, values in cfg.items():
        for key, default in values.items():
            env_name = f"CFG_{section.upper()}_{key.upper()}"
            raw = os.environ.get(env_name)
            if raw is None:
                continue
            if isinstance(default, bool):
                low = raw.strip().lower()
                if low not in ("true", "false", "1", "0", "yes", "no"):
                    die(f"環境変数 {env_name}: 真偽値が必要です (指定値: {raw!r})")
                values[key] = low in ("true", "1", "yes")
            elif isinstance(default, int):
                try:
                    values[key] = int(raw)
                except ValueError:
                    die(f"環境変数 {env_name}: 整数が必要です (指定値: {raw!r})")
            else:
                values[key] = raw
    return cfg


def gcloud_project() -> str:
    try:
        out = subprocess.run(
            ["gcloud", "config", "get-value", "project"],
            capture_output=True, text=True, timeout=30, check=False,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""
    return "" if out in ("", "(unset)") else out


NAME_RE = re.compile(r"^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$")
SIZE_RE = re.compile(r"^\d+(\.\d+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$")
QTY_RE = re.compile(r"^\d+(\.\d+)?m?$")


IPV4_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
# --cpu-count だけで作れる N2 の vCPU 数
ALLOYDB_N2_CPUS = (2, 4, 8, 16, 32, 64, 96, 128)
ALLOYDB_VERSIONS = ("POSTGRES_14", "POSTGRES_15", "POSTGRES_16", "POSTGRES_17",
                    "POSTGRES_18")


def validate(cfg: dict) -> None:
    gcp, cl, pg, ct = cfg["gcp"], cfg["cluster"], cfg["postgres"], cfg["content"]
    adb, app = cfg["alloydb"], cfg["app"]

    if not gcp["project"]:
        die("gcp.project が空で、`gcloud config get-value project` も未設定です。\n"
            "       config.toml の [gcp] project を設定するか "
            "`gcloud config set project <PROJECT_ID>` を実行してください。")

    if cl["mode"] not in ("autopilot", "standard"):
        die(f"cluster.mode は 'autopilot' か 'standard' です "
            f"(指定値: {cl['mode']!r})")
    autopilot = cl["mode"] == "autopilot"

    if cl["location_type"] not in ("zonal", "regional"):
        die(f"cluster.location_type は 'zonal' か 'regional' です "
            f"(指定値: {cl['location_type']!r})")
    if autopilot:
        # Autopilot クラスタは常にリージョナル (location_type は使われない)
        if not gcp["region"]:
            die("cluster.mode = 'autopilot' のとき gcp.region は必須です "
                "(Autopilot クラスタは常にリージョナルです)")
        if cl["release_channel"] == "None":
            die("cluster.mode = 'autopilot' では cluster.release_channel に "
                "'None' を指定できません (rapid | regular | stable | extended)")
    elif cl["location_type"] == "zonal" and not gcp["zone"]:
        die("cluster.location_type = 'zonal' のとき gcp.zone は必須です")
    elif cl["location_type"] == "regional" and not gcp["region"]:
        die("cluster.location_type = 'regional' のとき gcp.region は必須です")
    if gcp["zone"] and gcp["region"] and not gcp["zone"].startswith(gcp["region"]):
        die(f"gcp.zone ({gcp['zone']}) が gcp.region ({gcp['region']}) に属していません")

    for label, value in (("cluster.name", cl["name"]),
                         ("postgres.name", pg["name"]),
                         ("postgres.namespace", pg["namespace"])):
        if not NAME_RE.match(value):
            die(f"{label} は英小文字で始まる英数字とハイフンのみ、40 文字以内です "
                f"(指定値: {value!r})")

    if cl["num_nodes"] < 1:
        die(f"cluster.num_nodes は 1 以上です (指定値: {cl['num_nodes']})")
    if cl["disk_size_gb"] < 10:
        die(f"cluster.disk_size_gb は 10 以上です (指定値: {cl['disk_size_gb']})")
    if cl["autoscaling"]:
        if cl["min_nodes"] < 0 or cl["max_nodes"] < cl["min_nodes"]:
            die(f"cluster.min_nodes ({cl['min_nodes']}) <= max_nodes "
                f"({cl['max_nodes']}) である必要があります")
        if not (cl["min_nodes"] <= cl["num_nodes"] <= cl["max_nodes"]):
            die(f"cluster.num_nodes ({cl['num_nodes']}) は min_nodes "
                f"({cl['min_nodes']}) と max_nodes ({cl['max_nodes']}) の間である"
                f"必要があります")
    if cl["release_channel"] not in ("rapid", "regular", "stable", "extended", "None"):
        die("cluster.release_channel は rapid | regular | stable | extended | None です "
            f"(指定値: {cl['release_channel']!r})")

    if pg["replicas"] < 1:
        die(f"postgres.replicas は 1 以上です (指定値: {pg['replicas']})")
    if not SIZE_RE.match(pg["storage_size"]):
        die(f"postgres.storage_size の書式が不正です (例: 20Gi / 100Gi)"
            f" (指定値: {pg['storage_size']!r})")
    for label, value in (("cpu_request", pg["cpu_request"]),
                         ("cpu_limit", pg["cpu_limit"])):
        if not QTY_RE.match(value):
            die(f"postgres.{label} の書式が不正です (例: 500m / 2) "
                f"(指定値: {value!r})")
    for label, value in (("memory_request", pg["memory_request"]),
                         ("memory_limit", pg["memory_limit"])):
        if not SIZE_RE.match(value):
            die(f"postgres.{label} の書式が不正です (例: 1Gi / 4Gi) "
                f"(指定値: {value!r})")
    if pg["max_connections"] < 1:
        die(f"postgres.max_connections は 1 以上です (指定値: {pg['max_connections']})")
    if pg["database"] == "postgres":
        die("postgres.database に 'postgres' は指定できません（管理用 DB のため）")

    for label, value in (("content.rows_customers", ct["rows_customers"]),
                         ("content.rows_products", ct["rows_products"]),
                         ("content.rows_orders", ct["rows_orders"])):
        if value < 0:
            die(f"{label} は 0 以上です (指定値: {value})")

    # ---- [alloydb] ----
    for label, value in (("alloydb.cluster", adb["cluster"]),
                         ("alloydb.instance", adb["instance"]),
                         ("alloydb.psc_endpoint", adb["psc_endpoint"])):
        if not NAME_RE.match(value):
            die(f"{label} は英小文字で始まる英数字とハイフンのみ、40 文字以内です "
                f"(指定値: {value!r})")
    if adb["database_version"] not in ALLOYDB_VERSIONS:
        die(f"alloydb.database_version は {' | '.join(ALLOYDB_VERSIONS)} です "
            f"(指定値: {adb['database_version']!r})")
    if adb["availability_type"] not in ("ZONAL", "REGIONAL"):
        die(f"alloydb.availability_type は 'ZONAL' か 'REGIONAL' です "
            f"(指定値: {adb['availability_type']!r})")
    if adb["cpu_count"] < 1:
        die(f"alloydb.cpu_count は 1 以上です (指定値: {adb['cpu_count']})")
    if not adb["machine_type"] and adb["cpu_count"] not in ALLOYDB_N2_CPUS:
        die(f"alloydb.machine_type が空のとき alloydb.cpu_count は "
            f"{'/'.join(map(str, ALLOYDB_N2_CPUS))} のいずれかです "
            f"(指定値: {adb['cpu_count']})。1 vCPU にするには "
            "machine_type = \"c4a-highmem-1\" を指定してください (対応リージョンのみ)")
    if adb["machine_type"]:
        m = re.search(r"-(\d+)(-lssd)?$", adb["machine_type"])
        if m and int(m.group(1)) != adb["cpu_count"]:
            die(f"alloydb.cpu_count ({adb['cpu_count']}) が alloydb.machine_type "
                f"({adb['machine_type']}) の vCPU 数と一致しません")
    if adb["pool_mode"].lower() not in ("transaction", "session"):
        die(f"alloydb.pool_mode は 'transaction' か 'session' です "
            f"(指定値: {adb['pool_mode']!r})")
    # AlloyDB の API は小文字を返すので小文字に揃える。
    # (gcloud のフラグだけは大文字を要求するため、渡す直前に大文字化する)
    adb["pool_mode"] = adb["pool_mode"].lower()
    if adb["database"] == "postgres":
        die("alloydb.database に 'postgres' は指定できません（管理用 DB のため）")
    if adb["user"] == "postgres":
        die("alloydb.user に 'postgres' は指定できません（管理用ユーザのため）")
    if adb["psc_ip"]:
        m = IPV4_RE.match(adb["psc_ip"])
        if not m or any(int(o) > 255 for o in m.groups()):
            die(f"alloydb.psc_ip は IPv4 アドレスです (指定値: {adb['psc_ip']!r})")

    # ---- [app] ----
    if app["target"] not in ("postgresql", "alloydb"):
        die(f"app.target は 'postgresql' か 'alloydb' です (指定値: {app['target']!r})")
    for label, value in (("app.namespace", app["namespace"]),
                         ("app.name", app["name"])):
        if not NAME_RE.match(value):
            die(f"{label} は英小文字で始まる英数字とハイフンのみ、40 文字以内です "
                f"(指定値: {value!r})")
    if not re.match(r"^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", app["registry"]):
        die(f"app.registry は英小文字で始まる英数字とハイフンのみです "
            f"(指定値: {app['registry']!r})")
    if app["image_tag"] and not re.match(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", app["image_tag"]):
        die(f"app.image_tag の書式が不正です (指定値: {app['image_tag']!r})")
    if app["builder"] not in ("cloudbuild", "docker"):
        die(f"app.builder は 'cloudbuild' か 'docker' です (指定値: {app['builder']!r})")
    if app["service_type"] not in ("ClusterIP", "LoadBalancer"):
        die(f"app.service_type は 'ClusterIP' か 'LoadBalancer' です "
            f"(指定値: {app['service_type']!r})")
    if app["replicas"] < 1:
        die(f"app.replicas は 1 以上です (指定値: {app['replicas']})")
    if not QTY_RE.match(app["cpu_request"]):
        die(f"app.cpu_request の書式が不正です (例: 250m / 1) "
            f"(指定値: {app['cpu_request']!r})")
    if not SIZE_RE.match(app["memory_request"]):
        die(f"app.memory_request の書式が不正です (例: 512Mi / 1Gi) "
            f"(指定値: {app['memory_request']!r})")


def derive(cfg: dict) -> dict:
    """他の値から決まる項目を計算する。"""
    gcp, cl, pg = cfg["gcp"], cfg["cluster"], cfg["postgres"]
    adb, app = cfg["alloydb"], cfg["app"]
    # Autopilot クラスタは常にリージョナルなので location_type は見ない
    zonal = cl["mode"] == "standard" and cl["location_type"] == "zonal"
    location = gcp["zone"] if zonal else gcp["region"]
    # Autopilot にはノードプールが無いため、Spot は Pod 側で指定する
    autopilot_spot = cl["mode"] == "autopilot" and cl["spot"]
    return {
        "CLUSTER_LOCATION": location,
        # gcloud に渡すロケーション指定フラグ
        "CLUSTER_LOCATION_FLAG": ("--zone" if zonal else "--region"),
        # Spot Pod の指定。YAML のフローマッピングとしてそのまま埋め込む。
        "POD_NODE_SELECTOR_JSON": (
            '{"cloud.google.com/gke-spot": "true"}' if autopilot_spot else "{}"
        ),
        # nodeSelector に対応する toleration は Autopilot が自動で足してくれるが、
        # 自分で書いておかないと apply のたびに mutating webhook の警告が出る。
        "POD_TOLERATIONS_JSON": (
            '[{"key": "cloud.google.com/gke-spot", "operator": "Equal", '
            '"value": "true", "effect": "NoSchedule"}]'
            if autopilot_spot else "[]"
        ),
        # Spot の toleration を持つ Pod は Autopilot では猶予期間が最大 25 秒。
        # 超える値を書くと 25 秒に切り下げられ、やはり警告が出る。
        "POD_TERMINATION_GRACE": "25" if autopilot_spot else "60",
        # gcloud container clusters get-credentials が作る context 名
        "KUBE_CONTEXT": f"gke_{gcp['project']}_{location}_{cl['name']}",
        # StatefulSet の ordinal 0 (プライマリ) の FQDN
        "PRIMARY_HOST": f"{pg['name']}-0.{pg['name']}.{pg['namespace']}.svc.cluster.local",
        # レプリケーション構成かどうか
        "HA": "true" if pg["replicas"] >= 2 else "false",
        # PVC のマウント先直下ではなくサブディレクトリを使う (lost+found 対策)
        "PGDATA": "/var/lib/postgresql/data/pgdata",
        # postgres 公式イメージの postgres ユーザ / グループ
        "PG_UID": "999",
        "PG_GID": "999",
        "REPO_ROOT": str(ROOT),
        # ---- AlloyDB ----
        "ALLOYDB_REGION": adb["region"] or gcp["region"],
        # アプリが接続するポート。マネージド接続プーリングを有効にすると
        # プーラーが 6432 で待ち受ける (5432 は直結のまま残る)。
        "ALLOYDB_PORT": "6432" if adb["connection_pooling"] else "5432",
        # 管理用 (psql / dump の投入) は常に直結。transaction モードのプーラー越しでは
        # dump.sql の先頭にある SET が実行できないため。
        "ALLOYDB_DIRECT_PORT": "5432",
        # ---- サンプルアプリ ----
        # StatefulSet 側の書き込みエンドポイント (クラスタ内 DNS 名)
        "APP_DB_HOST_POSTGRESQL": f"{pg['name']}-rw.{pg['namespace']}.svc.cluster.local",
        # Artifact Registry 上のイメージ名 (タグは build-app.sh が決める)
        "APP_IMAGE_REPO": (f"{gcp['region']}-docker.pkg.dev/{gcp['project']}/"
                           f"{app['registry']}/{app['name']}"),
    }


def emit(cfg: dict, derived: dict, fmt: str) -> None:
    flat: dict[str, str] = {}
    for section, values in cfg.items():
        for key, value in values.items():
            if isinstance(value, bool):
                rendered = "true" if value else "false"
            else:
                rendered = str(value)
            flat[f"CFG_{section.upper()}_{key.upper()}"] = rendered
    for key, value in derived.items():
        flat[f"CFG_{key}"] = value

    if fmt == "sh":
        for key, value in flat.items():
            print(f"{key}={shlex.quote(value)}")
    elif fmt == "env":
        for key, value in flat.items():
            print(f"{key}={value}")
    elif fmt == "show":
        width = max(len(k) for k in flat)
        secret = ("PASSWORD",)
        for key, value in flat.items():
            if any(s in key for s in secret) and value:
                value = "***"
            print(f"{key.ljust(width)} = {value}")
    else:
        die(f"未知の出力形式: {fmt}")


def main() -> None:
    fmt = sys.argv[1] if len(sys.argv) > 1 else "sh"

    if not TEMPLATE.exists():
        die(f"{TEMPLATE} が見つかりません（デフォルト値の定義元です）")
    defaults = load(TEMPLATE)

    cfg = defaults
    if CONFIG.exists():
        cfg = merge(defaults, load(CONFIG), CONFIG.name)
    cfg = apply_env_overrides(cfg)

    if not cfg["gcp"]["project"]:
        cfg["gcp"]["project"] = gcloud_project()

    validate(cfg)
    emit(cfg, derive(cfg), fmt)


if __name__ == "__main__":
    main()
