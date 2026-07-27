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

	// health + metrics endpoint used by the healthcheck and Prometheus
	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
		})
		mux.Handle("/metrics", promhttp.Handler())
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
