FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY Config.yaml .
COPY handler.py sqs_worker.py job_status_store.py ./
COPY helpers/ ./helpers/

CMD ["python", "sqs_worker.py"]
