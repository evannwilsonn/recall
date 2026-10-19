# Recall as one container: a Phoenix release with the fitted grader and MiniLM's weights inside.
#   build  compiles the app (EXLA brings its compiled XLA library), builds the CSS and JS,
#          downloads MiniLM once, and assembles the release
#   run    Debian slim with only what the release needs, as a non-root user on port 7860
#          (the port and uid Hugging Face Spaces expects). GROQ_API_KEY comes from the
#          Space's secrets at run time; without it Recall writes cards from the notes alone.
FROM elixir:1.18-otp-27 AS build
WORKDIR /app
ENV MIX_ENV=prod BUMBLEBEE_CACHE_DIR=/app/bumblebee
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
RUN mix compile && mix assets.deploy

# Fetch MiniLM's weights and tokenizer now, so the running app never needs the network.
RUN mix run --no-start -e 'Application.ensure_all_started(:bumblebee); {:ok, _} = Bumblebee.load_model({:hf, "sentence-transformers/all-MiniLM-L6-v2"}); {:ok, _} = Bumblebee.load_tokenizer({:hf, "sentence-transformers/all-MiniLM-L6-v2"})'

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM debian:bookworm-slim AS run
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
RUN useradd --create-home --uid 1000 recall
WORKDIR /app
COPY --from=build --chown=recall /app/_build/prod/rel/recall ./
COPY --from=build --chown=recall /app/bumblebee ./bumblebee
USER recall
ENV MIX_ENV=prod PHX_SERVER=true PORT=7860 BUMBLEBEE_CACHE_DIR=/app/bumblebee BUMBLEBEE_OFFLINE=true
EXPOSE 7860
CMD ["/app/bin/server"]
