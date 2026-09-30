package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	mrand "math/rand/v2"
	"net/http"
	"strconv"
	"time"

	"github.com/bulbashenko/eks-gitops-platform/apps/internal/httpx"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/queue"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/store"
)

type publisher interface {
	Publish(ctx context.Context, m queue.OrderMessage) error
}

type orderReader interface {
	Get(ctx context.Context, id string) (store.Order, error)
}

type server struct {
	queue     publisher
	orders    orderReader
	faultRate float64
	version   string
}

// openAPISpec is the API contract. TestSpecMatchesRoutes keeps it in sync with endpoints(),
// and the handler tests validate every response against it.
//
//go:embed openapi.yaml
var openAPISpec []byte

type endpoint struct {
	pattern string
	handler http.HandlerFunc
}

// endpoints is the api's route table (the probes are registered by httpx.Probes).
func (s *server) endpoints() []endpoint {
	return []endpoint{
		{"POST /orders", s.withFaults(s.createOrder)},
		{"GET /orders/{id}", s.withFaults(s.getOrder)},
		{"GET /burn", s.withFaults(s.burn)},
		{"GET /version", s.getVersion},
		{"GET /openapi.yaml", serveOpenAPI},
	}
}

func (s *server) routes(mux *http.ServeMux) {
	for _, e := range s.endpoints() {
		httpx.Handle(mux, e.pattern, e.handler)
	}
}

func serveOpenAPI(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/yaml")
	// Public document: allow browser tools such as editor.swagger.io to fetch it cross-origin.
	w.Header().Set("Access-Control-Allow-Origin", "*")
	_, _ = w.Write(openAPISpec)
}

// withFaults fails a configurable fraction of requests. A release with FAULT_RATE > 0
// is how the demo produces a "bad" canary that the Prometheus analysis rejects.
func (s *server) withFaults(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.faultRate > 0 && mrand.Float64() < s.faultRate {
			httpx.Error(w, http.StatusInternalServerError, "injected fault")
			return
		}
		h(w, r)
	}
}

type createOrderRequest struct {
	Item string `json:"item"`
	Qty  int    `json:"qty"`
}

func (s *server) createOrder(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		httpx.Error(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.Item == "" || len(req.Item) > 100 {
		httpx.Error(w, http.StatusBadRequest, "item must be 1-100 characters")
		return
	}
	if req.Qty < 1 || req.Qty > 1000 {
		httpx.Error(w, http.StatusBadRequest, "qty must be between 1 and 1000")
		return
	}

	msg := queue.OrderMessage{ID: newID(), Item: req.Item, Qty: req.Qty, CreatedAt: time.Now().UTC()}
	if err := s.queue.Publish(r.Context(), msg); err != nil {
		slog.Error("publish order", "err", err)
		httpx.Error(w, http.StatusServiceUnavailable, "could not queue order")
		return
	}
	httpx.JSON(w, http.StatusAccepted, map[string]string{"id": msg.ID, "status": "queued"})
}

func (s *server) getOrder(w http.ResponseWriter, r *http.Request) {
	o, err := s.orders.Get(r.Context(), r.PathValue("id"))
	switch {
	case errors.Is(err, store.ErrNotFound):
		// Not processed yet (or never existed): the worker writes asynchronously.
		httpx.Error(w, http.StatusNotFound, "order not found or not processed yet")
	case err != nil:
		slog.Error("get order", "err", err)
		httpx.Error(w, http.StatusInternalServerError, "could not load order")
	default:
		httpx.JSON(w, http.StatusOK, o)
	}
}

// burn spends CPU for ?ms= milliseconds (max 500) so load tests can drive the HPA.
func (s *server) burn(w http.ResponseWriter, r *http.Request) {
	ms, err := strconv.Atoi(r.URL.Query().Get("ms"))
	if err != nil || ms < 1 {
		ms = 50
	}
	ms = min(ms, 500)
	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	sum := sha256.Sum256([]byte("burn"))
	for time.Now().Before(deadline) {
		sum = sha256.Sum256(sum[:])
	}
	httpx.JSON(w, http.StatusOK, map[string]any{"burned_ms": ms, "hash": hex.EncodeToString(sum[:4])})
}

func (s *server) getVersion(w http.ResponseWriter, _ *http.Request) {
	httpx.JSON(w, http.StatusOK, map[string]string{"version": s.version})
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
