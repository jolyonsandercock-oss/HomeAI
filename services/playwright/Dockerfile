FROM mcr.microsoft.com/playwright/python:v1.49.0-noble

# xvfb + x11vnc + fluxbox lets us run a headed Playwright session on a
# virtual display inside the container and expose it over VNC for
# interactive pairing sessions (auth flows that need eyes, e.g. SMS/TOTP).
# Headless production runs reuse the storage_state.json the pairing run saves.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xvfb x11vnc fluxbox \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN chmod +x /app/pair.sh 2>/dev/null || true

EXPOSE 8001 5900
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001", "--log-level", "info"]
