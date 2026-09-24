"""Populates a running PolicyLedger API with fake policies.

Run this after `docker compose up` so there's something to look at in
`GET /policies`. It only talks to the HTTP API — same as any other client —
so it never touches Postgres directly.
"""

import random

import requests

API_URL = "http://localhost:8000"

CARRIERS = [
    "Meridian Mutual",
    "Northbridge Life",
    "Harborview Assurance",
    "Cascade Life & Annuity",
    "Ridgeline Financial",
]

STATUSES = ["active", "lapsed", "surrendered"]


def seed(count: int = 15) -> None:
    for _ in range(count):
        payload = {
            "carrier": random.choice(CARRIERS),
            "cash_surrender_value": str(round(random.uniform(5_000, 250_000), 2)),
            "status": random.choice(STATUSES),
        }
        response = requests.post(
            f"{API_URL}/policies", json=payload, headers={"X-Actor": "seed-script"}
        )
        response.raise_for_status()
    print(f"seeded {count} fake policies")


if __name__ == "__main__":
    seed()
