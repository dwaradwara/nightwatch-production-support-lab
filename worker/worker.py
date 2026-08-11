import pika
import time
import os

credentials = pika.PlainCredentials(
    os.getenv("RABBITMQ_USER", "nightwatch"),
    os.getenv("RABBITMQ_PASSWORD", "")
)

connection = pika.BlockingConnection(
    pika.ConnectionParameters(
        host=os.getenv("RABBITMQ_HOST", "nightwatch-rabbit"),
        credentials=credentials
    )
)

channel = connection.channel()
channel.queue_declare(queue="nightwatch-jobs", durable=True)

print("Nightwatch worker waiting for jobs...")

def process(ch, method, properties, body):
    print(f"Processing: {body.decode()}")
    time.sleep(1)
    ch.basic_ack(delivery_tag=method.delivery_tag)

channel.basic_consume(
    queue="nightwatch-jobs",
    on_message_callback=process
)

channel.start_consuming()