FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
# Idle process so `docker exec` is cheap. Cron triggers responder.py.
CMD ["sleep", "infinity"]
