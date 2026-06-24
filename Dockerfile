FROM elixir:1.19-alpine

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
RUN mix deps.get --only prod && mix compile

# ランタイム: site/mix.exs の path: ".." が /build を指すよう同じレイアウトを維持
WORKDIR /build/site

EXPOSE 4001

CMD ["mix", "run", "--no-halt"]
