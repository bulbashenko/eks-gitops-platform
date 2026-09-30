// Package httpx holds the HTTP plumbing shared by all services:
// RED metrics, JSON helpers, health endpoints and graceful shutdown.
package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	requests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests by route and status code.",
	}, []string{"method", "route", "code"})

	duration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency by route.",
		Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5},
	}, []string{"method", "route"})
)

// Handle registers h on mux under pattern (e.g. "GET /orders/{id}") and records
// RED metrics labelled with the pattern, so label cardinality stays bounded.
func Handle(mux *http.ServeMux, pattern string, h http.HandlerFunc) {
	method, route := splitPattern(pattern)
	mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		h(rec, r)
		requests.WithLabelValues(method, route, strconv.Itoa(rec.status)).Inc()
		duration.WithLabelValues(method, route).Observe(time.Since(start).Seconds())
	})
}

func splitPattern(p string) (method, route string) {
	for i := 0; i < len(p); i++ {
		if p[i] == ' ' {
			return p[:i], p[i+1:]
		}
	}
	return "ANY", p
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func JSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("encode response", "err", err)
	}
}

func Error(w http.ResponseWriter, status int, msg string) {
	JSON(w, status, map[string]string{"error": msg})
}

// Probes serves /healthz, /readyz and /metrics. Readiness flips to false as soon as
// shutdown starts so the load balancer drains the pod before the server stops.
type Probes struct {
	shuttingDown atomic.Bool
	ready        func(context.Context) error
}

func NewProbes(ready func(context.Context) error) *Probes {
	return &Probes{ready: ready}
}

// ProbeRoutes lists the patterns Register serves, so API contracts can account for them.
var ProbeRoutes = []string{"GET /healthz", "GET /readyz", "GET /metrics"}

func (p *Probes) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if p.shuttingDown.Load() {
			http.Error(w, "shutting down", http.StatusServiceUnavailable)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		if err := p.ready(ctx); err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.Handle("GET /metrics", promhttp.Handler())
}

// Serve runs srv until ctx is cancelled, then marks the pod unready and shuts down gracefully.
func Serve(ctx context.Context, srv *http.Server, p *Probes) error {
	errc := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", srv.Addr)
		errc <- srv.ListenAndServe()
	}()

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}

	p.shuttingDown.Store(true)
	slog.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return err
	}
	if err := <-errc; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
