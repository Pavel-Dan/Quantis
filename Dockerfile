# Quantis - Cloud Run Job Image
# Calcule les KPIs financiers depuis GCS et charge dans BigQuery

FROM python:3.11-slim

WORKDIR /app

# Dépendances système minimales
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV PYTHONPATH=/app \
    PYTHONUNBUFFERED=1

CMD ["python", "main.py"]
