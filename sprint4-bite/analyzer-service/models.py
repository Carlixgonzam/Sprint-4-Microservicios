import uuid

from sqlalchemy import Column, DateTime, Enum, ForeignKey, Numeric, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB, UUID

from database import Base


class CostAnalysis(Base):
    __tablename__ = "cost_analysis"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    client_id = Column(String(64), index=True, nullable=False)
    company = Column(String(100), index=True)
    analysis_period_start = Column(DateTime)
    analysis_period_end = Column(DateTime)
    total_cost = Column(Numeric(18, 2), default=0)
    total_cost_optimized = Column(Numeric(18, 2), default=0)
    savings_potential = Column(Numeric(18, 2), default=0)
    recommendations_count = Column(Numeric(10, 0), default=0)
    created_at = Column(DateTime, server_default=func.now())
    analysis_data = Column(JSONB, default=dict)


class Recommendation(Base):
    __tablename__ = "recommendations"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    cost_analysis_id = Column(UUID(as_uuid=True),
                              ForeignKey("cost_analysis.id", ondelete="CASCADE"),
                              index=True, nullable=False)
    resource_id = Column(String(100), index=True)
    recommendation_type = Column(String(50))
    description = Column(Text)
    estimated_savings = Column(Numeric(12, 2), default=0)
    priority = Column(Enum("low", "medium", "high", name="rec_priority"),
                      default="low")
    status = Column(Enum("pending", "implemented", "dismissed", name="rec_status"),
                    default="pending")
    created_at = Column(DateTime, server_default=func.now())
