from datetime import datetime, timezone

from sqlalchemy import Column, DateTime, Integer, Numeric, String, Text

from app.database import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Policy(Base):
    __tablename__ = "policies"

    id = Column(Integer, primary_key=True, autoincrement=True)
    carrier = Column(String, nullable=False)
    cash_surrender_value = Column(Numeric(12, 2), nullable=False)
    status = Column(String, nullable=False, default="active")
    updated_at = Column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, nullable=False
    )


class AuditLog(Base):
    """Append-only trail of every policy create/update.

    Nothing in this codebase updates or deletes a row here, and there is no
    API route that could — that's what "append-only" means in practice.
    """

    __tablename__ = "audit_log"

    id = Column(Integer, primary_key=True, autoincrement=True)
    policy_id = Column(Integer, nullable=False)
    action = Column(String, nullable=False)  # "create" or "update"
    actor = Column(String, nullable=False)
    before = Column(Text, nullable=True)  # JSON snapshot, null on create
    after = Column(Text, nullable=False)  # JSON snapshot
    created_at = Column(DateTime(timezone=True), default=_utcnow, nullable=False)
