package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/legacy"

	"github.com/bulbashenko/eks-gitops-platform/apps/internal/httpx"
)

// Test requests target the spec's documented local server so the router can match them.
const specBaseURL = "http://localhost:8080"

var (
	specOnce   sync.Once
	specDoc    *openapi3.T
	specRouter routers.Router
	specErr    error
)

func loadSpec(t *testing.T) (*openapi3.T, routers.Router) {
	t.Helper()
	specOnce.Do(func() {
		loader := openapi3.NewLoader()
		if specDoc, specErr = loader.LoadFromData(openAPISpec); specErr != nil {
			return
		}
		if specErr = specDoc.Validate(context.Background()); specErr != nil {
			return
		}
		specRouter, specErr = legacy.NewRouter(specDoc)
	})
	if specErr != nil {
		t.Fatalf("openapi.yaml: %v", specErr)
	}
	return specDoc, specRouter
}

// validateResponse fails the test if the response (status, headers, body) is not described
// by openapi.yaml. IncludeResponseStatus makes undocumented status codes an error too.
func validateResponse(t *testing.T, req *http.Request, rec *httptest.ResponseRecorder) {
	t.Helper()
	_, router := loadSpec(t)
	route, params, err := router.FindRoute(req)
	if err != nil {
		t.Fatalf("%s %s is not in openapi.yaml: %v", req.Method, req.URL.Path, err)
	}
	opts := &openapi3filter.Options{IncludeResponseStatus: true, MultiError: true}
	in := &openapi3filter.ResponseValidationInput{
		RequestValidationInput: &openapi3filter.RequestValidationInput{
			Request: req, PathParams: params, Route: route, Options: opts,
		},
		Status:  rec.Code,
		Header:  rec.Header(),
		Options: opts,
	}
	in.SetBodyBytes(rec.Body.Bytes())
	if err := openapi3filter.ValidateResponse(context.Background(), in); err != nil {
		t.Errorf("%s %s → %d violates openapi.yaml: %v\nbody: %s", req.Method, req.URL.Path, rec.Code, err, rec.Body)
	}
}

func TestOpenAPISpecIsValid(t *testing.T) {
	loadSpec(t)
}

// Every route the code registers is documented, and every documented operation exists.
func TestSpecMatchesRoutes(t *testing.T) {
	doc, _ := loadSpec(t)

	var inSpec []string
	for path, item := range doc.Paths.Map() {
		for method := range item.Operations() {
			inSpec = append(inSpec, method+" "+path)
		}
	}
	var inCode []string
	for _, e := range (&server{}).endpoints() {
		inCode = append(inCode, e.pattern)
	}
	inCode = append(inCode, httpx.ProbeRoutes...)

	slices.Sort(inSpec)
	slices.Sort(inCode)
	if !slices.Equal(inSpec, inCode) {
		t.Errorf("routes and openapi.yaml diverge\n in code: %v\n in spec: %v", inCode, inSpec)
	}
}

func TestOpenAPIIsServed(t *testing.T) {
	rec := do(t, newTestMux(&server{}), "GET", "/openapi.yaml", "")
	if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), openAPISpec) {
		t.Fatalf("GET /openapi.yaml: status %d, %d bytes", rec.Code, rec.Body.Len())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/yaml" {
		t.Fatalf("Content-Type = %q", ct)
	}
}
