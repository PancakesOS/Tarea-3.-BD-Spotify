FROM python:3.13-slim

RUN apt-get update && apt-get install -y --no-install-recommends cron && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --locked

COPY app_simulator/ app_simulator/
COPY ingestion/ ingestion/

RUN crontab ingestion/crontab
