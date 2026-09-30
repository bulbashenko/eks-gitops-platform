// Command loadgen sends a steady stream of requests to the public api URL.
// Canary analysis needs live traffic through the ALB (where the canary weight is applied);
// without it the error-rate query has nothing to judge.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var version = "dev"

var sent = promauto.NewCounterVec(prometheus.CounterOpts{
	Name: "loadgen_requests_total",
	Help: "Requests sent by the load generator, by status code class.",
}, []string{"class"})

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "loadgen", "version", version))

	target := strings.TrimRight(os.Getenv("TARGET_URL"), "/")
	if target == "" {
		slog.Error("TARGET_URL is required")
		os.Exit(1)
	}
	rps, err := strconv.ParseFloat(getenv("RPS", "5"), 64)
	if err != nil || rps <= 0 {
		slog.Error("RPS must be a positive number")
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	go func() {
		mux := http.NewServeMux()
		mux.Handle("GET /metrics", promhttp.Handler())
		ok := func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }
		mux.HandleFunc("GET /healthz", ok)
		mux.HandleFunc("GET /readyz", ok)
		srv := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
		if err := srv.ListenAndServe(); err != nil {
			slog.Error("metrics server", "err", err)
		}
	}()

	client := &http.Client{Timeout: 5 * time.Second}
	ticker := time.NewTicker(time.Duration(float64(time.Second) / rps))
	defer ticker.Stop()
	slog.Info("sending traffic", "target", target, "rps", rps)

	for i := 0; ; i++ {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		// Mostly writes, some CPU work: exercises the queue path and the HPA.
		var req *http.Request
		if i%4 == 3 {
			req, _ = http.NewRequestWithContext(ctx, http.MethodGet, target+"/burn?ms=20", nil)
		} else {
			body := fmt.Sprintf(`{"item":"item-%d","qty":%d}`, i%50, i%5+1)
			req, _ = http.NewRequestWithContext(ctx, http.MethodPost, target+"/orders", strings.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
		}
		go send(client, req)
	}
}

func send(client *http.Client, req *http.Request) {
	resp, err := client.Do(req)
	if err != nil {
		sent.WithLabelValues("error").Inc()
		return
	}
	resp.Body.Close()
	sent.WithLabelValues(fmt.Sprintf("%dxx", resp.StatusCode/100)).Inc()
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
