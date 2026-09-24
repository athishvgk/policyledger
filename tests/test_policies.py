from sqlalchemy.orm import sessionmaker

from app.models import AuditLog


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_create_policy_returns_201_and_writes_audit_row(client, db_engine):
    response = client.post(
        "/policies",
        json={"carrier": "Meridian Mutual", "cash_surrender_value": "12500.50"},
        headers={"X-Actor": "test-user"},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["carrier"] == "Meridian Mutual"
    assert body["status"] == "active"
    assert body["id"] is not None

    session = sessionmaker(bind=db_engine)()
    rows = session.query(AuditLog).all()
    session.close()
    assert len(rows) == 1
    assert rows[0].action == "create"
    assert rows[0].actor == "test-user"
    assert rows[0].before is None


def test_list_policies_returns_created_policy(client):
    client.post("/policies", json={"carrier": "Northbridge Life", "cash_surrender_value": "8000.00"})
    response = client.get("/policies")
    assert response.status_code == 200
    assert len(response.json()) == 1
    assert response.json()[0]["carrier"] == "Northbridge Life"


def test_patch_updates_policy_and_appends_second_audit_row(client, db_engine):
    create = client.post(
        "/policies", json={"carrier": "Harborview Assurance", "cash_surrender_value": "5000.00"}
    )
    policy_id = create.json()["id"]

    response = client.patch(f"/policies/{policy_id}", json={"status": "surrendered"})
    assert response.status_code == 200
    assert response.json()["status"] == "surrendered"
    assert response.json()["carrier"] == "Harborview Assurance"  # untouched field kept

    session = sessionmaker(bind=db_engine)()
    rows = session.query(AuditLog).filter_by(policy_id=policy_id).order_by(AuditLog.id).all()
    session.close()
    assert len(rows) == 2
    assert rows[1].action == "update"
    assert "surrendered" in rows[1].after
    assert "active" in rows[1].before  # captured the pre-update state


def test_patch_missing_policy_returns_404(client):
    response = client.patch("/policies/999", json={"status": "surrendered"})
    assert response.status_code == 404
