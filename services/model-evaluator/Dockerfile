FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py benchmark_tasks.py qwen_prompts.py run_benchmark.py qwen_optimize.py ./
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8008"]
