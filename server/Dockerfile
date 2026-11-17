FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    RELAY_HOST=0.0.0.0 \
    RELAY_PORT=51888 \
    RELAY_DB=/srv/data/relay.db \
    TLS_CERT=/srv/tls/relay.crt \
    TLS_KEY=/srv/tls/relay.key \
    UPSTREAM_BASE=https://api.deepseek.com

WORKDIR /srv
COPY app ./app

RUN mkdir -p /srv/data
VOLUME ["/srv/data"]

EXPOSE 51888

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD python -c "import ssl,urllib.request,sys; ctx=ssl._create_unverified_context(); sys.exit(0 if urllib.request.urlopen('https://127.0.0.1:51888/healthz', timeout=3, context=ctx).status == 200 else 1)"

CMD ["python", "-m", "app.main"]
