"""Merge disjoint manual catalog edits; fail on conflicting keys without writing output."""

import argparse
import json
from pathlib import Path


def merge(left, right):
    if left["sourceLanguage"] != right["sourceLanguage"]:
        raise ValueError("Catalog source languages differ")
    strings = dict(left["strings"])
    for key, entry in right["strings"].items():
        if key in strings and strings[key] != entry:
            raise ValueError(f"Conflicting catalog key: {key}")
        strings[key] = entry
    return {**left, "strings": dict(sorted(strings.items()))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("left", type=Path)
    parser.add_argument("right", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = merge(json.loads(args.left.read_text()), json.loads(args.right.read_text()))
    except ValueError as exc:
        parser.error(str(exc))
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
