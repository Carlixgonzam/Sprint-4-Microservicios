import json
import logging
import os
import time

import httpx
import pika

from broker import QUEUE, declare_topology, _params

logger = logging.getLogger("orchestrator.worker")

INVENTORY_URL = os.getenv("INVENTORY_URL", "http://localhost:8001")
COLLECTOR_URL = os.getenv("COLLECTOR_URL", "http://localhost:8005")
ANALYZER_URL = os.getenv("ANALYZER_URL", "http://localhost:8006")
NOTIF_URL = os.getenv("NOTIF_URL", "http://localhost:8003")


def run(cache) -> None:
    """Run the worker loop forever — restarts on connection errors."""
    while True:
        try:
            _consume_forever(cache)
        except Exception as e:
            logger.error("Worker crashed, restarting in 5s: %s", e)
            time.sleep(5)


def _consume_forever(cache) -> None:
    conn = pika.BlockingConnection(_params())
    try:
        ch = conn.channel()
        declare_topology(ch)
        ch.basic_qos(prefetch_count=1)

        def on_message(channel, method, properties, body):
            try:
                msg = json.loads(body)
                _process(msg, cache)
                channel.basic_ack(delivery_tag=method.delivery_tag)
            except Exception as e:
                logger.error("Failed to process message: %s", e)
                channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)

        ch.basic_consume(queue=QUEUE, on_message_callback=on_message)
        logger.info("Worker consuming from %s", QUEUE)
        ch.start_consuming()
    finally:
        try:
            conn.close()
        except Exception:
            pass


def _process(msg: dict, cache) -> None:
    report_id = msg["report_id"]
    client_id = msg["client_id"]
    data = msg.get("data", {})
    company = data.get("company")
    ttl = msg.get("ttl", 3600)

    start = time.time()
    with httpx.Client(timeout=30.0) as http:
        inv_params = {"company": company} if company else {}
        inv = http.get(f"{INVENTORY_URL}/resources", params=inv_params).json()

        collector_payload = {
            "client_id": client_id,
            "resources": [
                {
                    "resource_id": r.get("id"),
                    "company": r.get("company"),
                    "project": r.get("project"),
                    "provider": r.get("provider"),
                }
                for r in inv.get("resources", [])[:200]
            ],
        }
        metrics = http.post(f"{COLLECTOR_URL}/collect", json=collector_payload).json()

        analyzer_payload = {
            "client_id": client_id,
            "company": company,
            "resources": inv.get("resources", []),
            "metrics_summary": {
                "total_metrics": metrics.get("total_metrics"),
                "resources_observed": metrics.get("resources_observed"),
            },
        }
        analysis = http.post(f"{ANALYZER_URL}/analyze", json=analyzer_payload).json()

    elapsed = (time.time() - start) * 1000
    report = {
        "report_id": report_id,
        "client_id": client_id,
        "status": "ready",
        "report_type": data.get("report_type"),
        "period": data.get("period"),
        "inventory_summary": {
            "total": inv.get("total"),
            "underutilized_count": inv.get("underutilized_count"),
        },
        "metrics_summary": {
            "total_metrics": metrics.get("total_metrics"),
            "resources_observed": metrics.get("resources_observed"),
        },
        "analysis": analysis,
        "elapsed_ms": round(elapsed, 2),
        "generated_at": time.time(),
    }

    composite_key = f"report:{client_id}:{data.get('report_type')}:{data.get('period')}"
    cache.set(composite_key, report, ttl=ttl)
    cache.set(f"report:id:{report_id}", report, ttl=ttl)
    cache.delete(f"report:status:{report_id}")

    try:
        with httpx.Client(timeout=5.0) as http:
            http.post(f"{NOTIF_URL}/jobs", json={
                "job_id": report_id,
                "email": f"{client_id}@bite.co",
                "company": company or "ALL",
                "project": data.get("report_type", "report"),
            })
    except Exception as e:
        logger.warning("Failed to notify: %s", e)
