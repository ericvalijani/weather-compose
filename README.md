# Weather stack on Docker Compose

A small but real multi-service weather app on Docker Compose. One Go image
runs in three MODEs; Postgres stores data, RabbitMQ is the queue, Redis caches
the latest reading per city, Caddy terminates HTTPS, Prometheus + Grafana
provide monitoring, and Watchtower keeps the pulled images updated.

> The exact spec that generated this project lives in [`PROMPT.md`](PROMPT.md)
> at the repo root — useful if you want to regenerate this later or adapt it.

## Pinned versions (verified current stable, July 2026)

| Service    | Image                             | Port(s)                        |
|------------|-------------------------------------|---------------------------------|
| Postgres   | postgres:18.4-alpine                | 5432 (internal)                |
| RabbitMQ   | rabbitmq:4.3.2-management-alpine    | 5672, 15672                    |
| Redis      | redis:8.8.0-alpine                  | 6379 (internal)                |
| weather-store    | built locally (Go)             | 9090 gRPC, 9091 health/metrics |
| weather-api      | built locally (Go)             | 8080 HTTP                      |
| weather-consumer | built locally (Go)             | none                            |
| Caddy      | caddy:2.11.4-alpine                 | 80, 443                        |
| Watchtower | nickfedor/watchtower:1.19.0          | none                            |
| Prometheus | prom/prometheus:v3.12.0             | 9090                            |
| Grafana    | grafana/grafana:13.1.0              | 3000                            |

**Note on Watchtower:** the original `containrrr/watchtower` project was
archived in December 2025 and is no longer maintained. This project uses
`nickfedor/watchtower`, the actively developed, API-compatible fork — same
labels, same command-line flags, drop-in replacement. If you've seen older
tutorials referencing `containrrr/watchtower`, that image still exists on
Docker Hub but won't receive further updates.

## Architecture

```
            Open-Meteo (internet)
                  |
                  v
  [weather-api] --publish--> [rabbitmq] --consume--> [weather-consumer]
   http :8080                  queue                        |
   /metrics                weather.readings                 | gRPC :9090
   /readings/latest                                         v
        ^                                            [weather-store]
        | gRPC GetLatest                             writes -> [postgres]
        +--------------------------------------      cache  -> [redis]
                                                     /metrics :9091

  [caddy] :80/:443 --reverse_proxy--> weather-api:8080
  [prometheus] :9090 scrapes weather-api + weather-store
  [grafana]    :3000 dashboards (Prometheus datasource)
  [watchtower] auto-updates pulled images
```

## Generate + run

**If you already have this project (e.g. unzipped it) — skip `generate.sh`.**
It's included only so you can reproduce the project from scratch later; running
it again would just recreate the same files.

```bash
cd weather-compose
cp .env.example .env   # required — .env is intentionally not shipped in the zip
make up                 # build + start everything
make logs                # follow logs
```

**Starting from scratch instead** (you have only `generate.sh`, nothing else):

```bash
bash generate.sh      # scaffold the weather-compose/ project, including .env
cd weather-compose
make up               # build + start everything
make logs             # follow logs
```

Endpoints:

- App (via Caddy):   https://localhost            (accept the local cert)
- Latest readings:   https://localhost/readings/latest
-                    https://localhost/readings/latest?city=Berlin
- Grafana:           http://localhost:3000        (admin / devpassword)
- Prometheus:        http://localhost:9090
- RabbitMQ console:  http://localhost:15672       (admin / devpassword)

Inspect data:

```bash
make psql
#  SELECT city, temperature_c, observed_at FROM weather_readings ORDER BY observed_at DESC LIMIT 10;
make redis-cli
#  GET latest:Tehran
```

## Is the app really connected?

Yes, end to end:

- store  -> Postgres (writes) + Redis (cache) + gRPC server + /metrics
- api    -> Open-Meteo (fetch) + RabbitMQ (publish) + gRPC client (reads) + /metrics
- consumer -> RabbitMQ (consume) + gRPC (AddReading -> store -> Postgres)

`FETCH_INTERVAL` is 300s by default; lower it in .env to see data sooner.

## Monitoring

The Go app exposes Prometheus metrics:

- weather_temperature_celsius{city}
- weather_windspeed_kph{city}
- weather_readings_published_total
- weather_readings_stored_total

Prometheus scrapes them; Grafana auto-loads the "Weather Overview" dashboard.

## K8s -> Compose mapping

| Kubernetes        | Here (Compose)                          |
|-------------------|-----------------------------------------|
| Service DNS       | service name on the weather network     |
| ConfigMap/Secret  | .env / environment                       |
| PVC/StatefulSet   | named volume pgdata                      |
| probes            | healthcheck blocks                      |
| Helm/ArgoCD       | this docker-compose.yml + Watchtower    |
| cert-manager      | Caddy automatic HTTPS                    |
| kube-prometheus   | prometheus + grafana services           |

## CI/CD: develop -> push -> auto-deploy

The loop you asked for (no ArgoCD, no Kubernetes):

1. Edit the Go code in `app/` and push to GitHub (`main` branch).
2. GitHub Actions (`.github/workflows/ci.yml`) runs `go vet` + `go test`, then
   builds the Docker image and pushes it to GitHub Container Registry (GHCR) as
   `ghcr.io/<owner>/<repo>:latest` (also tagged with the commit SHA).
3. Watchtower on your laptop polls GHCR every 60s, detects the new `:latest`,
   pulls it, and restarts the `weather-*` services automatically.

### One-time setup

- Push the CONTENTS of `weather-compose/` as your repo root, so that `app/` and
  `.github/` sit at the top of the repo.
- In `.env`, set `IMAGE_REPO` to your repo, ALL lowercase:
  `IMAGE_REPO=ghcr.io/<owner>/<repo>`
- The first push triggers the build. Then make the GHCR package public:
  GitHub -> your avatar -> Packages -> select the package -> Package settings
  -> Change visibility -> Public. (Public means Watchtower needs no login.)
- Start the stack locally once with `make up`. From then on, every push that
  turns green auto-updates the running app.

### Private package instead of public?

If you keep the GHCR package private, Watchtower needs credentials. Create a
GitHub Personal Access Token with `read:packages`, run `docker login ghcr.io`
on the laptop, then add this to the `watchtower` service in `docker-compose.yml`:

```
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${HOME}/.docker/config.json:/config.json:ro
```

Watchtower only touches services labelled
`com.centurylinklabs.watchtower.enable=true` (the three `weather-*` services),
so Postgres, Grafana, etc. are never restarted by it.

## Not for production as-is

- Credentials live in .env for a one-command dev start. Move them to Docker
  secrets / a secrets manager and drop .env from git for real use.
- Go is compiled inside the Docker build (protoc generates the gRPC stubs
  there), so you only need Docker + Docker Compose on your machine.
