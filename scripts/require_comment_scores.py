"""Gives every opinion without stars a score, so that none is left without them.

    python scripts/require_comment_scores.py                    # dry run: what would change
    python scripts/require_comment_scores.py --apply            # stars = the author's rating of the place
    python scripts/require_comment_scores.py --default 5 --apply
        # ...and opinions whose author never rated the place get 5 stars (plus that rating)

Database from .env (remote by default; USE_REMOTE_MONGO=false for the docker compose container).
The app does the first part itself at start; only `--default` needs a decision. Safe to re-run.
"""

import argparse
import asyncio
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))  # allow `python scripts/require_comment_scores.py` from anywhere

from app.config import settings  # noqa: E402
from app.db import create_client  # noqa: E402
from app.repositories import comments  # noqa: E402


async def main(default: int | None, apply: bool) -> None:
    print(f"{'Updating' if apply else 'Dry run on'} {settings.mongo_target()}")
    client = create_client()
    try:
        db = client[settings.mongo_db]
        from_ratings, defaulted = await comments.backfill_scores(db, default=default, dry_run=not apply)
        left = await db[comments.COLLECTION].count_documents({"score": None})
    finally:
        await client.close()
    verb = "set" if apply else "would set"
    print(f"Stars {verb} from the author's rating: {from_ratings}")
    if default is not None:
        print(f"Stars {verb} to {default} (author had no rating): {defaulted}")
    print(f"Opinions without stars {'left' if apply else 'now'}: {left}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--default", type=int, choices=range(1, 6), help="stars for opinions without any rating")
    parser.add_argument("--apply", action="store_true", help="write the changes (default: dry run)")
    args = parser.parse_args()
    asyncio.run(main(args.default, args.apply))
