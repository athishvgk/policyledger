import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

import app.main as main_module
from app.database import Base, get_db
from app.main import app

# SQLite in-memory instead of Postgres so tests don't need Docker running.
# StaticPool keeps a single connection alive for the whole test so the
# in-memory DB isn't thrown away between queries.
TEST_DATABASE_URL = "sqlite:///:memory:"


@pytest.fixture()
def db_engine():
    engine = create_engine(
        TEST_DATABASE_URL,
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    yield engine


@pytest.fixture()
def client(db_engine, monkeypatch):
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=db_engine)

    def override_get_db():
        db = TestingSessionLocal()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    # The startup hook calls Base.metadata.create_all(bind=engine) using
    # app.main's module-level `engine` — point it at the test engine too,
    # or it would try to create tables on the real Postgres URL.
    monkeypatch.setattr(main_module, "engine", db_engine)

    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()
