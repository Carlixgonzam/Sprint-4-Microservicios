import os

from pymongo import ASCENDING, DESCENDING, MongoClient

MONGO_URL = os.getenv("MONGO_URL", "mongodb://localhost:27017")
client = MongoClient(MONGO_URL)
db = client["bite_reports"]


def get_metrics_collection():
    return db["time_series_metrics"]


def ensure_indexes() -> None:
    col = get_metrics_collection()
    col.create_index(
        [("client_id", ASCENDING), ("resource_id", ASCENDING),
         ("metric_name", ASCENDING), ("timestamp", DESCENDING)],
        name="ix_client_resource_metric_ts",
    )
    col.create_index([("timestamp", DESCENDING)], name="ix_timestamp")
