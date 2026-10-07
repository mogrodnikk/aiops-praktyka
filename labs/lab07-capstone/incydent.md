# Dziennik incydentu — lab07 capstone

**Zgłoszenie (2026-10-07):** użytkownicy zgłaszają, że menu ładuje się bardzo wolno, a czasem dostają błąd.

| Godzina | Hipoteza (AI / ja) | Komenda / zapytanie | Wynik | Status |
|---|---|---|---|---|
| 15:44 | (ja) wykrycie — sprawdzam stan podów orders-api | `kubectl get pods -n mateusz` | `kantyna-orders-api-*` x2: `0/1 Running`, 0 restartów, inne serwisy (payments, web, worker, postgres) 1/1 | potwierdzone — orders-api NotReady |
| 15:44 | (AI) readiness probe pada — sprawdzam zdarzenia k8s | `kubectl get events -n mateusz --sort-by=.lastTimestamp` | `Readiness probe failed: Get ".../readyz": context deadline exceeded` na obu podach orders-api, co ~2s | potwierdzone |
| 15:44 | (AI) przyczyna może być w fladze runtime (db_pool_leak / slow_menu_query) | `kubectl get configmap -n mateusz kantyna-flags -o yaml` | `orders-api.db_pool_leak: true`, `orders-api.slow_menu_query: true` (inne flagi orders-api i payments/worker: wyłączone/0) | potwierdzone — obie flagi aktywne |
| 15:44 | (AI) wyczerpanie poola połączeń DB w orders-api | `kubectl logs -n mateusz kantyna-orders-api-57f449f654-dmhpb --tail=100` | powtarzające się `WARNING "Readiness check failed" error="couldn't get a connection after 30.00 sec"` od 13:35 UTC do teraz | potwierdzone |
| 15:44 | (AI) potwierdzenie metrykami Prometheus — pool pełny na obu podach | `query_prometheus: max by (pod) (db_pool_connections_in_use{namespace="mateusz"}) / max by (pod) (db_pool_size{namespace="mateusz"})` | `1` (100%) na obu podach orders-api | potwierdzone |
| 15:44 | (AI) czy to leak (rośnie w czasie) czy zwykłe obciążenie? | `query_prometheus (range 2h): max by (pod) (db_pool_connections_in_use{namespace="mateusz"})` | wartość 0 → skok do 10 (pełny pool) ok. 13:14 UTC (15:14 CEST) i od tego momentu płaskie plateau na 10, nie rośnie dalej — skok, nie powolny wzrost | potwierdzone — pool wypełnił się od razu po włączeniu flagi, nie przez narastający leak w czasie obserwacji |
| 15:44 | (AI) spadek ruchu po nasyceniu poola — zgodny z timeline | `query_prometheus (range 2h): sum(rate(http_requests_total{namespace="mateusz"}[5m]))` | RPS spadł z ~1.8 do ~0.68 w tym samym momencie (13:14 UTC) co nasycenie poola | potwierdzone — koreluje czasowo |
| 15:44 | (AI, wykluczenie) czy to CPU/pamięć (cpu_burn, memory_leak), nie pool? | `kubectl top pods -n mateusz` | orders-api: CPU 2m/limit 500m, RAM 70-71Mi/limit 384Mi — daleko od limitów | wykluczone jako przyczyna |

**Wniosek diagnozy (potwierdzony danymi):** flaga `orders-api.db_pool_leak=true` wyczerpuje pool połączeń do Postgresa (10/10 w użyciu na obu podach od ~15:14 CEST) → `/readyz` timeoutuje → pody wypadają z endpointów Service → web/loadgen widzą wolne/błędne odpowiedzi. Flaga `slow_menu_query=true` jest aktywna równocześnie i prawdopodobnie pogłębia problem (zapytania menu dłużej trzymają połączenie), ale nie została jeszcze osobno zmierzona (metryka `http_request_duration_seconds` dla handlera menu nie zwróciła danych w tym zapytaniu — do powtórzenia z poprawną nazwą handlera/labela).

## Diagnoza wg runbooka KantynaDBPoolExhausted — dalsze dowody

| Godzina | Hipoteza (AI / ja) | Komenda / zapytanie | Wynik | Status |
|---|---|---|---|---|
| 15:49 | (AI) krok 3 runbooka — logi z "pool" na poziomie ERROR/WARNING | Loki: `{namespace="mateusz", app="orders-api"} \|= "pool"` (poprawiony label — `app`, nie `app_kubernetes_io_name`) | 20 wpisów ERROR `"Exception in ASGI application"` z pełnym traceback | potwierdzone |
| 15:49 | (AI) jaki konkretnie wyjątek rzuca aplikacja? | analiza treści `exc_info` z logu | `psycopg_pool.PoolTimeout: couldn't get a connection after 30.00 sec` — to **realny błąd 500** zwracany użytkownikowi (nie tylko fail readiness probe) | potwierdzone — wyjaśnia "czasem dostają błąd" z zgłoszenia |
| 15:49 | (AI) dokładny moment startu incydentu | pierwsza linia błędu w Loki | pierwszy `PoolTimeout` o `2026-10-07T13:13:49 UTC` (15:13:49 CEST) — zgodne z momentem skoku `db_pool_connections_in_use` do 10/10 w Prometheusie (~13:14 UTC) | potwierdzone — start incydentu: **2026-10-07 15:13 CEST** |
| 15:49 | (AI) krok 4 runbooka — czy to niedawny deploy? | `helm -n mateusz history kantyna` | ostatnia wdrożona rewizja (5) z 2026-10-06 11:48:50 — ~28h przed incydentem; żadnej nowej rewizji w okolicy 15:13 CEST | wykluczone jako przyczyna — zmiana weszła przez edycję `kantyna-flags` (ConfigMap), nie przez `helm upgrade` |
| 15:49 | (AI) krok 2 runbooka — `pg_stat_activity` (idle in transaction vs realne query) | `kubectl exec sts/kantyna-postgres -- psql ...` | **nie wykonane** — `kubectl exec` zablokowany w uprawnieniach tej sesji (`.claude/settings.json` → `deny`) | blokada — wymaga ręcznego sprawdzenia przez uczestnika albo dashboardu z metryką stanu sesji |

**Zaktualizowany wniosek:** incydent zaczął się **2026-10-07 ok. 15:13 CEST**. Przyczyna pierwotna potwierdzona z dwóch niezależnych źródeł (metryki + logi aplikacji): flaga `db_pool_leak=true` wyczerpuje pool połączeń psycopg do Postgresa → część requestów (w tym menu) kończy się po 30s `PoolTimeout` (błąd 500), a `/readyz` też timeoutuje, więc pody wypadają z Service. Jedyny krok diagnozy z runbooka, którego nie udało się wykonać w tej sesji, to bezpośrednie zapytanie do `pg_stat_activity` (zablokowany `kubectl exec`) — nie jest to już konieczne do potwierdzenia przyczyny, ale potwierdziłoby mechanizm (realny leak w kodzie vs. sama flaga blokująca N połączeń).

## Krok 2 — pierwszy komunikat (szkic AI, DO POPRAWY przez uczestnika)

> **[SZKIC AI — nieprzeczytany/niepoprawiony przez człowieka]**
>
> Zamawianie w Kantynie działa wolno, a część zamówień kończy się błędem. Zgłoszenia użytkowników pojawiły się dziś po godzinie 15:00, a nasz monitoring potwierdza problem od ok. 15:13. Część użytkowników nie może złożyć zamówienia albo długo czeka na załadowanie menu; wcześniej złożone zamówienia i płatności nie są zagrożone. Zespół zidentyfikował prawdopodobną przyczynę — wyczerpanie puli połączeń do bazy danych w serwisie zamówień — i przygotowuje poprawkę. Następna aktualizacja za 30 minut albo wcześniej, jeśli wdrożymy mitygację.

**TODO uczestnika:** przeczytaj, popraw ton/fakty, usuń tę notatkę „SZKIC AI" i wklej ostateczną wersję jako wysłaną o godz. ____.

## Krok 4 — mitygacja i naprawa

**Decyzja (ja, po pytaniu od AI):** użyć `helm upgrade --reuse-values` jako mitygacji, bo repo i Helm release już miały poprawne wartości flag (`false/false`) — problemem był dryf na żywym ConfigMapie, zrobiony poza Helmem (prawdopodobnie setup labu wstrzyknął awarię bezpośrednio na klastrze, `kubectl patch`/`edit`, bez żadnej zmiany w repo/git).

| Godzina | Hipoteza (AI / ja) | Komenda / zapytanie | Wynik | Status |
|---|---|---|---|---|
| 15:55 | (AI) sprawdzenie, czy przyczyna jest w repo/Helm, czy to dryf na klastrze | `git log --oneline -- app/deploy/helm/kantyna/values.yaml`; `git diff` (pusty); `helm -n mateusz get values kantyna --all` | `values.yaml` od "Inicjalizacja repozytorium" ma `db_pool_leak: false`, `slow_menu_query: false`; `COMPUTED VALUES` ostatniego release'u Helma (rev. 5) też pokazują `false/false` | potwierdzone — **to nie błąd w repo/kodzie, to dryf konfiguracji na żywym klastrze poza Helmem** |
| 15:57 | (ja, decyzja) mitygacja: zresetować ConfigMap do wartości z Helm release, bez zmiany w repo | `helm upgrade kantyna app/deploy/helm/kantyna -n mateusz --reuse-values --timeout 5m` | `Release "kantyna" has been upgraded`, REVISION: 6 | wykonane |
| 15:57 | (AI) weryfikacja ConfigMapu po helm upgrade | `kubectl get configmap -n mateusz kantyna-flags -o jsonpath='{.data.flags\.json}'` | `db_pool_leak: false`, `slow_menu_query: false` dla orders-api | potwierdzone — ConfigMap naprawiony |
| 15:58 | (AI) czy pody wróciły do Ready po samym flipie flagi? | `kubectl get pods -n mateusz -l app.kubernetes.io/name=orders-api` (po ~20s na reload flag) | wciąż `0/1`; logi: `"couldn't get a connection after 30.00 sec"` nadal się powtarzają | **nie wystarczyło** — już wyciekniętych połączeń flaga sama nie zwalnia |
| 15:58 | (ja, decyzja z runbooka) restart orders-api, żeby zwolnić zaciekłe połączenia (akcja "Safe" z `KantynaDBPoolExhausted.md`) | `kubectl -n mateusz rollout restart deployment/kantyna-orders-api` → `kubectl -n mateusz rollout status deployment/kantyna-orders-api --timeout=120s` | `deployment "kantyna-orders-api" successfully rolled out`, nowe pody `1/1 Running` | wykonane, potwierdzone |
| 15:59 | (AI) weryfikacja poola po restarcie | Prometheus: `max by (pod) (db_pool_connections_in_use{namespace="mateusz"})` | nowe pody: `0` w użyciu (stare, terminujące pody jeszcze pokazywały `10` ze starej metryki) | potwierdzone — pool czysty na nowych podach |
| 15:59 | (AI) pełna weryfikacja środowiska | `setup/check.sh` | **SUKCES: 11/11** | potwierdzone — usługa w pełni przywrócona |

**Uwaga do post-mortem:** przyczyna źródłowa (kto i kiedy zmienił ConfigMap bezpośrednio na klastrze, poza Helmem) **nie została ustalona** — nie mam dostępu do audytu zdarzeń Kubernetes API (kto wykonał `kubectl patch`/`edit`) w tej sesji. To pozostaje do wyjaśnienia poza tym narzędziem (np. CloudTrail/audit log klastra) i do wpisania jako akcja zapobiegawcza w post-mortem. Commit do repo **nie był potrzebny** — `values.yaml` był już poprawny; naprawa to był `helm upgrade --reuse-values` + restart, bez zmian w kodzie.

## Krok 6 — post-mortem

Szkic: [`post-mortem.md`](post-mortem.md) (oznaczony jako SZKIC AI — do przeczytania, poprawy i usunięcia znaczników `[AI, niepotwierdzone w dzienniku]` przez uczestnika przed uznaniem za finalny).
