package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/bulbashenko/eks-gitops-platform/apps/internal/queue"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/store"
)

type fakeQueue struct{ deleted []string }

func (f *fakeQueue) Receive(context.Context) ([]queue.Message, error) { return nil, nil }
func (f *fakeQueue) Delete(_ context.Context, h string) error {
	f.deleted = append(f.deleted, h)
	return nil
}

type fakeOrders struct {
	inserted []store.Order
	err      error
}

func (f *fakeOrders) Insert(_ context.Context, o store.Order) error {
	if f.err != nil {
		return f.err
	}
	f.inserted = append(f.inserted, o)
	return nil
}

type fakeReceipts map[string][]byte

func (f fakeReceipts) Put(_ context.Context, key string, body []byte) error {
	f[key] = body
	return nil
}

func msg(id string) queue.Message {
	return queue.Message{
		ReceiptHandle: "rh-" + id,
		Order:         queue.OrderMessage{ID: id, Item: "tea", Qty: 1, CreatedAt: time.Now()},
	}
}

func TestHandleSuccessStoresWritesReceiptAndDeletes(t *testing.T) {
	q, orders, receipts := &fakeQueue{}, &fakeOrders{}, fakeReceipts{}
	p := &processor{queue: q, orders: orders, receipts: receipts}

	p.handle(context.Background(), msg("a1"))

	if len(orders.inserted) != 1 || orders.inserted[0].ID != "a1" {
		t.Fatalf("inserted = %+v", orders.inserted)
	}
	if _, ok := receipts["receipts/a1.json"]; !ok {
		t.Fatal("receipt not written")
	}
	if len(q.deleted) != 1 || q.deleted[0] != "rh-a1" {
		t.Fatalf("deleted = %v", q.deleted)
	}
}

func TestHandleFailureKeepsMessageForRetry(t *testing.T) {
	q := &fakeQueue{}
	p := &processor{queue: q, orders: &fakeOrders{err: errors.New("db down")}}

	p.handle(context.Background(), msg("a2"))

	if len(q.deleted) != 0 {
		t.Fatal("message must stay on the queue when processing fails")
	}
}

func TestHandleMalformedKeepsMessageForDLQ(t *testing.T) {
	q, orders := &fakeQueue{}, &fakeOrders{}
	p := &processor{queue: q, orders: orders}

	p.handle(context.Background(), queue.Message{ReceiptHandle: "rh", Err: errors.New("bad json")})

	if len(q.deleted) != 0 || len(orders.inserted) != 0 {
		t.Fatal("malformed message must be neither stored nor deleted")
	}
}
