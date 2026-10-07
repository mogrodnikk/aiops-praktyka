# Momenty odbiegające od normy — namespace `demo` (ostatnie 4 dni)

Godziny w czasie polskim (CEST, UTC+2). Namespace: `demo`.

sobota 11:35–12:12 | p95 czasu odpowiedzi orders-api skoczył z ~0.02 s do ~2.1–2.2 s (ponad 100x) | `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="demo", job="kantyna-orders-api"}[5m])))`

sobota 13:00–14:00 | kolejka workera: liczba widocznych wiadomości skoczyła z 0 do 1827 (peak ~13:47) | `worker_queue_visible_messages{namespace="demo"}`

sobota 17:35–18:35 | wyciek pamięci poda orders-api (7bb75898cc-*): ~83 MB → 279 MB, potem restart kontenera, nowy baseline ~140 MB | `max by (pod) (container_memory_working_set_bytes{namespace="demo", pod=~"kantyna-orders-api-7bb75898cc.*", container!=""})` oraz `sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="demo", pod=~"kantyna-orders-api-7bb75898cc.*"}[30m]))`

niedziela 12:03–12:33 | skok 5xx (route="unmatched", status=500): rate z 0 do ~0.4–0.5 req/s na ~30 min | `sum by (route, status) (rate(http_requests_total{namespace="demo", job="kantyna-orders-api", status=~"5.."}[5m]))`

poniedziałek 15:05–16:05 | drugi wyciek pamięci poda orders-api (bd4b567c6-*): ~81 MB → ~86 MB (wolny wzrost), potem skok do 137–155 MB i restart | `max by (pod) (container_memory_working_set_bytes{namespace="demo", pod=~"kantyna-orders-api-bd4b567c6.*", container!=""})` oraz `sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="demo", pod=~"kantyna-orders-api-bd4b567c6.*"}[30m]))`

poniedziałek 11:30–13:30 | drobny skok kolejki workera do 15 wiadomości (szum, nie incydent) | `worker_queue_visible_messages{namespace="demo"}`

wtorek 11:30–13:30 | drobny skok kolejki workera do 22 wiadomości (szum, nie incydent) | `worker_queue_visible_messages{namespace="demo"}`
