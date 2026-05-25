import os
from pymongo import MongoClient

MONGO_URL = os.getenv("MONGO_URL", "mongodb://localhost:27017")
client = MongoClient(MONGO_URL)
db = client["bite_reports"]

def get_costs_collection():
    return db["cost_reports"]

def get_monthly_collection():
    return db["monthly_summaries"]
