FROM ghcr.io/berriai/litellm:main-stable

WORKDIR /app

# Install hooks deps. LiteLLM image ships /app/.venv without pip; bootstrap it.
RUN /app/.venv/bin/python -m ensurepip --upgrade \
 && /app/.venv/bin/python -m pip install --no-cache-dir asyncpg

COPY config.yaml /app/config.yaml
COPY proxy_config.py /app/proxy_config.py
COPY entrypoint.sh /usr/local/bin/homeai-entrypoint.sh
RUN chmod +x /usr/local/bin/homeai-entrypoint.sh

ENV PORT=4000

EXPOSE 4000

ENTRYPOINT ["/usr/local/bin/homeai-entrypoint.sh"]
CMD ["--config", "/app/config.yaml", "--host", "0.0.0.0", "--port", "4000"]
