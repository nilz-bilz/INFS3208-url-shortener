# Shortener image: authentication, link management and QR codes.
# Author: Nihal Singh Atwal (student ID 49299175, nihalsingh.atwal@student.uq.edu.au)
# AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
FROM docker.io/library/python:3.12-slim
# Build-time version, baked in so the X-App-Version header matches the image tag
ARG APP_VERSION=v1
ENV APP_VERSION=${APP_VERSION} PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
# Run as a non-root user
RUN useradd -r -u 1000 app
USER 1000
EXPOSE 8000
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:8000", "app:app"]
