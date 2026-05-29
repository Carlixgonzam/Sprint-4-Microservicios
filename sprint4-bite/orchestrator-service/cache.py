import json
import os

import redis


class ReportCache:
    def __init__(self):
        url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
        self.client = redis.from_url(url, decode_responses=True)

    def ping(self) -> bool:
        try:
            return bool(self.client.ping())
        except Exception:
            return False

    def get(self, key: str):
        v = self.client.get(key)
        return json.loads(v) if v else None

    def set(self, key: str, value, ttl: int) -> None:
        self.client.set(key, json.dumps(value, default=str), ex=ttl)

    def delete(self, key: str) -> None:
        self.client.delete(key)
