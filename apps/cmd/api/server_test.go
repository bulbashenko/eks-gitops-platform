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

// dbDownID makes the fake behave like an unreachable database.
const dbDownID = "dddddddddddddddddddddddddddddddd"

func (f fakeOrders) Get(_ context.Context, id string) (store.Order, error) {
	if id == dbDownID {
		return store.Order{}, errors.New("connection refused")
	}
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

// do serves one request and checks the response against openapi.yaml (contract test).
func do(t *testing.T, mux http.Handler, method, target, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(method, specBaseURL+target, strings.NewReader(body)))
	validateResponse(t, httptest.NewRequest(method, specBaseURL+target, nil), rec)
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
			rec := do(t, newTestMux(&server{queue: q}), "POST", "/orders", tt.body)
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
	const id = "0123456789abcdef0123456789abcdef"
	now := time.Now().UTC()
	mux := newTestMux(&server{orders: fakeOrders{id: {ID: id, Item: "tea", Qty: 1, CreatedAt: now, ProcessedAt: now}}})

	for _, tt := range []struct {
		id   string
		want int
	}{
		{id, http.StatusOK},
		{"ffffffffffffffffffffffffffffffff", http.StatusNotFound},
		{dbDownID, http.StatusInternalServerError},
	} {
		if rec := do(t, mux, "GET", "/orders/"+tt.id, ""); rec.Code != tt.want {
			t.Errorf("GET /orders/%s: status = %d, want %d", tt.id, rec.Code, tt.want)
		}
	}
}

func TestBurnAndVersion(t *testing.T) {
	mux := newTestMux(&server{version: "abc1234"})
	if rec := do(t, mux, "GET", "/burn?ms=1", ""); rec.Code != http.StatusOK {
		t.Fatalf("/burn: status = %d", rec.Code)
	}
	if rec := do(t, mux, "GET", "/burn?ms=99999", ""); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"burned_ms":500`) {
		t.Fatalf("/burn must cap at 500ms, got %d %s", rec.Code, rec.Body)
	}
	if rec := do(t, mux, "GET", "/version", ""); !strings.Contains(rec.Body.String(), "abc1234") {
		t.Fatalf("/version body = %s", rec.Body)
	}
}

func TestFaultInjection(t *testing.T) {
	mux := newTestMux(&server{faultRate: 1})
	if rec := do(t, mux, "GET", "/burn?ms=1", ""); rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 with fault rate 1", rec.Code)
	}
	if rec := do(t, mux, "GET", "/version", ""); rec.Code != http.StatusOK {
		t.Fatalf("/version must not be affected by fault injection, got %d", rec.Code)
	}
}
