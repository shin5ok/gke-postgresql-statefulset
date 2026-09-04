# サンプルアプリのイメージ。make app-image が Cloud Build (または手元の docker) でビルドする。
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py ./
COPY templates ./templates

# root では動かさない (GKE Autopilot のセキュリティ既定にも合わせる)。
# gunicorn はホームディレクトリ配下に制御用ソケットを作るので、ホームは必要。
RUN useradd --uid 1000 --user-group --create-home app
USER 1000

EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", \
     "--access-logfile", "-", "main:app"]
