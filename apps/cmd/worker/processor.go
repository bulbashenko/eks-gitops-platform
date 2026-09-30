package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	"github.com/bulbashenko/eks-gitops-platform/apps/internal/queue"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/store"
)

var (
	processed = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "worker_messages_processed_total",
		Help: "Queue messages handled, by result (ok, error, malformed).",
	}, []string{"result"})

	processingDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "worker_processing_duration_seconds",
		Help:    "Time to persist one order and write its receipt.",
		Buckets: prometheus.DefBuckets,
	})
)

type consumer interface {
	Receive(ctx context.Context) ([]queue.Message, error)
	Delete(ctx context.Context, receiptHandle string) error
}

type orderWriter interface {
	Insert(ctx context.Context, o store.Order) error
}

type receiptWriter interface {
	Put(ctx context.Context, key string, body []byte) error
}

type processor struct {
	queue    consumer
	orders   orderWriter
	receipts receiptWriter // nil disables receipts
}

// Run polls until ctx is cancelled. A batch in flight is finished with a fresh
// context so SIGTERM never leaves an order half-processed.
func (p *processor) Run(ctx context.Context) error {
	for {
		msgs, err := p.queue.Receive(ctx)
		if ctx.Err() != nil {
			return nil
		}
		if err != nil {
			slog.Error("receive", "err", err)
			time.Sleep(2 * time.Second)
			continue
		}
		batchCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		for _, m := range msgs {
			p.handle(batchCtx, m)
		}
		cancel()
	}
}

// handle deletes a message only after it was fully processed. Failures are left on the
// queue: SQS redelivers after the visibility timeout and moves poison messages to the DLQ.
func (p *processor) handle(ctx context.Context, m queue.Message) {
	if m.Err != nil {
		slog.Error("malformed message, leaving for DLQ", "err", m.Err, "body", m.Raw)
		processed.WithLabelValues("malformed").Inc()
		return
	}
	start := time.Now()
	if err := p.process(ctx, m.Order); err != nil {
		slog.Error("process order", "id", m.Order.ID, "err", err)
		processed.WithLabelValues("error").Inc()
		return
	}
	if err := p.queue.Delete(ctx, m.ReceiptHandle); err != nil {
		// The order is stored; a redelivery is harmless because inserts are idempotent.
		slog.Error("delete message", "id", m.Order.ID, "err", err)
	}
	processingDuration.Observe(time.Since(start).Seconds())
	processed.WithLabelValues("ok").Inc()
	slog.Info("order processed", "id", m.Order.ID)
}

func (p *processor) process(ctx context.Context, o queue.OrderMessage) error {
	order := store.Order{ID: o.ID, Item: o.Item, Qty: o.Qty, CreatedAt: o.CreatedAt}
	if err := p.orders.Insert(ctx, order); err != nil {
		return fmt.Errorf("insert: %w", err)
	}
	if p.receipts == nil {
		return nil
	}
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(o); err != nil {
		return err
	}
	if err := p.receipts.Put(ctx, "receipts/"+o.ID+".json", buf.Bytes()); err != nil {
		return fmt.Errorf("write receipt: %w", err)
	}
	return nil
}
