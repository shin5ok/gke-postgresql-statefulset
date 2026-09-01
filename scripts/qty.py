#!/usr/bin/env python3
"""Kubernetes のリソース量 (20Gi, 100G ...) を 2 つ比較する。

  qty.py <current> <desired>  ->  grow | shrink | same
"""
import re
import sys

SUFFIXES = {
    "": 1,
    "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12, "P": 10**15, "E": 10**18,
    "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "Pi": 2**50, "Ei": 2**60,
}
PATTERN = re.compile(r"^(\d+(?:\.\d+)?)([EPTGMK]i?|)$")


def parse(text: str) -> float:
    match = PATTERN.match(text.strip())
    if not match:
        print(f"qty error: 解釈できない値です: {text!r}", file=sys.stderr)
        sys.exit(1)
    return float(match.group(1)) * SUFFIXES[match.group(2)]


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: qty.py <current> <desired>", file=sys.stderr)
        sys.exit(2)
    current, desired = parse(sys.argv[1]), parse(sys.argv[2])
    print("same" if current == desired else ("grow" if desired > current else "shrink"))


if __name__ == "__main__":
    main()
