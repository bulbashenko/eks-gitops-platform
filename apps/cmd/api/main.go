// Command api accepts orders over HTTP, queues them on SQS and serves processed orders from Postgres.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"

	"github.com/bulbashenko/eks-gitops-platform/apps/internal/config"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/httpx"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/queue"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/store"
)

// version is set at build time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "api", "version", version))
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return err
	}
	db, err := store.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Close()

	s := &server{
		queue:     queue.New(sqs.NewFromConfig(awsCfg), cfg.QueueURL),
		orders:    db,
		faultRate: cfg.FaultRate,
		version:   version,
	}
	if cfg.FaultRate > 0 {
		slog.Warn("fault injection enabled", "rate", cfg.FaultRate)
	}

	mux := http.NewServeMux()
	probes := httpx.NewProbes(db.Ping)
	probes.Register(mux)
	s.routes(mux)

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
	}
	return httpx.Serve(ctx, srv, probes)
}
