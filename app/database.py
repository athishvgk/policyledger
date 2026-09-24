import os

from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

# In docker-compose / Kubernetes this is overridden to point at the Postgres
# service; the fallback here is only so the file has something sane to show.
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg2://policyledger:policyledger@localhost:5432/policyledger",
)

engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    """FastAPI dependency: one DB session per request, always closed after."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
