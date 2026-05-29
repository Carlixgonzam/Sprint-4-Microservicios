import json
import os

import pika

EXCHANGE = "cost-analysis"
QUEUE = "report.request"
DLQ = "dlq.failed"


def _params() -> pika.URLParameters:
    url = os.getenv("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")
    return pika.URLParameters(url)


def declare_topology(channel) -> None:
    channel.exchange_declare(exchange=EXCHANGE, exchange_type="topic", durable=True)
    channel.queue_declare(queue=QUEUE, durable=True, arguments={
        "x-dead-letter-exchange": "",
        "x-dead-letter-routing-key": DLQ,
    })
    channel.queue_declare(queue=DLQ, durable=True)
    channel.queue_bind(exchange=EXCHANGE, queue=QUEUE, routing_key=QUEUE)


class ReportQueue:
    def ping(self) -> bool:
        try:
            conn = pika.BlockingConnection(_params())
            try:
                ch = conn.channel()
                declare_topology(ch)
            finally:
                conn.close()
            return True
        except Exception:
            return False

    def publish(self, message: dict) -> None:
        conn = pika.BlockingConnection(_params())
        try:
            ch = conn.channel()
            declare_topology(ch)
            ch.basic_publish(
                exchange=EXCHANGE,
                routing_key=QUEUE,
                body=json.dumps(message, default=str),
                properties=pika.BasicProperties(
                    delivery_mode=2,
                    content_type="application/json",
                ),
            )
        finally:
            conn.close()
