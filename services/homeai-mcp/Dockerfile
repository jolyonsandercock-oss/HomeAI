FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
# HTTP mode by default (sse mount) — claude-code can also spawn stdio mode
# via `MCP_TRANSPORT=stdio` env override.
EXPOSE 8765
CMD ["python", "-u", "server.py"]
