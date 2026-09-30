// Package store persists processed orders in PostgreSQL.
package store

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrNotFound = errors.New("order not found")

type Order struct {
	ID          string    `json:"id"`
	Item        string    `json:"item"`
	Qty         int       `json:"qty"`
	CreatedAt   time.Time `json:"created_at"`
	ProcessedAt time.Time `json:"processed_at"`
}

type Store struct {
	pool *pgxpool.Pool
}

const schema = `
CREATE TABLE IF NOT EXISTS orders (
	id           text        PRIMARY KEY,
	item         text        NOT NULL,
	qty          integer     NOT NULL,
	created_at   timestamptz NOT NULL,
	processed_at timestamptz NOT NULL DEFAULT now()
)`

// Connect opens a pool and applies the schema, retrying until ctx is done.
// Retrying lets pods start before the database (or its secret) is ready
// instead of crash-looping.
func Connect(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("parse database config: %w", err)
	}
	s := &Store{pool: pool}

	backoff := time.Second
	for {
		err = s.migrate(ctx)
		if err == nil {
			return s, nil
		}
		slog.Warn("database not ready, retrying", "err", err, "in", backoff)
		select {
		case <-ctx.Done():
			pool.Close()
			return nil, fmt.Errorf("connect to database: %w", err)
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 30*time.Second)
	}
}

func (s *Store) migrate(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, schema)
	return err
}

func (s *Store) Ping(ctx context.Context) error {
	return s.pool.Ping(ctx)
}

// Insert is idempotent: SQS delivers at least once, so a redelivered message must not fail.
func (s *Store) Insert(ctx context.Context, o Order) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO orders (id, item, qty, created_at) VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING`,
		o.ID, o.Item, o.Qty, o.CreatedAt)
	return err
}

func (s *Store) Get(ctx context.Context, id string) (Order, error) {
	var o Order
	err := s.pool.QueryRow(ctx,
		`SELECT id, item, qty, created_at, processed_at FROM orders WHERE id = $1`, id).
		Scan(&o.ID, &o.Item, &o.Qty, &o.CreatedAt, &o.ProcessedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return o, ErrNotFound
	}
	return o, err
}

func (s *Store) Close() {
	s.pool.Close()
}
