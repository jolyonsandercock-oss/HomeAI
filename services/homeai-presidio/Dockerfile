FROM python:3.11-slim

WORKDIR /app

# Install build deps (kept slim — most of what Presidio needs is pure Python)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      curl \
      && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Download spaCy model. en_core_web_lg is ~700MB but yields markedly better
# UK-name recognition than _sm. If you need to slim the image, swap to _sm
# and accept lower recall on names that the regex recognisers miss.
RUN python -m spacy download en_core_web_lg

COPY main.py recognizers.py ./

ENV PORT=8765

# Health check: /healthcheck must return 200 within 5s
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -sf http://localhost:${PORT}/healthcheck || exit 1

EXPOSE 8765

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8765"]
