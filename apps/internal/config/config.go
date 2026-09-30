// Package config loads service configuration from environment variables.
package config

import (
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	// HTTPAddr is where health, readiness, metrics (and for the api, business) endpoints listen.
	HTTPAddr string
	// QueueURL is the SQS queue orders are published to / consumed from.
	QueueURL string
	// DatabaseURL is a Postgres DSN. When empty, libpq PG* environment variables are used,
	// which is how the Kubernetes deployment injects credentials from External Secrets.
	DatabaseURL string
	// Bucket is the S3 bucket receipts are written to. Optional: empty disables receipts.
	Bucket string
	// FaultRate is the fraction (0..1) of business requests that deliberately fail with HTTP 500.
	// Used to demonstrate canary analysis and automatic rollback.
	FaultRate float64
}

func Load() (Config, error) {
	c := Config{
		HTTPAddr:    getenv("HTTP_ADDR", ":8080"),
		QueueURL:    os.Getenv("SQS_QUEUE_URL"),
		DatabaseURL: os.Getenv("DATABASE_URL"),
		Bucket:      os.Getenv("S3_BUCKET"),
	}
	if c.QueueURL == "" {
		return c, fmt.Errorf("SQS_QUEUE_URL is required")
	}
	if v := os.Getenv("FAULT_RATE"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f < 0 || f > 1 {
			return c, fmt.Errorf("FAULT_RATE must be a number between 0 and 1, got %q", v)
		}
		c.FaultRate = f
	}
	return c, nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
