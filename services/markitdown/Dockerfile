FROM python:3.11-slim

# MarkItDown needs ffmpeg for audio/video, libreoffice not strictly needed
# for typical invoice attachments. Slim install: just pip deps.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV PYTHONUNBUFFERED=1
EXPOSE 8004

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8004"]
