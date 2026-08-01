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
