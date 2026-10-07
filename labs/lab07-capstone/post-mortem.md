# Post-mortem — wolne/błędne menu w Kantynie (namespace `mateusz`)

> **[SZKIC AI — na podstawie `incydent.md`, nieprzeczytany/niepoprawiony przez uczestnika]**
> Format bez szukania winnych (blameless). Wszystkie znaczniki `[AI, niepotwierdzone w dzienniku]` oznaczają zdania, które są wnioskiem/propozycją modelu, a nie faktem potwierdzonym komendą w dzienniku — uczestnik ma je zweryfikować, poprawić albo usunąć.

## Podsumowanie

Orders-api w Kantynie (namespace `mateusz`) przestał być gotowy (`/readyz` timeout) od ok. **2026-10-07 15:13 CEST**, co powodowało wolne ładowanie menu i sporadyczne błędy 500 przy składaniu zamówień. Przyczyną było wyczerpanie puli połączeń do PostgreSQL (10/10) spowodowane flagą runtime `db_pool_leak=true` ustawioną bezpośrednio na żywym ConfigMapie klastra, poza repo/Helm release (które miały poprawną wartość `false`). Usługę przywrócono o **15:59 CEST** przez `helm upgrade --reuse-values` (reset ConfigMapy) i restart `deployment/kantyna-orders-api` (zwolnienie już wyciekniętych połączeń). `setup/check.sh` → SUKCES 11/11 po naprawie.

## Wpływ

- Oba pody `kantyna-orders-api` (2/2) były `0/1 Ready` i wypadły z endpointów Service przez ok. **46 minut** (15:13–15:59 CEST).
- Część requestów (w tym do menu) kończyła się błędem 500 (`psycopg_pool.PoolTimeout: couldn't get a connection after 30.00 sec`) po ok. 30s oczekiwania.
- Ruch mierzony przez `http_requests_total` spadł z ~1.8 do ~0.68 req/s w momencie nasycenia poola.
- [AI, niepotwierdzone w dzienniku] Dokładna liczba dotkniętych użytkowników i to, czy ruch w tym oknie pochodził od realnych uczestników czy głównie od `loadgen`, nie zostały ustalone — dziennik nie zawiera tego rozróżnienia.

## Oś czasu

| Czas (CEST) | Zdarzenie | Źródło w dzienniku |
|---|---|---|
| ~15:13 | Pierwszy błąd aplikacji `PoolTimeout`; pool połączeń DB skacze do 10/10 na obu podach orders-api | Loki (`PoolTimeout`), Prometheus (`db_pool_connections_in_use`) |
| 15:44 | Wykrycie: `orders-api` `0/1 Ready` na obu podach; inne serwisy zdrowe | `kubectl get pods` |
| 15:44 | Potwierdzenie: `Readiness probe failed ... context deadline exceeded` | `kubectl get events` |
| 15:44 | ConfigMap `kantyna-flags`: `db_pool_leak=true`, `slow_menu_query=true` dla orders-api | `kubectl get configmap -o yaml` |
| 15:44–15:49 | Potwierdzenie przyczyny: pool 100% wykorzystany na obu podach; logi `PoolTimeout`; wykluczono CPU/RAM i niedawny deploy Helma jako przyczynę | Prometheus, Loki, `kubectl top`, `helm history` |
| ~15:50 | Szkic pierwszego komunikatu (do poprawy przez uczestnika) | sekcja „Krok 2" dziennika |
| 15:55 | Ustalenie: repo i Helm release mają poprawne wartości flag (`false/false`) — to dryf konfiguracji na klastrze, nie błąd w kodzie | `git log`/`git diff`, `helm get values --all` |
| 15:57 | Mitygacja 1: `helm upgrade --reuse-values` resetuje ConfigMap do `false/false` | REVISION 6 |
| 15:58 | Stwierdzono, że sam reset flagi nie przywraca Ready — już wyciekniętych połączeń nie zwalnia | `kubectl get pods`, logi nadal `PoolTimeout` |
| 15:58 | Mitygacja 2: `kubectl rollout restart deployment/kantyna-orders-api` | rollout status: successfully rolled out |
| 15:59 | Weryfikacja: pool czysty na nowych podach, `setup/check.sh` → SUKCES 11/11 | Prometheus, `setup/check.sh` |

## Przyczyna źródłowa

**Potwierdzone faktem:** ConfigMap `kantyna-flags` w namespace `mateusz` miał `orders-api.db_pool_leak=true` i `orders-api.slow_menu_query=true`, podczas gdy zarówno repo (`app/deploy/helm/kantyna/values.yaml`) jak i zapisane wartości Helm release (`helm get values --all`, rev. 5) miały `false` dla obu flag. Oznacza to, że ConfigMap został zmieniony bezpośrednio na klastrze, poza pipeline'em i poza git history tego repo.

**Mechanizm (potwierdzony logami/metrykami):** `db_pool_leak=true` powoduje, że orders-api nie zwraca połączeń psycopg do poola; pool (rozmiar 10) wypełnił się skokowo (nie stopniowo); kolejne żądania, w tym `/readyz`, czekały 30s na wolne połączenie i kończyły się `PoolTimeout` — część jako błąd 500 dla użytkownika, a brak odpowiedzi `/readyz` wykluczał pody z endpointów Service.

**Luka w systemie/procesie (nie błąd osoby):** [AI, niepotwierdzone w dzienniku] brak jest mechanizmu, który wykrywałby i/lub blokował ręczną zmianę ConfigMapy zarządzanej przez Helm z pominięciem pipeline'u — to pozwoliło, by zmiana flagi (prawdopodobnie część wcześniejszego ćwiczenia z wstrzykiwaniem awarii, np. lab02) pozostała aktywna bez śladu w repo. **Kto i kiedy faktycznie zmienił ConfigMap — nieustalone**, w dzienniku nie ma na to dowodu (brak dostępu do audytu API klastra w tej sesji).

## Co zadziałało

- Metryki Prometheus (`db_pool_connections_in_use`/`db_pool_size`) i logi Loki pozwoliły szybko i jednoznacznie potwierdzić przyczynę bez zgadywania.
- Runbook `KantynaDBPoolExhausted.md` trafnie opisywał objawy i podał bezpieczne kroki remediacji (restart, reset flag), które faktycznie zadziałały.
- Porównanie repo/Helm release z żywym stanem klastra (`git diff`, `helm get values --all`) zapobiegło niepotrzebnemu/mylącemu commitowi — ujawniło, że problem był czysto operacyjny (dryf), nie błąd kodu.

## Co nie zadziałało

- Jeden krok mitygacji (`helm upgrade --reuse-values`) nie wystarczył — flaga wróciła do `false`, ale już wyciekniętych połączeń nie zwolniła; potrzebny był dodatkowy restart deploymentu. [AI, niepotwierdzone w dzienniku] Runbook o tym wspomina pośrednio (dwie osobne pozycje w tabeli remediacji), ale nie podkreśla wprost, że obie czynności mogą być potrzebne razem — warto to doprecyzować w runbooku.
- Nie udało się wykonać kroku 2 runbooka (`pg_stat_activity` przez `kubectl exec`) — zablokowane uprawnieniami tej sesji (`.claude/settings.json` → `deny`). Nie potwierdzono więc bezpośrednio mechanizmu "nie zwracania połączenia" po stronie bazy, tylko pośrednio przez logi aplikacji.
- Brak automatycznego wykrywania dryftu konfiguracji między Helm release/repo a żywym stanem klastra — incydent wykryto ręcznie (`setup/check.sh`/dashboard), nie przez alert.

## Akcje (właściciel, termin)

[AI — propozycje do zatwierdzenia/przypisania przez uczestnika; właściciele i terminy to placeholdery]

| Akcja | Właściciel | Termin |
|---|---|---|
| Alert Prometheus na `db_pool_connections_in_use/db_pool_size > 0.9` przez 5 min (zgodnie z warunkiem runbooka) | TBD | TBD |
| Wykrywanie dryftu: porównanie `helm get values`/ConfigMap z żywym stanem klastra (np. okresowy diff albo polityka blokująca ręczne `kubectl patch/edit` na zasobach zarządzanych przez Helm) | TBD | TBD |
| Ustalić w audycie klastra (K8s audit log / CloudTrail), kto i kiedy zmienił ConfigMap `kantyna-flags` 2026-10-07 przed 15:13 — potwierdzić lub wykluczyć, że to ślad po lab02 | TBD | TBD |
| Doprecyzować w `KantynaDBPoolExhausted.md`, że reset flagi i restart orders-api to zwykle dwa osobne, oba potrzebne kroki | TBD | TBD |
| Zmierzyć osobno wpływ `slow_menu_query` (p95 dla handlera menu) — metryka nie została poprawnie odpytana w tym incydencie | TBD | TBD |

## Pytania otwarte

- Kto/co zmieniło ConfigMap `kantyna-flags` bezpośrednio na klastrze i dokładnie kiedy przed 15:13 CEST?
- Czy ruch w oknie incydentu pochodził głównie od `loadgen`, czy byli nim dotknięci realni uczestnicy?
- Jaki był rzeczywisty, osobny wpływ `slow_menu_query=true` na p95 menu (niezależnie od wyczerpania poola)?
- Czy mechanizm „nie zwracania połączenia" pod `db_pool_leak=true` to czysta symulacja testowa, czy odwzorowuje realny wzorzec błędu, który mógłby wystąpić w kodzie produkcyjnym bez udziału flagi?
