# ================================================================
# Makefile for Multi-Repo Deployment
# Manages frontend, backend, worker services
#
# This Makefile drives both the LOCAL development environment
# (docker-compose.dev.yml) and the production stack
# (docker-compose.prod.yml) when bootstrapping a Prod-VM by hand —
# see docs/prod-setup.md for the manual walkthrough.
#
# Staging (docker-compose.staging.yml) has no local targets on
# purpose: that stack is rolled out exclusively via the Ansible CD
# pipeline (infrastructure/ansible/) so a developer laptop can't
# accidentally diverge from what CI produces.
# ================================================================
#
# Conventions:
# - All recipes that produce no file are listed in .PHONY below.
# - Compose-file paths live in $(DC_DEV) so we never
#   re-spell "docker-compose.dev.yml" in two recipes.
# - Help is generated from `## comments` on the target line — keep
#   them short, they are shown in the `make help` overview.
#
# Default goal is `help`, so a bare `make` is always safe.

# ----------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------
DOCKER  := $(shell command -v docker 2>/dev/null || command -v podman)
DC_DEV  := $(DOCKER) compose -f docker-compose.dev.yml
DC_PROD := $(DOCKER) compose -f docker-compose.prod.yml

# podman-compose (used when only podman is installed) has no `cp`
# subcommand, unlike `docker compose`. Container-to-host/host-to-
# container copies go through the engine's own `cp` instead, which
# both docker and podman support natively — but that needs the real
# container name (container_name: in the compose files), not the
# compose service name.
DOCKER_CP := $(DOCKER) cp

# Host-Ports (müssen mit den ${...:-default} Werten in den compose-
# Dateien übereinstimmen, sonst zeigt `make urls` falsche Links).
FRONTEND_PORT_DEV  ?= 5173
BACKEND_PORT       ?= 8000
KEYCLOAK_PORT      ?= 8080
RABBITMQ_UI_PORT   ?= 15672
PGADMIN_PORT       ?= 5050

.DEFAULT_GOAL := help

.PHONY: help \
        env secret \
        init quickstart urls \
        dev-up dev-down dev-stop dev-restart dev-restart-backend dev-restart-frontend dev-restart-worker \
        dev-logs dev-logs-backend dev-logs-frontend dev-logs-worker dev-logs-keycloak \
        dev-build dev-build-backend dev-build-frontend dev-build-worker dev-rebuild dev-ps \
        shell-backend shell-worker shell-frontend \
        shell-db shell-redis shell-keycloak shell-keycloak-db \
        keycloak-up keycloak-down keycloak-restart keycloak-logs keycloak-ps keycloak-reset keycloak-wait \
        keycloak-export keycloak-token keycloak-userinfo keycloak-url keycloak-disable-ssl \
        seed-data seed-reset \
        migrate-dev migration-create migration-history migration-current migration-downgrade \
        db-reset-dev \
        health status stats watch-dev top \
        clean-dev clean-all prune \
        test-backend test-backend-cov lint-backend lint-backend-fix format-backend \
        prod-up prod-down prod-stop prod-restart prod-pull prod-logs prod-ps \
        prod-migrate prod-seed prod-cert-self-signed prod-reset \
        prod-set-keycloak-urls \
        up down logs build

# ----------------------------------------------------------------
# Help
# ----------------------------------------------------------------
help: ## Show this help message
	@echo "🚀 Click-n-Deploy – Available Commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Services (dev): frontend, backend, worker, keycloak, postgres,"
	@echo "                postgres-test, postgres-tfstate, keycloak-postgres,"
	@echo "                redis, rabbitmq, pgadmin"
	@echo ""
	@echo "Bootstrap a fresh checkout:  make init"
	@echo "Show URLs:                   make urls"
	@echo ""

# ----------------------------------------------------------------
# Environment Setup
# ----------------------------------------------------------------
env: ## Create .env from template
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "✓ .env file created from template"; \
		echo "⚠️  Please edit .env with your actual values"; \
	else \
		echo ".env file already exists"; \
	fi

secret: ## Generate a new secret key (prints SECRET_KEY=...)
	@python3 -c "import secrets; print('SECRET_KEY=' + secrets.token_hex(32))"

# ----------------------------------------------------------------
# Bootstrap (Top-Level Helper)
# ----------------------------------------------------------------
# Bringt eine frische Arbeitskopie in einen lauffähigen Zustand.
# Reihenfolge: .env anlegen → Services hochfahren → DB-Schema
# applizieren → Beispiel-Daten einseeden. Wenn das .env-File schon
# existiert, lässt env es in Ruhe, also auch zum "auf den neuesten
# Stand bringen" verwendbar.
init: quickstart ## Alias for `quickstart`
quickstart: ## One-shot: env + dev-up + migrate-dev + seed-data
	@$(MAKE) --no-print-directory env
	@$(MAKE) --no-print-directory dev-up
	@echo "⏳ Warte 10s bis Backend/Postgres bereit sind..."
	@sleep 10
	@$(MAKE) --no-print-directory migrate-dev
	@$(MAKE) --no-print-directory seed-data
	@echo ""
	@echo "✓ Quickstart abgeschlossen."
	@$(MAKE) --no-print-directory urls

urls: ## Show all dev URLs in one place
	@echo "🌐 Dev URLs:"
	@echo ""
	@echo "  Frontend:           http://localhost:$(FRONTEND_PORT_DEV)"
	@echo "  Backend API:        http://localhost:$(BACKEND_PORT)"
	@echo "  Backend API Docs:   http://localhost:$(BACKEND_PORT)/docs"
	@echo "  Keycloak Admin:     http://localhost:$(KEYCLOAK_PORT)/admin   (admin / admin)"
	@echo "  Keycloak Realm:     http://localhost:$(KEYCLOAK_PORT)/realms/dhbw"
	@echo "  RabbitMQ UI:        http://localhost:$(RABBITMQ_UI_PORT)       (admin / admin)"
	@echo "  pgAdmin:            http://localhost:$(PGADMIN_PORT)            (admin@admin.com / admin)"
	@echo ""

# ----------------------------------------------------------------
# Development Environment
# ----------------------------------------------------------------
dev-up: ## Start development environment
	$(DC_DEV) up -d
	@echo ""
	@echo "✓ Development environment started"
	@$(MAKE) --no-print-directory urls

dev-down: ## Stop dev environment (keeps volumes)
	$(DC_DEV) down

dev-stop: ## Stop dev containers without removing them
	$(DC_DEV) stop

dev-restart: ## Restart dev environment
	$(DC_DEV) restart

dev-restart-backend: ## Restart backend only (e.g. after editing celery_app.py)
	$(DC_DEV) restart backend

dev-restart-frontend: ## Restart frontend only
	$(DC_DEV) restart frontend

dev-restart-worker: ## Restart worker only (after editing worker/app/tasks.py)
	$(DC_DEV) restart worker

dev-logs: ## Follow dev logs (all services)
	$(DC_DEV) logs -f

dev-logs-backend: ## Follow backend logs
	$(DC_DEV) logs -f backend

dev-logs-frontend: ## Follow frontend logs
	$(DC_DEV) logs -f frontend

dev-logs-worker: ## Follow worker logs
	$(DC_DEV) logs -f worker

dev-logs-keycloak: ## Follow Keycloak logs
	$(DC_DEV) logs -f keycloak

dev-build: ## Build all dev images
	$(DC_DEV) build

dev-build-backend: ## Build backend dev image only
	$(DC_DEV) build backend

dev-build-frontend: ## Build frontend dev image only
	$(DC_DEV) build frontend

dev-build-worker: ## Build worker dev image only
	$(DC_DEV) build worker

dev-rebuild: ## Rebuild from scratch and restart dev
	$(DC_DEV) down
	$(DC_DEV) build --no-cache
	$(DC_DEV) up -d

dev-ps: ## List dev containers
	$(DC_DEV) ps

# ----------------------------------------------------------------
# Shell Access
# ----------------------------------------------------------------
shell-backend: ## Open bash in backend container (dev)
	$(DC_DEV) exec backend bash

shell-worker: ## Open bash in worker container (dev)
	$(DC_DEV) exec worker bash

shell-frontend: ## Open sh in frontend container (dev)
	$(DC_DEV) exec frontend sh

shell-db: ## Open psql in dev Postgres (backend_dev)
	$(DC_DEV) exec postgres psql -U postgres -d backend_dev

shell-redis: ## Open redis-cli (dev)
	$(DC_DEV) exec redis redis-cli

shell-keycloak: ## Open bash in Keycloak container (dev)
	$(DC_DEV) exec keycloak bash

shell-keycloak-db: ## Open psql in Keycloak Postgres (dev)
	$(DC_DEV) exec keycloak-postgres psql -U keycloak -d keycloak

# ----------------------------------------------------------------
# Keycloak Management
# ----------------------------------------------------------------
keycloak-up: ## Start Keycloak + its Postgres only
	$(DC_DEV) up -d keycloak-postgres keycloak
	@echo "✓ Keycloak: http://localhost:$(KEYCLOAK_PORT)/admin   (admin / admin)"

keycloak-down: ## Stop Keycloak only
	$(DC_DEV) stop keycloak keycloak-postgres

keycloak-restart: ## Restart Keycloak only
	$(DC_DEV) restart keycloak

keycloak-logs: ## Follow Keycloak logs
	$(DC_DEV) logs -f keycloak

keycloak-ps: ## Show Keycloak container status
	$(DC_DEV) ps keycloak keycloak-postgres

keycloak-reset: ## ⚠️  Reset Keycloak (DROPS realm + users)
	@echo "⚠️  WARNING: This will delete all Keycloak data (realms, users, clients)!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		$(DC_DEV) stop keycloak keycloak-postgres; \
		$(DC_DEV) rm -f keycloak keycloak-postgres; \
		$(DOCKER) volume rm deployment_keycloak_postgres_data 2>/dev/null || true; \
		$(DC_DEV) up -d keycloak-postgres; \
		sleep 5; \
		$(DC_DEV) up -d keycloak; \
		$(MAKE) --no-print-directory keycloak-wait; \
		echo "✓ Keycloak reset complete"; \
		echo "  Login: admin / admin"; \
	fi

keycloak-wait: ## Block until Keycloak's HTTP listener answers (60s timeout)
	@# After a fresh `up -d keycloak`, the process boots Quarkus, imports
	@# the realm from data/import, and only THEN starts the HTTP listener.
	@# A subsequent `seed-data` racing against that startup explodes with
	@# `Connection refused` because nothing answers port 8080 yet.
	@#
	@# We can't use `curl -sf /realms/master/.well-known/openid-configuration`
	@# as the probe — Keycloak answers that endpoint with HTTP 403 by
	@# default (it's only available to authenticated callers), and curl
	@# -f treats 403 as a failure. The right signal is "any HTTP status
	@# came back", because that means the listener is bound. We probe
	@# /realms/master and accept anything that starts with a digit
	@# (2xx / 3xx / 4xx) — only a refused / hung connection produces
	@# an empty status code.
	@printf "⏳ Warte auf Keycloak (max 60s)"; \
	for i in $$(seq 1 60); do \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" -m 2 "http://localhost:$(KEYCLOAK_PORT)/realms/master" 2>/dev/null); \
	  case "$$code" in \
	    [234]*) echo " ✓ ready (nach $${i}s, HTTP $$code)"; exit 0 ;; \
	  esac; \
	  printf "."; \
	  sleep 1; \
	done; \
	echo ""; \
	echo "❌ Keycloak antwortet nach 60s nicht — siehe \`make dev-logs-keycloak\`"; \
	exit 1

keycloak-export: ## Export the dhbw realm to keycloak/keycloak-export.json
	@echo "Exporting Keycloak realm 'dhbw'..."
	$(DC_DEV) exec keycloak /opt/keycloak/bin/kc.sh export --dir /tmp --realm dhbw
	$(DOCKER_CP) keycloak-dev:/tmp/dhbw-realm.json ./keycloak/keycloak-export.json
	@echo "✓ Realm exported → keycloak/keycloak-export.json"

keycloak-disable-ssl: ## Allow plain-HTTP admin login on localhost (UPDATE realm SET ssl_required=NONE + restart)
	@echo "Disabling HTTPS requirement on the master realm..."
	$(DC_DEV) exec keycloak-postgres psql -U $${KEYCLOAK_DB_USER:-keycloak} -d $${KEYCLOAK_DB_NAME:-keycloak} \
		-c "UPDATE realm SET ssl_required = 'NONE' WHERE name = 'master';"
	@echo "Restarting Keycloak so it re-reads the realm settings..."
	$(DC_DEV) restart keycloak
	@echo "✓ master realm now accepts HTTP — Admin Console reachable at http://localhost:$(KEYCLOAK_PORT)/admin"

keycloak-token: ## Get a token (usage: make keycloak-token USER=luca.baeck PASS=1234)
	@curl -s -X POST http://localhost:$(KEYCLOAK_PORT)/realms/dhbw/protocol/openid-connect/token \
		-H "Content-Type: application/x-www-form-urlencoded" \
		-d "client_id=appstore-frontend" \
		-d "username=$(USER)" \
		-d "password=$(PASS)" \
		-d "grant_type=password" | jq -r '.access_token' | head -c 50; echo "..."

keycloak-userinfo: ## Decode userinfo (usage: make keycloak-userinfo TOKEN=xxx)
	@curl -s http://localhost:$(KEYCLOAK_PORT)/realms/dhbw/protocol/openid-connect/userinfo \
		-H "Authorization: Bearer $(TOKEN)" | jq

keycloak-url: ## Print Keycloak URLs
	@echo "🔐 Keycloak URLs:"
	@echo ""
	@echo "  Admin Console:   http://localhost:$(KEYCLOAK_PORT)/admin"
	@echo "  Realm dhbw:      http://localhost:$(KEYCLOAK_PORT)/realms/dhbw"
	@echo "  OIDC Config:     http://localhost:$(KEYCLOAK_PORT)/realms/dhbw/.well-known/openid-configuration"
	@echo "  Token Endpoint:  http://localhost:$(KEYCLOAK_PORT)/realms/dhbw/protocol/openid-connect/token"
	@echo "  User Info:       http://localhost:$(KEYCLOAK_PORT)/realms/dhbw/protocol/openid-connect/userinfo"
	@echo ""

# ----------------------------------------------------------------
# Seed Data
# ----------------------------------------------------------------
# Lädt Profs/Studenten/Admin in Keycloak (Realm ``dhbw``) und Kurse,
# Apps + Approval-Records in die Backend-DB. Idempotent — beliebig oft
# wiederholbar; Passwörter werden bei jedem Lauf auf den Default
# zurückgesetzt. Standardpasswort: 1234. Login: <vorname>.<nachname>@dhbw.de
#
# Voraussetzung: ``make dev-up`` lief (Backend + Keycloak gesund).
seed-data: ## Seed Keycloak users + DB (courses, apps, approvals)
	@echo "📥 Kopiere Seed-Skript + Realm-Export in den Backend-Container..."
	$(DOCKER_CP) ./seed/seed_data.py backend-dev:/tmp/seed_data.py
	$(DOCKER_CP) ./seed/app_descriptions backend-dev:/tmp/app_descriptions
	$(DOCKER_CP) ./keycloak/realm-export.json backend-dev:/tmp/realm-export.json
	@echo "🌱 Führe Seed aus..."
	$(DC_DEV) exec -T \
		-e KEYCLOAK_ADMIN_USER=$${KEYCLOAK_ADMIN_USER:-admin} \
		-e KEYCLOAK_ADMIN_PASSWORD=$${KEYCLOAK_ADMIN_PASSWORD:-admin} \
		-e REALM_EXPORT_PATH=/tmp/realm-export.json \
		backend poetry run python /tmp/seed_data.py

seed-reset: ## ⚠️  Reset DB + Keycloak realm, then seed
	@echo "⚠️  WARNING: This will reset the dev DB AND the Keycloak realm!"
	@read -p "Continue? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		$(MAKE) --no-print-directory db-reset-dev REPLY=y; \
		$(MAKE) --no-print-directory keycloak-reset REPLY=y; \
		$(MAKE) --no-print-directory seed-data; \
	fi

# ----------------------------------------------------------------
# Database Migrations
# ----------------------------------------------------------------
# Migrations on the deployed stack run automatically as a step in
# the Ansible CD pipeline (infrastructure/ansible/staging.yml)
# — there is no local migrate-deploy target, on purpose.
migrate-dev: ## Run database migrations (dev)
	$(DC_DEV) exec backend poetry run alembic upgrade head

migration-create: ## Autogenerate migration (usage: make migration-create MSG="message")
	@if [ -z "$(MSG)" ]; then \
		echo "Error: Please provide a message. Usage: make migration-create MSG='Your message'"; \
		exit 1; \
	fi
	$(DC_DEV) exec backend poetry run alembic revision --autogenerate -m "$(MSG)"

migration-history: ## Show migration history (dev)
	$(DC_DEV) exec backend poetry run alembic history

migration-current: ## Show current migration (dev)
	$(DC_DEV) exec backend poetry run alembic current

migration-downgrade: ## Downgrade by one revision (dev)
	$(DC_DEV) exec backend poetry run alembic downgrade -1

# ----------------------------------------------------------------
# Database Management
# ----------------------------------------------------------------
db-reset-dev: ## ⚠️  Wipe + re-create dev DB (DROPS ALL DATA, runs migrations)
	@echo "⚠️  WARNING: This will delete all development database data!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		$(DC_DEV) down -v; \
		$(DC_DEV) up -d; \
		sleep 8; \
		$(MAKE) --no-print-directory migrate-dev; \
		echo "✓ Development database reset complete"; \
	fi

# ----------------------------------------------------------------
# Health & Status
# ----------------------------------------------------------------
health: ## Check service health (dev)
	@echo "🏥 Checking service health..."
	@echo ""
	@printf "  Backend:   "; curl -sf http://localhost:$(BACKEND_PORT)/health > /dev/null && echo "✓ healthy" || echo "❌ not healthy"
	@printf "  Frontend:  "; curl -sf http://localhost:$(FRONTEND_PORT_DEV) > /dev/null && echo "✓ healthy" || echo "❌ not healthy"
	@printf "  Keycloak:  "; curl -sf http://localhost:$(KEYCLOAK_PORT)/realms/dhbw/.well-known/openid-configuration > /dev/null && echo "✓ healthy" || echo "❌ not healthy"
	@echo ""

status: ## Show container status (dev)
	$(DC_DEV) ps

# ----------------------------------------------------------------
# Monitoring
# ----------------------------------------------------------------
stats: ## docker stats (all containers)
	$(DOCKER) stats

watch-dev: ## Watch dev container status every 2s
	watch -n 2 '$(DC_DEV) ps'

top: ## Show top processes per dev container
	$(DC_DEV) top

# ----------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------
clean-dev: ## ⚠️  down -v on dev (removes ALL volumes/data)
	$(DC_DEV) down -v
	@echo "✓ Development cleanup complete"

clean-all: ## ⚠️  Wipe dev (DROPS ALL DATA)
	$(DC_DEV) down -v --rmi local
	@echo "✓ Complete cleanup done"

prune: ## ⚠️  docker system prune -af --volumes (system-wide)
	$(DOCKER) system prune -af --volumes
	@echo "✓ Docker system pruned"

# ----------------------------------------------------------------
# Testing & Quality (Backend)
# ----------------------------------------------------------------
test-backend: ## Run backend pytest
	$(DC_DEV) exec backend pytest

test-backend-cov: ## Run backend pytest with HTML coverage
	$(DC_DEV) exec backend pytest --cov=. --cov-report=html

lint-backend: ## Run backend linter (ruff check)
	$(DC_DEV) exec backend ruff check .

lint-backend-fix: ## ruff check --fix
	$(DC_DEV) exec backend ruff check --fix .

format-backend: ## ruff format
	$(DC_DEV) exec backend ruff format .

# ----------------------------------------------------------------
# Production (manual VM bootstrap — see docs/prod-setup.md)
# ----------------------------------------------------------------
# Self-signed certificate parameters. Override on the command line if
# the VM has a public IP / different hostname:
#   make prod-cert-self-signed PROD_HOST=203.0.113.42
# Default ``localhost`` is only useful when probing on the VM itself.
PROD_HOST       ?= localhost
PROD_CERT_DAYS  ?= 3650
PROD_CERT_DIR   := nginx/certs

prod-up: ## Start the prod stack (pulls :latest first)
	$(DC_PROD) up -d --pull always

prod-down: ## Stop and REMOVE prod containers (volumes kept)
	$(DC_PROD) down

prod-stop: ## Stop prod containers without removing them
	$(DC_PROD) stop

prod-restart: ## Restart one prod service (usage: make prod-restart SVC=backend)
	@if [ -z "$(SVC)" ]; then echo "Error: pass SVC=<service>, e.g. SVC=backend"; exit 1; fi
	$(DC_PROD) up -d --force-recreate $(SVC)

prod-pull: ## Re-pull all prod images and recreate changed containers
	$(DC_PROD) pull
	$(DC_PROD) up -d

prod-logs: ## Follow prod logs (all services, or SVC=backend for one)
	@$(DC_PROD) logs -f $(SVC)

prod-ps: ## List prod containers + health
	$(DC_PROD) ps

prod-migrate: ## Apply Alembic migrations against the running backend-prod container
	$(DOCKER) exec backend-prod python -m alembic upgrade head

prod-seed: ## Seed Keycloak users + DB (kurse, apps, approvals) against the prod stack
	@# Same shape as dev's seed-data: copy script + descriptions + realm
	@# export into the running backend container, then run it as a plain
	@# python call (the prod image has no poetry; the venv on PATH makes
	@# `python` resolve to /app/.venv/bin/python, which has the keycloak
	@# + SQLAlchemy deps).
	@# Critically we source .env inside the recipe shell so the
	@# KEYCLOAK_ADMIN_* values flow into the -e flags below. Without the
	@# source, the make shell sees them as empty (Make does not
	@# auto-include .env), the docker compose exec runs with empty
	@# admin creds, and the seed script hits Keycloak with a 401.
	@echo "📥 Kopiere Seed-Skript + Realm-Export in den Backend-Container..."
	$(DOCKER_CP) ./seed/seed_data.py backend-prod:/tmp/seed_data.py
	$(DOCKER_CP) ./seed/app_descriptions backend-prod:/tmp/app_descriptions
	$(DOCKER_CP) ./keycloak/realm-export.json backend-prod:/tmp/realm-export.json
	@echo "🌱 Führe Seed aus..."
	@set -a; . ./.env; set +a; \
	if [ -z "$$KEYCLOAK_ADMIN_USER" ] || [ -z "$$KEYCLOAK_ADMIN_PASSWORD" ]; then \
	  echo "❌ KEYCLOAK_ADMIN_USER / KEYCLOAK_ADMIN_PASSWORD fehlen in .env"; \
	  exit 1; \
	fi; \
	$(DC_PROD) exec -T \
	  -e KEYCLOAK_ADMIN_USER="$$KEYCLOAK_ADMIN_USER" \
	  -e KEYCLOAK_ADMIN_PASSWORD="$$KEYCLOAK_ADMIN_PASSWORD" \
	  -e REALM_EXPORT_PATH=/tmp/realm-export.json \
	  backend python /tmp/seed_data.py

prod-set-keycloak-urls: ## Patch Keycloak client redirect/web-origin URLs to APP_BASE_URL from .env
	@# Der Realm-Export bringt localhost-URLs mit (Dev-Snapshot). Dieses
	@# Target patcht die beiden Clients (`appstore-frontend` +
	@# `appstore-backend`) auf den Wert von `APP_BASE_URL`. Idempotent
	@# und bewusst NICHT Teil von `prod-seed` — sonst würden manuell
	@# ergänzte Redirect-URIs bei jedem Seed-Lauf stillschweigend weg.
	@set -a; . ./.env; set +a; \
	if [ -z "$$APP_BASE_URL" ]; then \
	  echo "❌ APP_BASE_URL fehlt in .env"; exit 1; \
	fi; \
	if [ -z "$$KEYCLOAK_ADMIN_USER" ] || [ -z "$$KEYCLOAK_ADMIN_PASSWORD" ]; then \
	  echo "❌ KEYCLOAK_ADMIN_USER / KEYCLOAK_ADMIN_PASSWORD fehlen in .env"; exit 1; \
	fi; \
	$(DOCKER_CP) ./seed/set_keycloak_urls.py backend-prod:/tmp/set_keycloak_urls.py; \
	$(DC_PROD) exec -T \
	  -e KEYCLOAK_ADMIN_USER="$$KEYCLOAK_ADMIN_USER" \
	  -e KEYCLOAK_ADMIN_PASSWORD="$$KEYCLOAK_ADMIN_PASSWORD" \
	  -e APP_BASE_URL="$$APP_BASE_URL" \
	  backend python /tmp/set_keycloak_urls.py

prod-cert-self-signed: ## Generate a 10-year self-signed cert (override PROD_HOST=<ip-or-host>)
	@mkdir -p $(PROD_CERT_DIR) && chmod 700 $(PROD_CERT_DIR)
	@# Add IP: SAN entry too when PROD_HOST looks like an IPv4 — both
	@# 'IP:1.2.3.4' and 'DNS:1.2.3.4' would otherwise be rejected by
	@# strict clients depending on what they were asked to verify.
	@san="DNS:$(PROD_HOST)"; \
	if echo "$(PROD_HOST)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$$'; then \
	  san="IP:$(PROD_HOST),DNS:$(PROD_HOST)"; \
	fi; \
	openssl req -x509 -nodes -days $(PROD_CERT_DAYS) -newkey rsa:2048 \
	  -keyout $(PROD_CERT_DIR)/key.pem \
	  -out    $(PROD_CERT_DIR)/cert.pem \
	  -subj   "/CN=$(PROD_HOST)" \
	  -addext "subjectAltName=$$san"
	@chmod 600 $(PROD_CERT_DIR)/key.pem
	@chmod 644 $(PROD_CERT_DIR)/cert.pem
	@echo ""
	@echo "✓ Self-signed cert für '$(PROD_HOST)' liegt unter $(PROD_CERT_DIR)/"
	@echo "  Gültig bis: $$(openssl x509 -in $(PROD_CERT_DIR)/cert.pem -noout -enddate | cut -d= -f2)"

prod-reset: ## ⚠️  STOP prod + DELETE all volumes (DBs, Keycloak, RabbitMQ). Irreversible.
	@echo "⚠️  This wipes ALL prod data: postgres, keycloak DB, rabbitmq, redis, tfstate."
	@read -p "Type 'yes' to continue: " -r REPLY; \
	if [ "$$REPLY" = "yes" ]; then \
	  $(DC_PROD) down -v; \
	  echo "✓ Prod stack and all volumes removed."; \
	else \
	  echo "Aborted."; \
	fi

# ----------------------------------------------------------------
# Aliases
# ----------------------------------------------------------------
up: dev-up ## Alias for dev-up
down: dev-down ## Alias for dev-down
logs: dev-logs ## Alias for dev-logs
build: dev-build ## Alias for dev-build
