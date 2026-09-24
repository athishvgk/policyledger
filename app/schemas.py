from datetime import datetime
from decimal import Decimal
from typing import Optional

from pydantic import BaseModel, ConfigDict


class PolicyCreate(BaseModel):
    carrier: str
    cash_surrender_value: Decimal
    status: str = "active"


class PolicyUpdate(BaseModel):
    """All fields optional: PATCH only touches what's sent."""

    carrier: Optional[str] = None
    cash_surrender_value: Optional[Decimal] = None
    status: Optional[str] = None


class PolicyOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    carrier: str
    cash_surrender_value: Decimal
    status: str
    updated_at: datetime
