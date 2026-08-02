# The prompt behind this project

This file is the spec that generated everything in this repo. Keep it at the
project root — if you ever want to regenerate this from scratch (a newer
model, a different tool, six months from now), this is what to hand it.

It's been refined more than once: an archived dependency, a CI/Go version
mismatch, a Postgres major-version breaking change, and a renamed function
whose call sites never got updated were all caught during verification
passes. The instructions below have those lessons folded in, so a fresh
regeneration shouldn't repeat any of them.

---

## How to use this

Paste everything in the box below into a capable coding assistant. Two things
matter more than the prompt itself:

1. **Ask it to verify versions with a live search, not from memory.**
   Model training data goes stale; package registries don't wait for it.
2. **Ask it to check whether each pinned dependency is still maintained**,
   not just whether a version number exists. A project can have a "latest"
   tag on an abandoned image — version currency and maintenance status are
   two different questions, and only the second one tells you if you're
   about to build on something that gets security patches.

---

## The prompt

```
Build me a small but real multi-service weather app, fully containerized with
Docker Compose. I want to learn the stack by running it, not by reading about
it — so it has to actually work end to end with real data, not mocks.

Scaffolding:
- One pure-bash script, generate.sh, that creates the entire project tree
  (folders, Dockerfiles, configs, code) when I run it.
- The application code itself must be 100% Go. No Python, no Node, anywhere.
- A single Go binary with a MODE env var (store / api / consumer) selecting
  which role it plays — not three separate codebases. Share common helpers
  (env var reading with defaults, duration parsing) in one file.
- Include a basic Go unit test so `go test` has something real to run in CI.

Version policy — read this before picking any image or dependency:
- For every image and every Go dependency, look up today's current stable
  version with a live search and pin it explicitly (e.g. postgres:18.4-alpine,
  not postgres:latest and not a version pulled from memory). No floating
  "latest" tags anywhere — I want a reproducible build.
- For each one, also check whether the project is still actively maintained
  — not just "does this version exist." If a commonly-used image or library
  has been archived, deprecated, or superseded by a community fork, use the
  maintained one instead and tell me about the switch and why.
- For any image whose pinned version crosses a major version boundary from
  what's commonly documented (e.g. Postgres 17 → 18), check that version's
  release notes for breaking changes to defaults, file layout, volume mount
  paths, or config format — not just that the tag resolves. A tag existing
  on the registry says nothing about whether anything structural changed
  underneath it. This is what actually breaks a first run, more often than
  a wrong version number does.
- Cross-check that versions you pick are mutually compatible — in particular,
  make sure any CI config (e.g. a GitHub Actions setup-go step) uses the same
  language version as go.mod. A CI runner on an older toolchain than the
  module requires will fail on the very first run.

Services (9 total) — give me exact ports and named volumes, not just names:
- postgres (current stable, alpine variant) — durable storage, named volume
  for data (pgdata)
- rabbitmq (current stable, management variant) — message queue, management
  UI on :15672
- redis (current stable, alpine variant) — cache of the latest reading per city
- weather-store (Go, built locally) — gRPC server on :9090, health/metrics
  plus /cities REST (GET/POST) on :9091, only service touching Postgres/Redis
- weather-api (Go, built locally) — fetch loop + public HTTP on :8080
  (/healthz, /metrics, /readings/latest, /cities, and "/" serving the UI
  described below)
- weather-consumer (Go, built locally) — drains the queue, writes via store's
  gRPC, no exposed ports
- caddy (current stable, alpine variant) — reverse proxy on :443/:80,
  automatic HTTPS
- prom/prometheus (current stable) — scrapes app metrics, UI on :9090
- grafana/grafana (current stable) — dashboards, auto-provisioned on first
  boot, UI on :3000

Data flow:
- api fetches current weather per city from the free Open-Meteo API (no key
  required) on a timer (FETCH_INTERVAL env var)
- api publishes each reading as JSON to a RabbitMQ queue (QUEUE env var)
- consumer drains the queue and calls store over gRPC (STORE_ADDR) to persist it
- store writes to Postgres, refreshes a Redis cache key (latest:<city>) with a
  configurable TTL (CACHE_TTL)
- api also reads back through store via gRPC for GET /readings/latest?city=X
- Only store may import the Postgres/Redis client libraries — api and
  consumer reach data exclusively through store's gRPC interface
- Both store and consumer retry their connections on startup (~30 attempts,
  short backoff) instead of crash-looping if Postgres/Redis/RabbitMQ aren't
  ready yet — Compose starts containers in parallel

Contract & schema:
- Define the gRPC contract in a .proto file: a Reading message (city,
  latitude, longitude, temperature_c, windspeed_kph, observed_at, source) and
  a WeatherStore service with AddReading and GetLatest RPCs
- Define the Postgres schema in db/init.sql: weather_readings table with an
  index on (city, observed_at DESC), plus a cities table (name unique,
  latitude, longitude) for the UI described below
- protoc and the Go build happen inside a multi-stage Docker build — nothing
  but Docker + Docker Compose needed locally
- Pin Go and all module dependencies to their current stable releases in
  go.mod (grpc, protobuf, a Postgres driver, go-redis, an amqp client,
  prometheus client) — check each one, don't assume

Web UI for managing cities:
- A dark-themed single page served at weather-api's "/" - a search box with
  live autocomplete over the currently tracked cities
- Typing a name that doesn't match anything tracked yet shows an inline
  "+ Add" option instead of nothing
- Adding a city: resolve the name to coordinates via Open-Meteo's free
  geocoding API (no key required), persist it, then fetch and store its
  temperature immediately - don't make the user wait for the next scheduled
  FETCH_INTERVAL cycle just to see the city they just added
- The city list must always be read from Postgres, never from the CITIES env
  var after the very first boot. CITIES only ever seeds the table once, on
  an empty database - after that, the database is the single source of
  truth, including for whatever in-memory cache api keeps for its own fetch
  loop. If a "quick refresh" cache is used, it must be refreshed by reading
  the database again, not by hand-patching the cache's contents in code
- Keep this on weather-store's existing small REST surface (the same :9091
  that already serves /healthz and /metrics) rather than adding a new
  service or exposing a new port - store is still the only thing that
  touches Postgres directly

Configuration:
- Every tunable is an env var with a sane default: MODE, FETCH_INTERVAL,
  CITIES (Name:lat:lon, comma-separated, skip malformed entries), QUEUE,
  API_PORT, STORE_ADDR, STORE_HTTP_ADDR, CACHE_TTL, REDIS_ADDR, Postgres
  connection vars, RabbitMQ credentials, AMQP host/port
- .env with working defaults, .env.example as a template, .gitignore
  excluding .env

Observability:
- Real Prometheus metrics: counters for readings published/stored, gauges for
  temperature and windspeed per city
- Grafana auto-provisions its Prometheus data source and one starter
  dashboard on first boot

Deploy/ops:
- Makefile with make up / make logs
- Docker healthchecks on postgres/redis/rabbitmq, depends_on with
  condition: service_healthy
- GitHub Actions: go vet + go test, build and push to GHCR (commit SHA tag,
  plus latest as a convenience alias only)
- No auto-deploy service watching the registry in the background - deploy is
  a deliberate, manual `docker compose up -d --build` when I actually want
  the new image. Don't add anything that recreates containers on its own;
  I need to know exactly when and why something restarts, not have it
  happen silently in the background
- Explain which credentials I actually type at any point vs. what's automatic

Be upfront about rough edges — auto-ack in the consumer, plaintext gRPC inside
the network, cache staleness window — instead of smoothing them over.

Deliverable: a zip of the generated project, plus a short written doc with a
service/port/version table, a data-flow diagram, a CI/CD diagram, and a
hands-on section for poking at each tool. Include this prompt itself in the
project as PROMPT.md, so the spec travels with the code.
```

---

## What changed from the first draft, and why

- **"Latest stable" became "look it up live, don't recall it."** Model
  training data has a cutoff; package versions don't. This is the single
  highest-leverage line in the whole prompt.
- **Added a maintenance check, separate from a version check.** This is what
  would have caught the archived-Watchtower issue on the first pass instead
  of the second. A tag existing on a registry says nothing about whether
  anyone is still patching it.
- **Added an explicit cross-compatibility check** (CI Go version vs. go.mod)
  — the kind of mismatch that's invisible until the pipeline actually runs,
  and cheap to ask for upfront.
- **Added a breaking-change check, separate from both of the above.** This
  is the one that actually bit first: Postgres 18 silently changed its
  expected volume mount path from what every pre-18 tutorial uses. The tag
  existed, the image was maintained — and it still broke `make up` on the
  very first run, because nothing checked for a structural change between
  major versions. Version-exists, still-maintained, and no-breaking-changes
  are three separate questions; this prompt now asks all three instead of
  stopping after the first two.
- **Asked for the prompt to be embedded in its own output.** A generated
  project is easiest to trust, audit, and regenerate later when the spec
  that made it ships alongside the code, not just in a chat log.
- **Added a same-package consistency check as a required verification step,
  not just a style check.** A function got renamed at its definition during
  a later edit, but three call sites still used the old name — gofmt and a
  raw-string/backtick check both passed cleanly, because neither one checks
  whether an identifier actually exists. That's a different, cheaper check
  than a full build (which needs network access to a module proxy this
  project may not always have): parse the source and confirm every
  same-package function call resolves to something actually defined.
  Syntax-valid and semantically-consistent are two different guarantees;
  this prompt now asks for both instead of assuming the first implies the
  second.
- **Dropped the auto-redeploy service entirely, after using it for a
  while.** It recreates containers outside `docker compose`'s own
  bookkeeping — when that happens mid-update (e.g. a VPN connection
  dropping partway through a pull, relevant on a sanctioned network), the
  container can end up removed but never recreated, orphaned from
  Compose's view of the project, causing confusing "name already in use"
  errors on the next `docker compose up` that a plain `down` can't clean up
  either. Not worth the tradeoff for someone who was rebuilding manually
  with `--build` anyway and wants to know exactly when something restarts,
  not have it happen silently in the background.

