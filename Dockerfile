# GmapsEx — production Docker image.
#
# Builds a release with all the pure-HTTP scraper machinery. No browser, no
# Chromium — keeps the image under 100 MB.
#
# Usage:
#   docker build -t gmaps_ex .
#   docker run --rm \
#     -e DATABASE_URL="ecto://postgres:postgres@host.docker.internal/gmaps_ex" \
#     -e GMAPS_PROXIES="" \
#     -v "$PWD/queries.txt:/app/queries.txt:ro" \
#     -v "$PWD/out:/app/out" \
#     gmaps_ex \
#     bin/gmaps_ex eval "
#       GmapsEx.Runner.start([%{
#         query: 'coffee shops', lat: 30.78, lon: 30.99,
#         zoom: 13, lang: 'ar', gl: 'eg'
#       }])
#     "
#
# For local CLI use, install Elixir natively and use `mix gmaps.scrape` instead.

FROM hexpm/elixir:1.18.4-erlang-27.2-alpine-3.21.0 AS build

ENV MIX_ENV=prod

RUN apk add --no-cache build-base git

WORKDIR /app

# Copy mix files first for better layer caching
COPY mix.exs mix.lock ./
COPY config config

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod && \
    mix deps.compile

# Now copy sources
COPY lib lib
COPY priv priv

RUN mix compile

# Build release
RUN mix release

# Runtime image
FROM alpine:3.21.0

RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates

WORKDIR /app

COPY --from=build /app/_build/prod/rel/gmaps_ex ./

ENV HOME=/app

# Healthcheck assumes you've got an Ecto-connected app
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bin/gmaps_ex rpc "GmapsEx.Repo.query!('SELECT 1')" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["bin/gmaps_ex"]
CMD ["start"]
