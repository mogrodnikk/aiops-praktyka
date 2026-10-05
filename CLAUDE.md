# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Czym jest to repo

Materiały szkoleniowe (Sages, 5–7.10.2026), dokumentacja po polsku, kod po angielsku:

- `app/` — aplikacja **Kantyna** (zamawianie obiadów), mikroserwisy na EKS. Kod, Makefile i Helm chart są tutaj.
- `labs/` — laby z celem, krokami i warunkiem SUKCES.
- `setup/` — przygotowanie stanowiska; `setup/check.sh` sprawdza 11 testów w namespace uczestnika.
- `docs/` — materiały i szablony promptów (`docs/prompts/`).

Komendy poniżej uruchamiaj z `app/`, chyba że napisano inaczej. `uv` nie jest w każdym środowisku — `make test-payments` wymaga tylko Dockera.

## Komendy

```bash
# Testy (z app/)
make test                          # orders-api (pytest) + payments (go test w golang:1.23 w Dockerze)
make test-orders-api               # cd orders-api && uv run pytest -q
cd orders-api && uv run pytest tests/test_api.py::test_create_order_success   # pojedynczy test
cd orders-api && uv run pytest -k "flag"                                      # po wyrażeniu

# Lokalnie (Docker Compose v2, z app/)
docker compose up -d --build       # UI: localhost:8088, orders-api: localhost:8000
docker compose --profile loadgen up -d loadgen
docker compose down -v             # usuwa też dane Postgresa

# Obrazy i chart
make build push VERSION=1.1.0 VARIANT=receipt-v2   # tagi :1.1.0 i :1.1.0-receipt-v2
make legacy-build                  # orders-api/Dockerfile.legacy (Python 3.9)
make helm-lint
make helm-template REGISTRY=<registry> VERSION=1.0.0

#Wersje kubectl. helm
kubectl version --client -o yaml | head -3
helm version --short


# Stanowisko uczestnika (z korzenia repo, wymaga klastra)
setup/check.sh                     # oczekiwany wynik: SUKCES: 11/11
```

## Architektura: przepływ zamówienia

Żeby zrozumieć system, trzeba przeczytać kilka plików razem:

- `app/web/` — nginx serwuje SPA (`app/web/html/`) i przekazuje `/api/` do `orders-api`.
- `app/orders-api/app/main.py` — FastAPI. `POST /api/orders` waliduje dane, liczy kwotę z cen w bazie i woła `payments` (`app/orders-api/app/payments.py`). Dopiero po zgodzie płatności zapisuje zamówienie w PostgreSQL w jednej transakcji, a potem publikuje zdarzenie do SQS (`app/orders-api/app/queue.py`, no-op bez `QUEUE_URL`).
- `app/payments/` — Go, `POST /pay`. Odmowa płatności kończy zamówienie błędem i nic nie trafia do bazy.
- `app/worker/app/main.py` — konsument SQS, zapisuje paragon JSON do S3.
- `app/loadgen/` — syntetyczny ruch o dobowym profilu (sterowany `PEAK_RPS`).

Lokalnie nie ma SQS ani S3: worker tylko czeka, a zamówienia i tak trafiają do bazy.

## Flagi i celowe awarie

- Flagi runtime: `app/deploy/local/flags.json` lokalnie, `flags:` w `app/deploy/helm/kantyna/values.yaml` na klastrze (ConfigMap `kantyna-flags`). Serwisy przeładowują plik co ~15 s, bez restartu.
- Flagi celowo wstrzykują awarie (`error_rate`, `db_pool_leak`, `memory_leak_mb_per_min`, `cpu_burn`, `slow_menu_query`, `log_noise`, opóźnienia i błędy w payments). Służą do ćwiczeń (lab02, runbooki w `app/runbooks/`). Nie usuwaj ich ani nie „naprawiaj” bez wyraźnej prośby.
- `APP_VARIANT` (`stable`, `receipt-v2`, `menu-v2`) zmienia zachowanie kodu: `menu_uses_n_plus_one` i `maybe_receipt_variant_error` w `app/orders-api/app/runtime.py`.

## Konfiguracja i obserwowalność

- Konfiguracja wyłącznie przez zmienne środowiskowe: `app/orders-api/app/config.py` (tabela w `app/README.md`).
- Logi JSON na stdout z `trace_id`/`span_id`; metryki Prometheus na `/metrics` każdego serwisu; trace'y OTLP do Tempo.
- `app/.env` zawiera **fałszywe** wartości do ćwiczeń. Nie wpisuj prawdziwych kluczy ani haseł do repo ani do modelu.
- Sprawdzanie zmian zrobisz za pomocą helm lint app/deploy/helm/kantyna
## Uprawnienia Claude Code

`.claude/settings.json` (korzeń repo): `kubectl get/describe/logs/top` i `k8sgpt analyze` działają bez pytania; `kubectl set/patch/edit/rollout/apply` pytają; `kubectl delete`, `kubectl exec` i odczyt sekretów są zablokowane.