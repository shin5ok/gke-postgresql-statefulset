#!/usr/bin/env python3
"""config.toml の 1 つのキーを、コメントを保ったまま書き換える。

  set-config.py <section> <key> <value>

`make scale N=3` のように「次回以降の make db にも効いてほしい」変更を
config.toml に反映するために使う。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "config.toml"
TEMPLATE = ROOT / "config.toml.template"


def die(msg: str) -> None:
    print(f"set-config error: {msg}", file=sys.stderr)
    sys.exit(1)


def format_value(raw: str) -> str:
    if re.fullmatch(r"-?\d+", raw):
        return raw
    if raw.lower() in ("true", "false"):
        return raw.lower()
    return '"' + raw.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> None:
    if len(sys.argv) != 4:
        print("usage: set-config.py <section> <key> <value>", file=sys.stderr)
        sys.exit(2)
    section, key, raw = sys.argv[1], sys.argv[2], sys.argv[3]
    value = format_value(raw)

    if not CONFIG.exists():
        if not TEMPLATE.exists():
            die(f"{CONFIG} も {TEMPLATE} も見つかりません")
        CONFIG.write_text(TEMPLATE.read_text())

    lines = CONFIG.read_text().splitlines()
    header = re.compile(r"^\s*\[([^\]]+)\]\s*$")
    assign = re.compile(rf"^(\s*){re.escape(key)}(\s*)=(\s*)(.*)$")

    in_section = False
    section_at = None
    for i, line in enumerate(lines):
        match = header.match(line)
        if match:
            in_section = match.group(1).strip() == section
            if in_section:
                section_at = i
            continue
        if in_section and assign.match(line):
            # 行末コメントは残す
            trailing = ""
            comment = re.search(r"\s+#(?!.*[\"']).*$", line)
            if comment:
                trailing = comment.group(0)
            lines[i] = f"{key} = {value}{trailing}"
            CONFIG.write_text("\n".join(lines) + "\n")
            print(f"config.toml: [{section}] {key} = {value}")
            return

    if section_at is None:
        lines += ["", f"[{section}]", f"{key} = {value}"]
    else:
        lines.insert(section_at + 1, f"{key} = {value}")
    CONFIG.write_text("\n".join(lines) + "\n")
    print(f"config.toml: [{section}] {key} = {value} (追加)")


if __name__ == "__main__":
    main()
