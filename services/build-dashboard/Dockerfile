FROM python:3.11-slim

# docker CLI so /api/benchmark/stream can shell out to `docker exec` the
# benchmark runner. Pull the static binary directly from docker.com — the
# Debian docker.io package on Trixie only ships server bits, not the
# client. ~70MB extracted.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-26.1.4.tgz \
       | tar -xz -C /tmp \
    && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY static/ ./static/
COPY data/   ./data/

ENV PYTHONUNBUFFERED=1
EXPOSE 8090

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8090"]
