#!/usr/bin/env python3
"""`gcloud container clusters describe --format=json` の出力を標準入力から読み、
既存クラスタの現在値をシェル変数 (LIVE_*) として出力する。

ensure-cluster.sh が config.toml との差分を判定するために使う。
"""
import json
import shlex
import sys


def main() -> None:
    try:
        cluster = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"cluster-facts error: describe の出力を解釈できません: {exc}",
              file=sys.stderr)
        sys.exit(1)

    pools = cluster.get("nodePools") or [{}]
    pool = pools[0]
    config = pool.get("config") or {}
    autoscaling = pool.get("autoscaling") or {}

    # リリースチャンネルは API が大文字 (REGULAR) を返す。未設定なら none 扱い。
    channel = ((cluster.get("releaseChannel") or {}).get("channel") or "").lower()
    if channel in ("", "unspecified"):
        channel = "none"

    facts = {
        "LIVE_POOL": pool.get("name", ""),
        "LIVE_POOL_COUNT": str(len(pools)),
        # regional クラスタでは「ゾーンあたり」の台数。config の num_nodes と同じ意味。
        "LIVE_NODES": str(pool.get("initialNodeCount", "")),
        "LIVE_MACHINE_TYPE": config.get("machineType", ""),
        "LIVE_DISK_TYPE": config.get("diskType", ""),
        "LIVE_DISK_SIZE_GB": str(config.get("diskSizeGb", "")),
        "LIVE_IMAGE_TYPE": (config.get("imageType") or "").upper(),
        "LIVE_SPOT": "true" if config.get("spot") else "false",
        "LIVE_AUTOSCALING": "true" if autoscaling.get("enabled") else "false",
        "LIVE_MIN_NODES": str(autoscaling.get("minNodeCount", "")),
        "LIVE_MAX_NODES": str(autoscaling.get("maxNodeCount", "")),
        "LIVE_RELEASE_CHANNEL": channel,
        "LIVE_MASTER_VERSION": cluster.get("currentMasterVersion", ""),
        "LIVE_AUTOPILOT": "true" if (cluster.get("autopilot") or {}).get("enabled") else "false",
    }
    for key, value in facts.items():
        print(f"{key}={shlex.quote(value)}")


if __name__ == "__main__":
    main()
