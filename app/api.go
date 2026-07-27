package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	pb "weather/genproto"

	amqp "github.com/rabbitmq/amqp091-go"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

type cityCoord struct {
	Name string
	Lat  float64
	Lon  float64
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
	cities := parseCities(getenv("CITIES", ""))
	interval := mustDuration("FETCH_INTERVAL", "300s")
	storeAddr := getenv("STORE_ADDR", "weather-store:9090")

	conn, err := grpc.NewClient(storeAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("api: cannot create store client: %v", err)
	}
	defer conn.Close()
	store := pb.NewWeatherStoreClient(conn)

	go serveHTTP(store, cities)

	log.Printf("api: fetch loop every %s for %d cities", interval, len(cities))
	for {
		publishAll(amqpURL, queue, cities)
		time.Sleep(interval)
	}
}

func serveHTTP(store pb.WeatherStoreClient, cities []cityCoord) {
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
			for _, c := range cities {
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
	addr := ":" + getenv("API_PORT", "8080")
	log.Println("api: http on", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("api: http server: %v", err)
	}
}

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
