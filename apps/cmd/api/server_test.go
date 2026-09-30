package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/bulbashenko/eks-gitops-platform/apps/internal/queue"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/store"
)

type fakeQueue struct {
	published []queue.OrderMessage
	err       error
}

func (f *fakeQueue) Publish(_ context.Context, m queue.OrderMessage) error {
	if f.err != nil {
		return f.err
	}
	f.published = append(f.published, m)
	return nil
}

type fakeOrders map[string]store.Order

func (f fakeOrders) Get(_ context.Context, id string) (store.Order, error) {
	o, ok := f[id]
	if !ok {
		return o, store.ErrNotFound
	}
	return o, nil
}

func newTestMux(s *server) *http.ServeMux {
	mux := http.NewServeMux()
	s.routes(mux)
	return mux
}

func do(mux http.Handler, method, target, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(method, target, strings.NewReader(body)))
	return rec
}

func TestCreateOrder(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		queueErr   error
		wantStatus int
		wantQueued int
	}{
		{"valid", `{"item":"coffee","qty":2}`, nil, http.StatusAccepted, 1},
		{"malformed json", `{`, nil, http.StatusBadRequest, 0},
		{"empty item", `{"item":"","qty":1}`, nil, http.StatusBadRequest, 0},
		{"qty too large", `{"item":"coffee","qty":5000}`, nil, http.StatusBadRequest, 0},
		{"queue down", `{"item":"coffee","qty":1}`, errors.New("boom"), http.StatusServiceUnavailable, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			q := &fakeQueue{err: tt.queueErr}
			rec := do(newTestMux(&server{queue: q}), "POST", "/orders", tt.body)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, tt.wantStatus, rec.Body)
			}
			if len(q.published) != tt.wantQueued {
				t.Fatalf("published %d messages, want %d", len(q.published), tt.wantQueued)
			}
		})
	}
}

func TestGetOrder(t *testing.T) {
	orders := fakeOrders{"abc": {ID: "abc", Item: "tea", Qty: 1, CreatedAt: time.Now()}}
	mux := newTestMux(&server{orders: orders})

	if rec := do(mux, "GET", "/orders/abc", ""); rec.Code != http.StatusOK {
		t.Fatalf("existing order: status = %d", rec.Code)
	}
	if rec := do(mux, "GET", "/orders/missing", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("missing order: status = %d", rec.Code)
	}
}

func TestFaultInjection(t *testing.T) {
	mux := newTestMux(&server{faultRate: 1})
	if rec := do(mux, "GET", "/burn?ms=1", ""); rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 with fault rate 1", rec.Code)
	}
	if rec := do(mux, "GET", "/version", ""); rec.Code != http.StatusOK {
		t.Fatalf("/version must not be affected by fault injection, got %d", rec.Code)
	}
}
