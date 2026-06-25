# build
FROM elixir:1.19-alpine AS build

WORKDIR /build

RUN apk add --no-cache build-base git \
    && mix local.hex --force \
    && mix local.rebar --force

# フレームワーク（path dep 先）
COPY mix.exs mix.lock ./
COPY lib/ lib/
COPY priv/ priv/

# サイトアプリ
COPY site/mix.exs site/mix.lock ./site/
COPY site/lib/ site/lib/
COPY site/priv/ site/priv/

ENV MIX_ENV=prod
WORKDIR /build/site
RUN mix deps.get --only prod && mix release

# runtime
FROM alpine:3.23 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs

ENV MIX_ENV=prod LANG=C.UTF-8

WORKDIR /app

COPY --from=build /build/site/_build/prod/rel/dialup_site ./

EXPOSE 4001

CMD ["bin/dialup_site", "start"]
