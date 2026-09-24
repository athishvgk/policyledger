# ---- builder: install Python deps into an isolated virtualenv ----------
# alpine, not slim (debian): as of 2026-09-24 python:3.12-slim (debian
# trixie) carries 44 HIGH CVEs in OS packages debian hasn't patched yet --
# see README's "what broke and how I fixed it". python:3.12-alpine scans
# clean, and every dependency here already ships a musllinux wheel, so
# there's no compiler-toolchain cost to switching.
FROM python:3.12-alpine AS builder

WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- runtime: copy only the venv + source, drop root -------------------
FROM python:3.12-alpine

RUN addgroup -g 1000 appuser \
    && adduser -u 1000 -G appuser -H -D -s /sbin/nologin appuser

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY app ./app

ENV PATH="/opt/venv/bin:$PATH"
USER appuser

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
