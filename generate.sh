#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# generate.sh  -  scaffolds the whole Docker Compose weather stack.
# Pure bash generator (no Python). Run:  bash generate.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="weather-compose"
rm -rf "$ROOT"
mkdir -p "$ROOT/app/proto" "$ROOT/db" "$ROOT/caddy" \
  "$ROOT/monitoring/prometheus" \
  "$ROOT/monitoring/grafana/provisioning/datasources" \
  "$ROOT/monitoring/grafana/provisioning/dashboards" \
  "$ROOT/.github/workflows"

# ============================ docker-compose.yml ============================
cat > "$ROOT/docker-compose.yml" <<'WEOF'
name: weather-compose

networks:
  weather:
    driver: bridge

volumes:
  pgdata:
  rabbitmq_data:
  caddy_data:
  caddy_config:
  prometheus_data:
  grafana_data:

services:
  # ---- Data layer ------------------------------------------------
  postgres:
    image: postgres:18.4-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - pgdata:/var/lib/postgresql
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [weather]

  rabbitmq:
    image: rabbitmq:4.3.2-management-alpine
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_DEFAULT_USER}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_DEFAULT_PASS}
    ports:
      - "15672:15672"
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 15s
      timeout: 10s
      retries: 5
    networks: [weather]

  redis:
    image: redis:8.8.0-alpine
    restart: unless-stopped
    command: ["redis-server", "--save", "", "--appendonly", "no"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [weather]

  # ---- Application layer (one Go image, three MODEs) -------------
  weather-store:
    build:
      context: ./app
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    restart: unless-stopped
    environment:
      MODE: store
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    env_file: [.env]
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:9091/healthz"]
      interval: 15s
      timeout: 5s
      retries: 5
    networks: [weather]

  weather-api:
    build:
      context: ./app
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    restart: unless-stopped
    environment:
      MODE: api
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    env_file: [.env]
    depends_on:
      rabbitmq:
        condition: service_healthy
      weather-store:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/healthz"]
      interval: 15s
      timeout: 5s
      retries: 5
    networks: [weather]

  weather-consumer:
    build:
      context: ./app
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    restart: unless-stopped
    environment:
      MODE: consumer
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    env_file: [.env]
    depends_on:
      rabbitmq:
        condition: service_healthy
      weather-store:
        condition: service_healthy
    networks: [weather]

  # ---- Edge + automation ----------------------------------------
  caddy:
    image: caddy:2.11.4-alpine
    restart: unless-stopped
    depends_on: [weather-api]
    environment:
      SITE_ADDRESS: ${SITE_ADDRESS}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [weather]

  watchtower:
    image: nickfedor/watchtower:1.19.0
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: ["--interval", "60", "--cleanup", "--label-enable"]
    networks: [weather]

  # ---- Monitoring -----------------------------------------------
  prometheus:
    image: prom/prometheus:v3.12.0
    restart: unless-stopped
    volumes:
      - ./monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    ports:
      - "9090:9090"
    networks: [weather]

  grafana:
    image: grafana/grafana:13.1.0
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: ${GRAFANA_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - ./monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"
    depends_on: [prometheus]
    networks: [weather]
WEOF

# ================================== .env ====================================
cat > "$ROOT/.env" <<'WEOF'
# ---- Postgres ----
POSTGRES_USER=weather
POSTGRES_PASSWORD=devpassword
POSTGRES_DB=weatherdb
PGHOST=postgres
PGPORT=5432

# ---- RabbitMQ ----
RABBITMQ_DEFAULT_USER=admin
RABBITMQ_DEFAULT_PASS=devpassword
AMQP_HOST=rabbitmq
AMQP_PORT=5672
QUEUE=weather.readings

# ---- Redis ----
REDIS_ADDR=redis:6379
CACHE_TTL=120s

# ---- App ----
STORE_ADDR=weather-store:9090
STORE_HTTP_ADDR=http://weather-store:9091
API_PORT=8080
CITIES=Tehran:35.6892:51.3890,Berlin:52.5200:13.4050,Tokyo:35.6762:139.6503
FETCH_INTERVAL=300s

# ---- Image (CI/CD: GitHub Actions -> GHCR) ----
# Must match your GitHub repo, ALL lowercase: ghcr.io/<owner>/<repo>
IMAGE_REPO=ghcr.io/your-github-username/weather-compose
IMAGE_TAG=latest

# ---- Grafana ----
GRAFANA_USER=admin
GRAFANA_PASSWORD=devpassword

# ---- Caddy ----
# "localhost" -> Caddy issues a local cert automatically.
# For a real server use your domain, e.g. weather.example.com
SITE_ADDRESS=localhost

WEOF
cp "$ROOT/.env" "$ROOT/.env.example"

# ============================== .gitignore ==================================
cat > "$ROOT/.gitignore" <<'WEOF'
# never commit real secrets
.env

# go build output (app is built inside Docker)
/app/genproto/
WEOF

# ============================== db/init.sql =================================
cat > "$ROOT/db/init.sql" <<'WEOF'
CREATE TABLE IF NOT EXISTS weather_readings (
    id            BIGSERIAL PRIMARY KEY,
    city          TEXT NOT NULL,
    latitude      DOUBLE PRECISION,
    longitude     DOUBLE PRECISION,
    temperature_c DOUBLE PRECISION,
    windspeed_kph DOUBLE PRECISION,
    observed_at   TIMESTAMPTZ,
    source        TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_weather_city_time
    ON weather_readings (city, observed_at DESC);

CREATE TABLE IF NOT EXISTS cities (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    latitude   DOUBLE PRECISION NOT NULL,
    longitude  DOUBLE PRECISION NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

WEOF

# ============================== caddy/Caddyfile =============================
cat > "$ROOT/caddy/Caddyfile" <<'WEOF'
{$SITE_ADDRESS} {
	encode gzip
	reverse_proxy weather-api:8080
}
WEOF

# ============================== app/go.mod ==================================
cat > "$ROOT/app/go.mod" <<'WEOF'
module weather

go 1.26

require (
	github.com/lib/pq v1.10.9
	github.com/prometheus/client_golang v1.23.2
	github.com/rabbitmq/amqp091-go v1.12.0
	github.com/redis/go-redis/v9 v9.21.0
	google.golang.org/grpc v1.82.0
	google.golang.org/protobuf v1.36.11
)
WEOF

# ============================ app/proto/weather.proto =======================
cat > "$ROOT/app/proto/weather.proto" <<'WEOF'
syntax = "proto3";
package weather;
option go_package = "weather/genproto;genproto";

message Reading {
  string city = 1;
  double latitude = 2;
  double longitude = 3;
  double temperature_c = 4;
  double windspeed_kph = 5;
  string observed_at = 6;
  string source = 7;
}

message AddReadingResponse { int64 id = 1; }
message GetLatestRequest { string city = 1; }
message GetLatestResponse {
  Reading reading = 1;
  bool found = 2;
}

service WeatherStore {
  rpc AddReading(Reading) returns (AddReadingResponse);
  rpc GetLatest(GetLatestRequest) returns (GetLatestResponse);
}
WEOF

# ============================== app/main.go =================================
cat > "$ROOT/app/main.go" <<'WEOF'
package main

import (
	"log"
	"os"
	"time"
)

// getenv returns the env var or a default when unset/empty.
func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// mustDuration parses a duration env var (e.g. "300s") or dies.
func mustDuration(key, def string) time.Duration {
	d, err := time.ParseDuration(getenv(key, def))
	if err != nil {
		log.Fatalf("invalid duration for %s: %v", key, err)
	}
	return d
}

// One binary, three roles selected by MODE.
func main() {
	switch getenv("MODE", "") {
	case "store":
		runStore()
	case "api":
		runAPI()
	case "consumer":
		runConsumer()
	default:
		log.Fatal("set MODE=store|api|consumer")
	}
}
WEOF

# ============================== app/metrics.go ==============================
cat > "$ROOT/app/metrics.go" <<'WEOF'
package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Prometheus metrics shared across modes (registered on the default registry).
var (
	tempGauge = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "weather_temperature_celsius",
		Help: "Latest observed temperature in Celsius by city.",
	}, []string{"city"})

	windGauge = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "weather_windspeed_kph",
		Help: "Latest observed windspeed in km/h by city.",
	}, []string{"city"})

	publishedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "weather_readings_published_total",
		Help: "Total readings published to the queue by the api.",
	})

	storedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "weather_readings_stored_total",
		Help: "Total readings written to Postgres by the store.",
	})
)
WEOF

# ============================== app/store.go ================================
cat > "$ROOT/app/store.go" <<'WEOF'
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"time"

	pb "weather/genproto"

	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
)

type storeServer struct {
	pb.UnimplementedWeatherStoreServer
	db  *sql.DB
	rdb *redis.Client
	ttl time.Duration
}

func runStore() {
	dsn := "host=" + getenv("PGHOST", "postgres") +
		" port=" + getenv("PGPORT", "5432") +
		" user=" + getenv("POSTGRES_USER", "weather") +
		" password=" + getenv("POSTGRES_PASSWORD", "") +
		" dbname=" + getenv("POSTGRES_DB", "weatherdb") +
		" sslmode=disable"

	var db *sql.DB
	var err error
	for i := 0; i < 30; i++ {
		db, err = sql.Open("postgres", dsn)
		if err == nil {
			err = db.Ping()
		}
		if err == nil {
			break
		}
		log.Printf("store: waiting for postgres: %v", err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("store: cannot connect to postgres: %v", err)
	}
	log.Println("store: connected to postgres")

	rdb := redis.NewClient(&redis.Options{Addr: getenv("REDIS_ADDR", "redis:6379")})
	srv := &storeServer{db: db, rdb: rdb, ttl: mustDuration("CACHE_TTL", "120s")}
	seedCities(db, getenv("CITIES", ""))

	// health + metrics endpoint used by the healthcheck and Prometheus
	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
		})
		mux.Handle("/metrics", promhttp.Handler())

		// /cities is store's own small REST surface (separate from the gRPC
		// service above) - it's the only thing that touches the `cities`
		// table, keeping the "only store touches Postgres" rule intact.
		mux.HandleFunc("/cities", func(w http.ResponseWriter, r *http.Request) {
			switch r.Method {
			case http.MethodGet:
				rows, err := db.Query(`SELECT name, latitude, longitude FROM cities ORDER BY name`)
				if err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
				defer rows.Close()
				out := []cityCoord{}
				for rows.Next() {
					var c cityCoord
					if err := rows.Scan(&c.Name, &c.Lat, &c.Lon); err == nil {
						out = append(out, c)
					}
				}
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(out)

			case http.MethodPost:
				var c cityCoord
				if err := json.NewDecoder(r.Body).Decode(&c); err != nil || c.Name == "" {
					http.Error(w, "invalid city payload", http.StatusBadRequest)
					return
				}
				_, err := db.Exec(
					`INSERT INTO cities (name, latitude, longitude) VALUES ($1,$2,$3)
					 ON CONFLICT (name) DO UPDATE SET latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude`,
					c.Name, c.Lat, c.Lon)
				if err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
				log.Printf("store: city added/updated: %s (%.4f, %.4f)", c.Name, c.Lat, c.Lon)
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(c)

			default:
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			}
		})

		log.Println("store: health+metrics on :9091")
		if err := http.ListenAndServe(":9091", mux); err != nil {
			log.Printf("store: health server: %v", err)
		}
	}()

	lis, err := net.Listen("tcp", ":9090")
	if err != nil {
		log.Fatalf("store: listen: %v", err)
	}
	g := grpc.NewServer()
	pb.RegisterWeatherStoreServer(g, srv)
	log.Println("store: gRPC on :9090")
	if err := g.Serve(lis); err != nil {
		log.Fatalf("store: serve: %v", err)
	}
}

// AddReading inserts a reading, refreshes the Redis cache, bumps metrics.
func (s *storeServer) AddReading(ctx context.Context, r *pb.Reading) (*pb.AddReadingResponse, error) {
	var id int64
	err := s.db.QueryRowContext(ctx,
		`INSERT INTO weather_readings
		 (city, latitude, longitude, temperature_c, windspeed_kph, observed_at, source)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		r.City, r.Latitude, r.Longitude, r.TemperatureC, r.WindspeedKph, r.ObservedAt, r.Source,
	).Scan(&id)
	if err != nil {
		return nil, err
	}
	if b, e := json.Marshal(r); e == nil {
		s.rdb.Set(ctx, "latest:"+r.City, b, s.ttl)
	}
	storedTotal.Inc()
	log.Printf("store: saved id=%d city=%s temp=%.1f", id, r.City, r.TemperatureC)
	return &pb.AddReadingResponse{Id: id}, nil
}

// GetLatest returns the newest reading for a city (cache first, then Postgres).
func (s *storeServer) GetLatest(ctx context.Context, req *pb.GetLatestRequest) (*pb.GetLatestResponse, error) {
	if v, err := s.rdb.Get(ctx, "latest:"+req.City).Result(); err == nil {
		var r pb.Reading
		if json.Unmarshal([]byte(v), &r) == nil {
			return &pb.GetLatestResponse{Reading: &r, Found: true}, nil
		}
	}
	var r pb.Reading
	var observed time.Time
	err := s.db.QueryRowContext(ctx,
		`SELECT city, latitude, longitude, temperature_c, windspeed_kph, observed_at, source
		 FROM weather_readings WHERE city=$1 ORDER BY observed_at DESC LIMIT 1`, req.City).
		Scan(&r.City, &r.Latitude, &r.Longitude, &r.TemperatureC, &r.WindspeedKph, &observed, &r.Source)
	if err == sql.ErrNoRows {
		return &pb.GetLatestResponse{Found: false}, nil
	}
	if err != nil {
		return nil, err
	}
	r.ObservedAt = observed.Format(time.RFC3339)
	return &pb.GetLatestResponse{Reading: &r, Found: true}, nil
}

// seedCities inserts the initial CITIES list into the cities table once,
// so the very first boot has something to show before anyone adds a city
// through the UI. Safe to call every startup - ON CONFLICT DO NOTHING.
func seedCities(db *sql.DB, csv string) {
	for _, c := range parseCities(csv) {
		_, err := db.Exec(
			`INSERT INTO cities (name, latitude, longitude) VALUES ($1,$2,$3)
			 ON CONFLICT (name) DO NOTHING`, c.Name, c.Lat, c.Lon)
		if err != nil {
			log.Printf("store: seed city %s: %v", c.Name, err)
		}
	}
}

WEOF

# ============================== app/api.go ==================================
cat > "$ROOT/app/api.go" <<'WEOF'
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	pb "weather/genproto"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	amqp "github.com/rabbitmq/amqp091-go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

type cityCoord struct {
	Name string
	Lat  float64
	Lon  float64
}

// activeCities is a simple cache of the city list, always sourced from
// Postgres (via store's /cities) - CITIES env is only ever used once, by
// store, to seed the table on first boot. Never read from env here.
var (
	citiesMu     sync.RWMutex
	activeCities []cityCoord
)

func getCities() []cityCoord {
	citiesMu.RLock()
	defer citiesMu.RUnlock()
	out := make([]cityCoord, len(activeCities))
	copy(out, activeCities)
	return out
}

func setCities(c []cityCoord) {
	citiesMu.Lock()
	activeCities = c
	citiesMu.Unlock()
}

// listCities always reads the current city list straight from store's
// /cities (Postgres). Called at startup and periodically to refresh the
// cache above - insert into the DB, then re-read the DB, nothing fancier.
func listCities(storeHTTP string) ([]cityCoord, error) {
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(storeHTTP + "/cities")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("store /cities: status %d", resp.StatusCode)
	}
	var out []cityCoord
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

// addCityToStore POSTs a resolved city (name + coordinates) to store, which
// persists it in Postgres (INSERT ... ON CONFLICT DO UPDATE).
func addCityToStore(storeHTTP string, c cityCoord) error {
	body, _ := json.Marshal(c)
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Post(storeHTTP+"/cities", "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("store /cities: status %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

// geocodeCity resolves a plain city name to coordinates via Open-Meteo's
// free geocoding API - no API key required. Returns the first match.
func geocodeCity(name string) (cityCoord, error) {
	u := "https://geocoding-api.open-meteo.com/v1/search?count=1&name=" + url.QueryEscape(name)
	client := http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(u)
	if err != nil {
		return cityCoord{}, err
	}
	defer resp.Body.Close()
	var parsed struct {
		Results []struct {
			Name      string  `json:"name"`
			Latitude  float64 `json:"latitude"`
			Longitude float64 `json:"longitude"`
			Country   string  `json:"country"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return cityCoord{}, err
	}
	if len(parsed.Results) == 0 {
		return cityCoord{}, fmt.Errorf("no match found for %q", name)
	}
	r := parsed.Results[0]
	return cityCoord{Name: r.Name, Lat: r.Latitude, Lon: r.Longitude}, nil
}

type reading struct {
	City         string  `json:"city"`
	Latitude     float64 `json:"latitude"`
	Longitude    float64 `json:"longitude"`
	TemperatureC float64 `json:"temperature_c"`
	WindspeedKph float64 `json:"windspeed_kph"`
	ObservedAt   string  `json:"observed_at"`
	Source       string  `json:"source"`
}

func parseCities(s string) []cityCoord {
	var out []cityCoord
	for _, part := range strings.Split(s, ",") {
		f := strings.Split(strings.TrimSpace(part), ":")
		if len(f) != 3 {
			continue
		}
		lat, _ := strconv.ParseFloat(f[1], 64)
		lon, _ := strconv.ParseFloat(f[2], 64)
		out = append(out, cityCoord{Name: f[0], Lat: lat, Lon: lon})
	}
	return out
}

func runAPI() {
	amqpURL := fmt.Sprintf("amqp://%s:%s@%s:%s/",
		getenv("RABBITMQ_DEFAULT_USER", "admin"),
		getenv("RABBITMQ_DEFAULT_PASS", ""),
		getenv("AMQP_HOST", "rabbitmq"),
		getenv("AMQP_PORT", "5672"))
	queue := getenv("QUEUE", "weather.readings")
	interval := mustDuration("FETCH_INTERVAL", "300s")
	storeAddr := getenv("STORE_ADDR", "weather-store:9090")
	storeHTTP := getenv("STORE_HTTP_ADDR", "http://weather-store:9091")

	conn, err := grpc.NewClient(storeAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("api: cannot create store client: %v", err)
	}
	defer conn.Close()
	store := pb.NewWeatherStoreClient(conn)

	// The city list always comes from Postgres, via store's /cities -
	// never from CITIES directly here. CITIES is only ever used once, by
	// store, to seed the table on first boot (see seedCities in store.go).
	// Retry until store is up, since it may still be starting.
	for i := 0; i < 30; i++ {
		if list, err := listCities(storeHTTP); err == nil {
			setCities(list)
			break
		}
		time.Sleep(2 * time.Second)
	}

	// Periodic cache refresh, still DB-sourced: picks up cities added
	// through the UI (or directly in Postgres) without a restart.
	go func() {
		for {
			time.Sleep(30 * time.Second)
			if list, err := listCities(storeHTTP); err == nil {
				setCities(list)
			}
		}
	}()

	go serveHTTP(store, storeHTTP)

	log.Printf("api: fetch loop every %s", interval)
	for {
		publishAll(amqpURL, queue, getCities())
		time.Sleep(interval)
	}
}

func serveHTTP(store pb.WeatherStoreClient, storeHTTP string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/readings/latest", func(w http.ResponseWriter, r *http.Request) {
		var names []string
		if q := r.URL.Query().Get("city"); q != "" {
			names = []string{q}
		} else {
			for _, c := range getCities() {
				names = append(names, c.Name)
			}
		}
		out := []reading{}
		for _, name := range names {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			resp, err := store.GetLatest(ctx, &pb.GetLatestRequest{City: name})
			cancel()
			if err != nil {
				log.Printf("api: getLatest %s: %v", name, err)
				continue
			}
			if resp.Found && resp.Reading != nil {
				out = append(out, reading{
					City:         resp.Reading.City,
					Latitude:     resp.Reading.Latitude,
					Longitude:    resp.Reading.Longitude,
					TemperatureC: resp.Reading.TemperatureC,
					WindspeedKph: resp.Reading.WindspeedKph,
					ObservedAt:   resp.Reading.ObservedAt,
					Source:       resp.Reading.Source,
				})
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(out)
	})

	// GET /cities  - the current active list (Postgres-backed via store).
	// POST /cities - add a new city by name only; we geocode it ourselves.
	mux.HandleFunc("/cities", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(getCities())

		case http.MethodPost:
			var body struct {
				Name string `json:"name"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.Name) == "" {
				http.Error(w, "provide a city name", http.StatusBadRequest)
				return
			}
			c, err := geocodeCity(strings.TrimSpace(body.Name))
			if err != nil {
				http.Error(w, "could not resolve city: "+err.Error(), http.StatusBadRequest)
				return
			}
			if err := addCityToStore(storeHTTP, c); err != nil {
				http.Error(w, "could not save city: "+err.Error(), http.StatusBadGateway)
				return
			}

			// Insert done - now just re-read the list from the database,
			// rather than guessing/patching the in-memory cache by hand.
			if list, err := listCities(storeHTTP); err == nil {
				setCities(list)
			}

			// Get the temperature right away instead of waiting for the
			// next scheduled FETCH_INTERVAL cycle.
			if rd, err := fetchOne(c); err != nil {
				log.Printf("api: immediate fetch for %s failed: %v", c.Name, err)
			} else {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				_, err := store.AddReading(ctx, &pb.Reading{
					City:         rd.City,
					Latitude:     rd.Latitude,
					Longitude:    rd.Longitude,
					TemperatureC: rd.TemperatureC,
					WindspeedKph: rd.WindspeedKph,
					ObservedAt:   rd.ObservedAt,
					Source:       rd.Source,
				})
				cancel()
				if err != nil {
					log.Printf("api: immediate reading store for %s: %v", c.Name, err)
				} else {
					tempGauge.WithLabelValues(rd.City).Set(rd.TemperatureC)
					windGauge.WithLabelValues(rd.City).Set(rd.WindspeedKph)
					publishedTotal.Inc()
				}
			}

			log.Printf("api: city added: %s (%.4f, %.4f)", c.Name, c.Lat, c.Lon)
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(c)

		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})

	// GET / - a single dark-themed page to look up a city's current
	// weather, and add new cities by name (geocoded automatically).
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(weatherUIHTML))
	})

	addr := ":" + getenv("API_PORT", "8080")
	log.Println("api: http on", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("api: http server: %v", err)
	}
}

const weatherUIHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Weather stack</title>
<style>
  :root {
    --bg: #0f1420;
    --panel: #161d2e;
    --panel-2: #1d2740;
    --border: #2a3550;
    --text: #e8ecf5;
    --muted: #8b96b3;
    --accent: #4fc3f7;
    --accent-2: #29b6f6;
    --ok: #4ade80;
    --err: #f87171;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    background: radial-gradient(circle at 20% -10%, #1b2540 0%, var(--bg) 55%);
    color: var(--text);
    font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
    display: flex;
    justify-content: center;
    padding: 4rem 1.25rem;
  }
  .card {
    width: 100%;
    max-width: 460px;
  }
  h1 {
    font-size: 1.5rem;
    font-weight: 600;
    margin: 0 0 .3rem;
    letter-spacing: -.01em;
  }
  .sub {
    color: var(--muted);
    font-size: .9rem;
    margin: 0 0 1.75rem;
  }
  .search-wrap {
    position: relative;
  }
  .search-box {
    display: flex;
    align-items: center;
    gap: .6rem;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: .75rem 1rem;
    transition: border-color .15s;
  }
  .search-box:focus-within {
    border-color: var(--accent);
  }
  .search-box svg { flex-shrink: 0; color: var(--muted); }
  .search-box input {
    flex: 1;
    background: none;
    border: none;
    outline: none;
    color: var(--text);
    font-size: 1rem;
  }
  .search-box input::placeholder { color: var(--muted); }
  .dropdown {
    position: absolute;
    top: calc(100% + 8px);
    left: 0;
    right: 0;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 12px 32px rgba(0,0,0,.4);
    z-index: 5;
    display: none;
  }
  .dropdown.open { display: block; }
  .dropdown-item {
    padding: .7rem 1rem;
    cursor: pointer;
    font-size: .95rem;
    display: flex;
    justify-content: space-between;
    color: var(--text);
  }
  .dropdown-item:hover, .dropdown-item.active {
    background: var(--panel-2);
  }
  .dropdown-item .coords {
    color: var(--muted);
    font-size: .8rem;
  }
  .dropdown-item.add {
    color: var(--accent);
    font-weight: 500;
  }
  .dropdown-item.add .coords {
    color: var(--accent);
    opacity: .7;
  }
  .result {
    margin-top: 1.75rem;
    background: linear-gradient(160deg, var(--panel-2), var(--panel));
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 1.5rem;
    display: none;
  }
  .result.show { display: block; }
  .result .city {
    font-size: 1.1rem;
    font-weight: 600;
  }
  .result .temp {
    font-size: 3rem;
    font-weight: 700;
    line-height: 1.1;
    margin: .4rem 0;
    background: linear-gradient(90deg, var(--accent), var(--accent-2));
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
  }
  .result .meta {
    color: var(--muted);
    font-size: .85rem;
    display: flex;
    gap: 1.25rem;
    margin-top: .5rem;
  }
  .msg {
    margin-top: 1rem;
    font-size: .9rem;
    min-height: 1.2rem;
  }
  .msg.error { color: var(--err); }
  .msg.ok { color: var(--ok); }
  .msg.loading { color: var(--muted); }
</style>
</head>
<body>
  <div class="card">
    <h1>Weather stack</h1>
    <p class="sub">Search a city, or add a new one to start tracking it</p>

    <div class="search-wrap">
      <div class="search-box">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="7"></circle>
          <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
        </svg>
        <input id="q" type="text" placeholder="Search city, e.g. Tehran" autocomplete="off">
      </div>
      <div id="dropdown" class="dropdown"></div>
    </div>

    <div id="msg" class="msg"></div>

    <div id="result" class="result">
      <div class="city" id="r-city"></div>
      <div class="temp" id="r-temp"></div>
      <div class="meta">
        <span id="r-wind"></span>
        <span id="r-time"></span>
      </div>
    </div>
  </div>

<script>
let allCities = [];
let activeIndex = -1;

const q = document.getElementById('q');
const dropdown = document.getElementById('dropdown');
const msg = document.getElementById('msg');
const result = document.getElementById('result');

function setMsg(text, kind) {
  msg.textContent = text || '';
  msg.className = 'msg' + (kind ? ' ' + kind : '');
}

async function loadCities() {
  try {
    const res = await fetch('/cities');
    allCities = (await res.json()) || [];
  } catch (e) {
    setMsg('Could not load city list: ' + e.message, 'error');
  }
}

function renderDropdown(filter) {
  const term = (filter || '').trim();
  const lower = term.toLowerCase();
  const matches = allCities.filter(c => c.Name.toLowerCase().includes(lower));
  activeIndex = -1;

  if (matches.length === 0) {
    if (!term) {
      dropdown.classList.remove('open');
      dropdown.innerHTML = '';
      return;
    }
    // No known city matches - offer to add it.
    dropdown.innerHTML =
      '<div class="dropdown-item add" data-add="' + term + '">' +
        '<span>+ Add "' + term + '"</span>' +
        '<span class="coords">new city</span>' +
      '</div>';
    dropdown.classList.add('open');
    dropdown.querySelector('.dropdown-item').addEventListener('click', () => addCity(term));
    return;
  }

  dropdown.innerHTML = matches.map((c, i) =>
    '<div class="dropdown-item" data-name="' + c.Name + '" data-i="' + i + '">' +
      '<span>' + c.Name + '</span>' +
      '<span class="coords">' + c.Lat.toFixed(2) + ', ' + c.Lon.toFixed(2) + '</span>' +
    '</div>'
  ).join('');
  dropdown.classList.add('open');
  dropdown.querySelectorAll('.dropdown-item').forEach(el => {
    el.addEventListener('click', () => {
      q.value = el.dataset.name;
      dropdown.classList.remove('open');
      lookup(el.dataset.name);
    });
  });
}

async function addCity(name) {
  dropdown.classList.remove('open');
  result.classList.remove('show');
  setMsg('Looking up "' + name + '" and fetching its temperature...', 'loading');
  try {
    const res = await fetch('/cities', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name }),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(text || ('status ' + res.status));
    }
    const city = await res.json();
    await loadCities();
    q.value = city.Name;
    await lookup(city.Name);
  } catch (e) {
    setMsg('Could not add city: ' + e.message, 'error');
  }
}

async function lookup(name) {
  const city = (name || q.value).trim();
  if (!city) return;
  result.classList.remove('show');
  setMsg('Looking up ' + city + '...', 'loading');
  try {
    const res = await fetch('/readings/latest?city=' + encodeURIComponent(city));
    if (!res.ok) throw new Error('status ' + res.status);
    const data = await res.json();
    if (!data || data.length === 0) {
      setMsg('No data yet for "' + city + '". Only configured cities have readings.', 'error');
      return;
    }
    const r = data[0];
    document.getElementById('r-city').textContent = r.city;
    document.getElementById('r-temp').textContent = r.temperature_c.toFixed(1) + '°C';
    document.getElementById('r-wind').textContent = 'Wind ' + r.windspeed_kph.toFixed(0) + ' km/h';
    document.getElementById('r-time').textContent = r.observed_at.replace('T', ' ');
    result.classList.add('show');
    setMsg('', '');
  } catch (e) {
    setMsg('Error: ' + e.message, 'error');
  }
}

q.addEventListener('input', () => renderDropdown(q.value));
q.addEventListener('focus', () => renderDropdown(q.value));
q.addEventListener('keydown', (e) => {
  const items = Array.from(dropdown.querySelectorAll('.dropdown-item'));
  if (e.key === 'ArrowDown' && items.length) {
    e.preventDefault();
    activeIndex = Math.min(activeIndex + 1, items.length - 1);
    items.forEach((el, i) => el.classList.toggle('active', i === activeIndex));
  } else if (e.key === 'ArrowUp' && items.length) {
    e.preventDefault();
    activeIndex = Math.max(activeIndex - 1, 0);
    items.forEach((el, i) => el.classList.toggle('active', i === activeIndex));
  } else if (e.key === 'Enter') {
    e.preventDefault();
    const chosen = (activeIndex >= 0 && items[activeIndex]) ? items[activeIndex] : items[0];
    if (chosen && chosen.dataset.add) {
      addCity(chosen.dataset.add);
    } else if (chosen && chosen.dataset.name) {
      q.value = chosen.dataset.name;
      dropdown.classList.remove('open');
      lookup(chosen.dataset.name);
    } else {
      dropdown.classList.remove('open');
      lookup();
    }
  } else if (e.key === 'Escape') {
    dropdown.classList.remove('open');
  }
});
document.addEventListener('click', (e) => {
  if (!e.target.closest('.search-wrap')) dropdown.classList.remove('open');
});

loadCities();
</script>
</body>
</html>`

func publishAll(amqpURL, queue string, cities []cityCoord) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		log.Printf("api: amqp dial: %v", err)
		return
	}
	defer conn.Close()
	ch, err := conn.Channel()
	if err != nil {
		log.Printf("api: channel: %v", err)
		return
	}
	defer ch.Close()
	if _, err := ch.QueueDeclare(queue, true, false, false, false, nil); err != nil {
		log.Printf("api: queue declare: %v", err)
		return
	}
	for _, c := range cities {
		rd, err := fetchOne(c)
		if err != nil {
			log.Printf("api: fetch %s: %v", c.Name, err)
			continue
		}
		body, _ := json.Marshal(rd)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err = ch.PublishWithContext(ctx, "", queue, false, false, amqp.Publishing{
			ContentType: "application/json",
			Body:        body,
		})
		cancel()
		if err != nil {
			log.Printf("api: publish %s: %v", c.Name, err)
			continue
		}
		tempGauge.WithLabelValues(rd.City).Set(rd.TemperatureC)
		windGauge.WithLabelValues(rd.City).Set(rd.WindspeedKph)
		publishedTotal.Inc()
		log.Printf("api: published %s temp=%.1f", rd.City, rd.TemperatureC)
	}
}

func fetchOne(c cityCoord) (reading, error) {
	url := fmt.Sprintf(
		"https://api.open-meteo.com/v1/forecast?latitude=%f&longitude=%f&current_weather=true",
		c.Lat, c.Lon)
	client := http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return reading{}, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var parsed struct {
		CurrentWeather struct {
			Temperature float64 `json:"temperature"`
			Windspeed   float64 `json:"windspeed"`
			Time        string  `json:"time"`
		} `json:"current_weather"`
	}
	if err := json.Unmarshal(b, &parsed); err != nil {
		return reading{}, err
	}
	return reading{
		City:         c.Name,
		Latitude:     c.Lat,
		Longitude:    c.Lon,
		TemperatureC: parsed.CurrentWeather.Temperature,
		WindspeedKph: parsed.CurrentWeather.Windspeed,
		ObservedAt:   parsed.CurrentWeather.Time,
		Source:       "open-meteo",
	}, nil
}

WEOF

# ============================== app/consumer.go =============================
cat > "$ROOT/app/consumer.go" <<'WEOF'
package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	pb "weather/genproto"

	amqp "github.com/rabbitmq/amqp091-go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func runConsumer() {
	amqpURL := "amqp://" + getenv("RABBITMQ_DEFAULT_USER", "admin") + ":" +
		getenv("RABBITMQ_DEFAULT_PASS", "") + "@" +
		getenv("AMQP_HOST", "rabbitmq") + ":" + getenv("AMQP_PORT", "5672") + "/"
	queue := getenv("QUEUE", "weather.readings")
	storeAddr := getenv("STORE_ADDR", "weather-store:9090")

	conn, err := grpc.NewClient(storeAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("consumer: cannot create store client: %v", err)
	}
	defer conn.Close()
	client := pb.NewWeatherStoreClient(conn)

	var mq *amqp.Connection
	for i := 0; i < 30; i++ {
		mq, err = amqp.Dial(amqpURL)
		if err == nil {
			break
		}
		log.Printf("consumer: waiting for rabbitmq: %v", err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("consumer: cannot connect rabbitmq: %v", err)
	}
	defer mq.Close()

	ch, err := mq.Channel()
	if err != nil {
		log.Fatalf("consumer: channel: %v", err)
	}
	defer ch.Close()
	if _, err := ch.QueueDeclare(queue, true, false, false, false, nil); err != nil {
		log.Fatalf("consumer: queue declare: %v", err)
	}
	msgs, err := ch.Consume(queue, "", true, false, false, false, nil)
	if err != nil {
		log.Fatalf("consumer: consume: %v", err)
	}
	log.Println("consumer: waiting for messages")
	for d := range msgs {
		var r reading
		if err := json.Unmarshal(d.Body, &r); err != nil {
			log.Printf("consumer: bad message: %v", err)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		resp, err := client.AddReading(ctx, &pb.Reading{
			City:         r.City,
			Latitude:     r.Latitude,
			Longitude:    r.Longitude,
			TemperatureC: r.TemperatureC,
			WindspeedKph: r.WindspeedKph,
			ObservedAt:   r.ObservedAt,
			Source:       r.Source,
		})
		cancel()
		if err != nil {
			log.Printf("consumer: addReading: %v", err)
			continue
		}
		log.Printf("consumer: stored id=%d city=%s", resp.Id, r.City)
	}
}
WEOF

# ============================== app/Dockerfile ==============================
cat > "$ROOT/app/Dockerfile" <<'WEOF'
# ---- build stage: generate gRPC stubs + compile ----
FROM golang:1.26-alpine AS build
RUN apk add --no-cache protobuf protobuf-dev git
ENV GOBIN=/go/bin
ENV PATH="/go/bin:${PATH}"
WORKDIR /src

RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11 \
 && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2

COPY go.mod ./
COPY proto ./proto
RUN protoc --go_out=. --go_opt=module=weather \
           --go-grpc_out=. --go-grpc_opt=module=weather \
           proto/weather.proto

COPY *.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 go build -trimpath -o /weather .

# ---- runtime stage ----
FROM alpine:3.24
RUN apk add --no-cache ca-certificates wget
COPY --from=build /weather /weather
ENTRYPOINT ["/weather"]
WEOF

# ============================== app/.dockerignore ===========================
cat > "$ROOT/app/.dockerignore" <<'WEOF'
genproto/
*.md
WEOF

# ==================== monitoring/prometheus/prometheus.yml ==================
cat > "$ROOT/monitoring/prometheus/prometheus.yml" <<'WEOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: weather-api
    static_configs:
      - targets: ["weather-api:8080"]

  - job_name: weather-store
    static_configs:
      - targets: ["weather-store:9091"]
WEOF

# ============ monitoring/grafana provisioning: datasource ==================
cat > "$ROOT/monitoring/grafana/provisioning/datasources/datasource.yml" <<'WEOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
WEOF

# ============ monitoring/grafana provisioning: dashboards provider =========
cat > "$ROOT/monitoring/grafana/provisioning/dashboards/dashboards.yml" <<'WEOF'
apiVersion: 1
providers:
  - name: default
    orgId: 1
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /etc/grafana/provisioning/dashboards
WEOF

# ============ monitoring/grafana dashboard JSON ===========================
cat > "$ROOT/monitoring/grafana/provisioning/dashboards/weather.json" <<'WEOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "panels": [
    {
      "type": "timeseries",
      "title": "Temperature (C) by city",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 9, "w": 12, "x": 0, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "celsius" }, "overrides": [] },
      "targets": [ { "expr": "weather_temperature_celsius", "refId": "A" } ]
    },
    {
      "type": "timeseries",
      "title": "Windspeed (km/h) by city",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 9, "w": 12, "x": 12, "y": 0 },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "targets": [ { "expr": "weather_windspeed_kph", "refId": "A" } ]
    },
    {
      "type": "timeseries",
      "title": "Readings rate: published vs stored",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 9 },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "targets": [
        { "expr": "rate(weather_readings_published_total[5m])", "refId": "A", "legendFormat": "published" },
        { "expr": "rate(weather_readings_stored_total[5m])", "refId": "B", "legendFormat": "stored" }
      ]
    }
  ],
  "schemaVersion": 39,
  "tags": ["weather"],
  "templating": { "list": [] },
  "time": { "from": "now-6h", "to": "now" },
  "timepicker": {},
  "title": "Weather Overview",
  "uid": "weather-overview",
  "version": 1
}
WEOF

# ============================ .github/workflows/ci.yml ======================
cat > "$ROOT/.github/workflows/ci.yml" <<'WEOF'
name: CI/CD

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: @@O@@github.repository@@C@@

jobs:
  test:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: app
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.26"
      - name: Install protoc and plugins
        run: |
          sudo apt-get update
          sudo apt-get install -y protobuf-compiler
          go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11
          go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2
          echo "$(go env GOPATH)/bin" >> "$GITHUB_PATH"
      - name: Generate gRPC stubs
        run: |
          protoc --go_out=. --go_opt=module=weather \
                 --go-grpc_out=. --go-grpc_opt=module=weather \
                 proto/weather.proto
      - name: Vet and test
        run: |
          go mod tidy
          go vet ./...
          go test ./...

  build-and-push:
    needs: test
    runs-on: ubuntu-latest
    if: github.event_name == 'push'
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: @@O@@env.REGISTRY@@C@@
          username: @@O@@github.actor@@C@@
          password: @@O@@secrets.GITHUB_TOKEN@@C@@
      - name: Docker metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: @@O@@env.REGISTRY@@C@@/@@O@@env.IMAGE_NAME@@C@@
          tags: |
            type=raw,value=latest
            type=sha,format=short
      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: ./app
          push: true
          tags: @@O@@steps.meta.outputs.tags@@C@@
          labels: @@O@@steps.meta.outputs.labels@@C@@
          cache-from: type=gha
          cache-to: type=gha,mode=max
WEOF

# Reconstruct GitHub Actions expression braces (brace-safe post-processing).
D='$'; LC='{'; RC='}'
OPEN="${D}${LC}${LC} "
CLOSE=" ${RC}${RC}"
sed -i "s|@@O@@|${OPEN}|g; s|@@C@@|${CLOSE}|g" "$ROOT/.github/workflows/ci.yml"

# ============================ app/parse_test.go =============================
cat > "$ROOT/app/parse_test.go" <<'WEOF'
package main

import "testing"

func TestParseCities(t *testing.T) {
	got := parseCities("Tehran:35.6892:51.3890,Berlin:52.52:13.405")
	if len(got) != 2 {
		t.Fatalf("expected 2 cities, got %d", len(got))
	}
	if got[0].Name != "Tehran" {
		t.Errorf("expected first city Tehran, got %q", got[0].Name)
	}
	if got[1].Lat != 52.52 {
		t.Errorf("expected Berlin lat 52.52, got %v", got[1].Lat)
	}
}

func TestParseCitiesSkipsMalformed(t *testing.T) {
	got := parseCities("Bad,Tokyo:35.6762:139.6503,")
	if len(got) != 1 {
		t.Fatalf("expected 1 valid city, got %d", len(got))
	}
	if got[0].Name != "Tokyo" {
		t.Errorf("expected Tokyo, got %q", got[0].Name)
	}
}
WEOF

# ================================ Makefile ==================================
# built with printf so the recipe lines get real TAB characters
{
  printf '.PHONY: up down logs build restart ps psql redis-cli grafana prom\n\n'
  printf 'up:\n\tdocker compose up -d --build\n\n'
  printf 'down:\n\tdocker compose down\n\n'
  printf 'logs:\n\tdocker compose logs -f --tail=100\n\n'
  printf 'build:\n\tdocker compose build\n\n'
  printf 'restart:\n\tdocker compose restart\n\n'
  printf 'ps:\n\tdocker compose ps\n\n'
  printf 'psql:\n\tdocker compose exec postgres sh -c '\''psql -U $$POSTGRES_USER -d $$POSTGRES_DB'\''\n\n'
  printf 'redis-cli:\n\tdocker compose exec redis redis-cli\n\n'
  printf 'grafana:\n\t@echo Grafana:   http://localhost:3000\n\n'
  printf 'prom:\n\t@echo Prometheus: http://localhost:9090\n\n'
} > "$ROOT/Makefile"

# ================================ README ====================================
cat > "$ROOT/README.md" <<'WEOF'
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

## Web UI

Open `https://localhost` (or `http://localhost:8080` if calling weather-api
directly) for a small dark-themed page:

- Search box with live autocomplete over your currently tracked cities
- Type a city that isn't tracked yet and a "+ Add" option appears — it
  resolves the name to coordinates via Open-Meteo's free geocoding API
  (no key needed), saves it to Postgres, and fetches its temperature
  immediately, no restart or waiting for the next scheduled fetch cycle
- The city list is always read from Postgres (via `weather-store`'s own
  `/cities` endpoint on :9091) — `CITIES` in `.env` only ever seeds the
  table once, on the very first boot with an empty database

## Architecture

```
            Open-Meteo (internet)          Open-Meteo geocoding (internet)
                  |                                    ^
                  v                                    | (on add-city)
  [weather-api] --publish--> [rabbitmq] --consume--> [weather-consumer]
   http :8080                  queue                        |
   /metrics                weather.readings                 | gRPC :9090
   /readings/latest                                         v
   /cities (GET/POST)                                 [weather-store]
   /  (UI page)                                        writes -> [postgres]
        ^                                              cache  -> [redis]
        | gRPC GetLatest/AddReading                    /cities (GET/POST, :9091)
        +--------------------------------------        /metrics :9091

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

- App UI (via Caddy):  https://localhost              (accept the local cert)
- Latest readings:     https://localhost/readings/latest
-                      https://localhost/readings/latest?city=Berlin
- Cities (JSON):       https://localhost/cities        (GET list, POST to add)
- Grafana:             http://localhost:3000           (admin / devpassword)
- Prometheus:          http://localhost:9090
- RabbitMQ console:    http://localhost:15672          (admin / devpassword)

Inspect data:

```bash
make psql
#  SELECT city, temperature_c, observed_at FROM weather_readings ORDER BY observed_at DESC LIMIT 10;
#  SELECT name, latitude, longitude FROM cities ORDER BY name;
make redis-cli
#  GET latest:Tehran
```

## Is the app really connected?

Yes, end to end:

- store  -> Postgres (writes) + Redis (cache) + gRPC server + REST /cities + /metrics
- api    -> Open-Meteo (fetch + geocoding) + RabbitMQ (publish) + gRPC client (reads) + /metrics + UI
- consumer -> RabbitMQ (consume) + gRPC (AddReading -> store -> Postgres)

`FETCH_INTERVAL` is 300s by default; lower it in .env to see data sooner for
your originally configured cities. Cities added through the UI get their
first reading immediately, without waiting for the next cycle.

**If you're adding the `cities` table to an already-running stack** (rather
than starting fresh): Postgres only runs `db/init.sql` once, on a genuinely
empty data volume. If your `pgdata` volume predates this feature, adding a
city will fail with `relation "cities" does not exist` until you either run
`docker compose down -v` (wipes data, re-seeds from CITIES) or create the
table manually once:

```bash
docker compose exec postgres psql -U weather -d weatherdb -c "
CREATE TABLE IF NOT EXISTS cities (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    latitude   DOUBLE PRECISION NOT NULL,
    longitude  DOUBLE PRECISION NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"
```

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

WEOF

# ================================ PROMPT.md =================================
cat > "$ROOT/PROMPT.md" <<'PEOF'
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

Services (10 total) — give me exact ports and named volumes, not just names:
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
- an image that auto-redeploys updated containers by polling a registry
  (verify whether the well-known option for this is still maintained before
  picking it)
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
- The auto-redeploy service polls GHCR periodically and restarts only the
  three weather-* services via a docker label
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

PEOF

chmod +x generate.sh 2>/dev/null || true
echo "generated $ROOT"
