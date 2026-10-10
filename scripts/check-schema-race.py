"""Start several API 'replicas' at the same instant and check none crash.

Each replica runs the API's real startup step (app.main.ensure_schema) against
an empty database, many times over. Before the fix this crashed about 1 start
in 400 with DuplicateTable; after it, never.

It DROPS the public schema of the database it is pointed at, so it refuses
anything but a local throwaway one. Start one with:

    docker run -d --name race-pg -e POSTGRES_USER=race -e POSTGRES_PASSWORD=race \
        -e POSTGRES_DB=race -p 55432:5432 postgres:16-alpine

then run:

    .venv/bin/python scripts/check-schema-race.py [rounds] [replicas]
"""
import os
import sys
import threading
from pathlib import Path

URL = "postgresql+psycopg2://race:race@localhost:55432/race"

if "localhost" not in URL and "127.0.0.1" not in URL:
    sys.exit("refusing to run: this script wipes the database it connects to")

os.environ["DATABASE_URL"] = URL  # must be set before app.database is imported
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sqlalchemy import create_engine, text  # noqa: E402

from app.main import ensure_schema  # noqa: E402


def main() -> int:
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    replicas = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    admin = create_engine(URL, isolation_level="AUTOCOMMIT")
    crashes = 0

    for _ in range(rounds):
        with admin.connect() as conn:
            conn.execute(text("DROP SCHEMA public CASCADE"))
            conn.execute(text("CREATE SCHEMA public"))

        barrier = threading.Barrier(replicas)  # all replicas start together
        errors = []

        def replica():
            engine = create_engine(URL)
            try:
                barrier.wait()
                ensure_schema(engine)
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)
            finally:
                engine.dispose()

        threads = [threading.Thread(target=replica) for _ in range(replicas)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        crashes += len(errors)

    starts = rounds * replicas
    print(f"{crashes} crashes out of {starts} starts ({replicas} replicas x {rounds} rounds)")
    return 1 if crashes else 0


sys.exit(main())
