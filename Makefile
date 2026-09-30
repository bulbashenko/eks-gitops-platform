SHELL        := /bin/bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help

PROJECT      ?= egp
REGION       ?= eu-north-1
# Ephemeral layers in apply order; `down` destroys them in reverse.
LAYERS       := 10-network 20-cluster 30-data

ACCOUNT_ID    = $(shell aws sts get-caller-identity --query Account --output text)
STATE_BUCKET  = $(PROJECT)-tfstate-$(ACCOUNT_ID)
TF            = terraform -chdir=infra/live/$*
BACKEND_ARGS  = -backend-config=../backend.hcl -backend-config="bucket=$(STATE_BUCKET)" \
                -backend-config="kms_key_id=arn:aws:kms:$(REGION):$(ACCOUNT_ID):alias/$(PROJECT)-tfstate"

##@ Infrastructure
.PHONY: bootstrap
bootstrap: ## One-time: create the state bucket and KMS key (local state)
	terraform -chdir=infra/bootstrap init -input=false
	terraform -chdir=infra/bootstrap apply

init-%: ## terraform init a layer, e.g. make init-00-foundation
	$(TF) init -input=false -reconfigure $(BACKEND_ARGS)

plan-%: init-% ## terraform plan a layer
	$(TF) plan -input=false

apply-%: init-% ## terraform apply a layer
	$(TF) apply -input=false $(if $(AUTO_APPROVE),-auto-approve)

destroy-%: init-% ## terraform destroy a layer
	$(TF) destroy -input=false $(if $(AUTO_APPROVE),-auto-approve)

.PHONY: up
up: $(addprefix apply-,$(LAYERS)) ## Create the ephemeral environment (network -> cluster -> data)

.PHONY: down
down: ## Clean up controller-created AWS resources, then destroy data -> cluster -> network
	PROJECT=$(PROJECT) REGION=$(REGION) ./scripts/platform-down.sh

##@ Application
.PHONY: test
test: ## Go vet + unit tests
	cd apps && go vet ./... && go test -race ./...

.PHONY: local-up
local-up: ## Run api + worker with Postgres and ElasticMQ in Docker
	docker compose -f local/compose.yaml up --build -d
	@echo "api: http://localhost:8080  worker metrics: http://localhost:8081/metrics"

.PHONY: local-down
local-down:
	docker compose -f local/compose.yaml down -v

##@ Quality
.PHONY: lint
lint: ## Run all pre-commit hooks on every file
	pre-commit run --all-files

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_%-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)}' $(MAKEFILE_LIST)
