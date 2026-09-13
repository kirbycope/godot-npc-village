#!/usr/bin/env python3
"""Survey a tree of third-party assets and report what is worth importing.

    python tools/inventory_assets.py <directory> [--top 40] [--json out.json]

A general asset library runs to gigabytes, and importing it wholesale into a Godot
project is a bad trade: every model is reimported on open, the repository swells, and
most of it is never placed in a scene. This walks the tree without Godot, groups files
into packs, and reports what each pack actually contains, so a handful can be chosen and
copied in rather than all of it.

Nothing is copied or modified. The output is a report.

Rigged and animated glTF files are flagged by reading the glTF header directly, because
that is the single most useful thing to know about a character pack before importing it:
a pack with skins and animations can drive an NPC, and one without is scenery.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import defaultdict
from pathlib import Path

MODEL_SUFFIXES = {".glb", ".gltf", ".fbx", ".obj", ".blend", ".dae"}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".tga", ".bmp", ".webp"}
AUDIO_SUFFIXES = {".ogg", ".wav", ".mp3", ".flac"}

# Godot imports .glb and .gltf directly; the rest need converting first.
GODOT_READY = {".glb", ".gltf"}


def human(size: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024.0 or unit == "TB":
            return f"{size:,.0f} {unit}" if unit == "B" else f"{size:,.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} TB"


def read_glb_json(path: Path) -> dict | None:
    """The JSON chunk of a binary glTF, or None if it cannot be read as one."""
    try:
        with path.open("rb") as handle:
            header = handle.read(12)
            if len(header) < 12 or header[:4] != b"glTF":
                return None
            chunk_header = handle.read(8)
            if len(chunk_header) < 8:
                return None
            length, kind = struct.unpack("<II", chunk_header)
            if kind != 0x4E4F534A:  # 'JSON'
                return None
            return json.loads(handle.read(length).decode("utf-8", "replace"))
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def describe_model(path: Path) -> dict:
    """What a glTF contains: whether it is skinned, and how many animations it has."""
    facts = {"skinned": False, "animations": 0, "meshes": 0, "readable": False}
    document = None
    if path.suffix.lower() == ".glb":
        document = read_glb_json(path)
    elif path.suffix.lower() == ".gltf":
        try:
            document = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError):
            document = None
    if document is None:
        return facts
    facts["readable"] = True
    facts["skinned"] = bool(document.get("skins"))
    facts["animations"] = len(document.get("animations", []))
    facts["meshes"] = len(document.get("meshes", []))
    return facts


def pack_of(root: Path, path: Path) -> str:
    """The top one or two directories under the root, used as the pack name."""
    parts = path.relative_to(root).parts
    if len(parts) <= 1:
        return "(loose files)"
    if len(parts) == 2:
        return parts[0]
    return "/".join(parts[:2])


def main() -> int:
    parser = argparse.ArgumentParser(description="Survey an asset tree")
    parser.add_argument("directory", help="Directory to walk")
    parser.add_argument("--top", type=int, default=40, help="Packs to list (default 40)")
    parser.add_argument("--json", dest="json_out", help="Also write the report as JSON")
    parser.add_argument(
        "--sample-models",
        type=int,
        default=400,
        help="glTF files to open per pack when checking for rigs (default 400)",
    )
    args = parser.parse_args()

    root = Path(args.directory).expanduser().resolve()
    if not root.is_dir():
        sys.exit(f"Not a directory: {root}")

    packs: dict[str, dict] = defaultdict(
        lambda: {
            "bytes": 0,
            "models": 0,
            "godot_ready": 0,
            "images": 0,
            "audio": 0,
            "other": 0,
            "skinned": 0,
            "animated": 0,
            "inspected": 0,
            "licenses": set(),
            "suffixes": defaultdict(int),
        }
    )

    for path in root.rglob("*"):
        if not path.is_file():
            continue
        try:
            size = path.stat().st_size
        except OSError:
            continue
        suffix = path.suffix.lower()
        entry = packs[pack_of(root, path)]
        entry["bytes"] += size
        entry["suffixes"][suffix] += 1

        if "licen" in path.name.lower() or "readme" in path.name.lower():
            entry["licenses"].add(str(path.relative_to(root)))

        if suffix in MODEL_SUFFIXES:
            entry["models"] += 1
            if suffix in GODOT_READY:
                entry["godot_ready"] += 1
                if entry["inspected"] < args.sample_models:
                    entry["inspected"] += 1
                    facts = describe_model(path)
                    if facts["skinned"]:
                        entry["skinned"] += 1
                    if facts["animations"]:
                        entry["animated"] += 1
        elif suffix in IMAGE_SUFFIXES:
            entry["images"] += 1
        elif suffix in AUDIO_SUFFIXES:
            entry["audio"] += 1
        else:
            entry["other"] += 1

    if not packs:
        print(f"Nothing found under {root}")
        return 0

    total_bytes = sum(entry["bytes"] for entry in packs.values())
    total_models = sum(entry["models"] for entry in packs.values())
    print(f"\n{root}")
    print(f"{len(packs)} packs, {total_models:,} models, {human(total_bytes)} total\n")

    header = f"{'pack':<44}{'size':>10}{'models':>8}{'glb':>7}{'rigged':>8}{'anim':>6}"
    print(header)
    print("-" * len(header))

    ordered = sorted(packs.items(), key=lambda item: item[1]["bytes"], reverse=True)
    for name, entry in ordered[: args.top]:
        print(
            f"{name[:43]:<44}{human(entry['bytes']):>10}{entry['models']:>8}"
            f"{entry['godot_ready']:>7}{entry['skinned']:>8}{entry['animated']:>6}"
        )
    if len(ordered) > args.top:
        print(f"... and {len(ordered) - args.top} more packs")

    # The packs that can drive a villager are the ones this project is short of.
    characters = [
        (name, entry)
        for name, entry in ordered
        if entry["skinned"] > 0
    ]
    if characters:
        print("\nPacks containing rigged characters (candidates for villagers):")
        for name, entry in characters[:20]:
            print(
                f"  {name:<44} {entry['skinned']} rigged, "
                f"{entry['animated']} with animations, of {entry['inspected']} inspected"
            )
    else:
        print("\nNo rigged characters found; everything here is scenery.")

    missing = [name for name, entry in ordered if not entry["licenses"]]
    if missing:
        print(f"\n{len(missing)} packs carry no licence or readme file. Attribution")
        print("has to come from the original download page for these before shipping.")

    if args.json_out:
        serialisable = {
            name: {
                key: (sorted(value) if isinstance(value, set) else dict(value)
                      if isinstance(value, defaultdict) else value)
                for key, value in entry.items()
            }
            for name, entry in packs.items()
        }
        Path(args.json_out).write_text(json.dumps(serialisable, indent=2), encoding="utf-8")
        print(f"\nWrote {args.json_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
