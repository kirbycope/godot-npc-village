#!/usr/bin/env python3
"""Pull the addons named in tools/addons.json into addons/, like an install step.

Each addon's repository is cloned into .addon_cache/ (git-ignored), checked out at the ref the
manifest asks for, and its payload copied into addons/<name>/. The resolved commit of each is
written to tools/addons.lock.json, so what is vendored is always traceable to a commit upstream.

    python tools/pull_addons.py                 every addon in the manifest
    python tools/pull_addons.py controls gta    only these
    python tools/pull_addons.py --dry-run       report what would change, touch nothing
    python tools/pull_addons.py --locked        take the commits in the lock file, not the ref

The addons are committed to this repository, so review the diff and commit as usual afterwards.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

from addon_common import (
    ROOT,
    addon_source,
    load_lock,
    load_manifest,
    mirror,
    run,
    save_lock,
    sync_cache,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Vendor the addons into addons/")
    parser.add_argument("names", nargs="*", help="Only these addons (default: all)")
    parser.add_argument("--dry-run", action="store_true", help="Report, change nothing")
    parser.add_argument(
        "--locked",
        action="store_true",
        help="Check out the commits recorded in tools/addons.lock.json instead of the manifest ref",
    )
    parser.add_argument("--offline", action="store_true", help="Do not fetch, use the cache as is")
    parser.add_argument(
        "--force",
        action="store_true",
        help="Delete local files that are not upstream. Without it, a pull that would remove "
        "anything stops so the work can be pushed first.",
    )
    args = parser.parse_args()

    addons = load_manifest()
    if args.names:
        wanted = set(args.names)
        unknown = wanted - {a["name"] for a in addons}
        if unknown:
            sys.exit(f"Not in the manifest: {', '.join(sorted(unknown))}")
        addons = [a for a in addons if a["name"] in wanted]

    lock = load_lock()
    changed = False
    blocked = False

    print(f"Project:  {ROOT}")
    print(f"Addons:   {len(addons)}")
    print()

    for addon in addons:
        name = addon["name"]
        dest = ROOT / "addons" / name

        try:
            cache = sync_cache(addon, fetch=not args.offline)
        except RuntimeError as exc:
            print(f"{name:<28} FAILED  {exc}")
            continue

        if args.locked and name in lock:
            target = lock[name]["commit"]
        else:
            target = f"origin/{addon['ref']}"

        try:
            run(["git", "checkout", "--quiet", "--force", target], cwd=cache)
        except RuntimeError as exc:
            print(f"{name:<28} FAILED  cannot check out {target}: {exc}")
            continue

        commit = run(["git", "rev-parse", "HEAD"], cwd=cache)
        subject = run(["git", "log", "-1", "--pretty=%s"], cwd=cache)
        previous = lock.get(name, {}).get("commit")

        # Look before touching anything, so a pull that would destroy unpushed work can stop.
        origin = addon_source(cache, name)
        copied, removed = mirror(origin, dest, dry_run=True)

        if removed and not (args.force or args.dry_run):
            print(f"{name:<28} {commit[:7]}  STOPPED: {len(removed)} local file(s) are not upstream")
            for path in removed[:10]:
                print(f"{'':<28}   {path.relative_to(dest)}")
            if len(removed) > 10:
                print(f"{'':<28}   ... and {len(removed) - 10} more")
            print(f"{'':<28} push them first, or re-run with --force to delete them")
            blocked = True
            continue

        if not args.dry_run:
            copied, removed = mirror(origin, dest, dry_run=False)

        if copied or removed:
            changed = True
            verb = "would update" if args.dry_run else "updated"
            print(f"{name:<28} {commit[:7]}  {verb}: {copied} file(s) in, {len(removed)} removed")
            for path in removed[:10]:
                print(f"{'':<28}   removed {path.relative_to(dest)}")
            if len(removed) > 10:
                print(f"{'':<28}   ... and {len(removed) - 10} more removed")
        elif previous != commit:
            changed = True
            print(f"{name:<28} {commit[:7]}  same files, new commit recorded")
        else:
            print(f"{name:<28} {commit[:7]}  up to date")

        if subject:
            print(f"{'':<28} {subject[:70]}")

        if not args.dry_run:
            lock[name] = {
                "repo": addon["repo"],
                "ref": addon["ref"],
                "commit": commit,
                "subject": subject,
                "pulled": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }

    print()

    if args.dry_run:
        print("Dry run, nothing was written.")
        return 0

    save_lock(lock)

    if blocked:
        print("Some addons were left alone because a pull would have deleted local work.")
        print("Send it upstream with tools/push_addons.py, then pull again.")
        return 1

    if not changed:
        print("Everything already matches upstream.")
        return 0

    print("Vendored copies updated. Review and commit:")
    print("  git add addons tools/addons.lock.json")
    print('  git commit -m "Update the vendored addons"')
    return 0


if __name__ == "__main__":
    sys.exit(main())
