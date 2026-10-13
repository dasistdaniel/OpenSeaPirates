# Produktions-Image: Elixir-Release, ein Port (4000), kein Reverse Proxy enthalten.
# Build:  docker build -t osp .
# Start:  docker run -p 4200:4000 osp
ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.3.1-debian-trixie-20260202-slim
ARG RUNNER_IMAGE=debian:trixie-slim

# --- Build -------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends git build-essential ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

COPY config/runtime.exs config/
RUN mix release

# --- Laufzeit ------------------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    PORT=4000 \
    MIX_ENV=prod

WORKDIR /app
RUN useradd --system --create-home --shell /usr/sbin/nologin app
COPY --from=build --chown=app:app /app/_build/prod/rel/osp ./
USER app

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1

CMD ["bin/osp", "start"]
