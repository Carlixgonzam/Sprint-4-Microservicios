from sqlalchemy import Column, Integer, String, Float, DateTime, func
from database import Base

class CloudResource(Base):
    __tablename__ = "cloud_resources"

    id = Column(Integer, primary_key=True, index=True)
    company = Column(String(100), index=True)
    project = Column(String(100), index=True)
    provider = Column(String(50))
    resource_type = Column(String(100))
    region = Column(String(50))
    status = Column(String(20))
    cpu_usage = Column(Float, default=0.0)
    memory_gb = Column(Float, default=0.0)
    monthly_cost = Column(Float, default=0.0)
    created_at = Column(DateTime, server_default=func.now())
