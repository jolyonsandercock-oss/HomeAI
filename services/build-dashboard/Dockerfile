FROM python:3.11-slim

# F4: no Docker CLI / socket here. The benchmark is run by model-evaluator in
# its own container and relayed over HTTP (/api/benchmark/stream), so this
# web-facing container has zero Docker access.

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY static/ ./static/
COPY data/   ./data/

ENV PYTHONUNBUFFERED=1
EXPOSE 8090

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8090"]
