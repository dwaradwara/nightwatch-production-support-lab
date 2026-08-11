import pika
import time

credentials = pika.PlainCredentials("nightwatch", "nightwatchpass")

connection = pika.BlockingConnection(
    pika.ConnectionParameters(
        host="nightwatch-rabbit",
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