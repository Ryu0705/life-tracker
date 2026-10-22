# migration の確かめ用の Postgres（本番と同じ 17 系）に plpgsql_check を入れたもの。run.sh が初回だけ作る
FROM postgres:17
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-plpgsql-check \
 && rm -rf /var/lib/apt/lists/*
