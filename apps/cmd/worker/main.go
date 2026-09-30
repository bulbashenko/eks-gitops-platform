// Command worker consumes orders from SQS, stores them in Postgres and writes receipts to S3.
package main

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"golang.org/x/sync/errgroup"

	"github.com/bulbashenko/eks-gitops-platform/apps/internal/config"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/httpx"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/queue"
	"github.com/bulbashenko/eks-gitops-platform/apps/internal/store"
)

var version = "dev"

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "worker", "version", version))
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

	p := &processor{
		queue:  queue.New(sqs.NewFromConfig(awsCfg), cfg.QueueURL),
		orders: db,
	}
	if cfg.Bucket != "" {
		p.receipts = &s3Receipts{client: s3.NewFromConfig(awsCfg), bucket: cfg.Bucket}
	} else {
		slog.Warn("S3_BUCKET not set, receipts disabled")
	}

	mux := http.NewServeMux()
	probes := httpx.NewProbes(db.Ping)
	probes.Register(mux)
	srv := &http.Server{Addr: cfg.HTTPAddr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error { return httpx.Serve(gctx, srv, probes) })
	g.Go(func() error { return p.Run(gctx) })
	return g.Wait()
}

type s3Receipts struct {
	client *s3.Client
	bucket string
}

func (r *s3Receipts) Put(ctx context.Context, key string, body []byte) error {
	_, err := r.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(r.bucket),
		Key:         aws.String(key),
		Body:        bytes.NewReader(body),
		ContentType: aws.String("application/json"),
	})
	return err
}
