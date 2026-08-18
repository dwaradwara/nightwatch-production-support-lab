FROM python:3.13-slim

ARG OPSFORGE_RELEASE_FAULT_MODE=none

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN if [ "$OPSFORGE_RELEASE_FAULT_MODE" = "ticket-read-api-500" ]; then \
      sed -i '/def get_ticket(ticket_id):/a\    raise RuntimeError("OPSFORGE simulated application ticket-read regression")' app.py; \
    fi

EXPOSE 8000

CMD ["python", "app.py"]
