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
