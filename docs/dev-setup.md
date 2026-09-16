# Lokales Dev Setup

Der App Store ist ein Web-System, in dem Studierende und Dozierende vorgefertigte Cloud-Apps (Packer + Terraform in einem Git-Repo) per Klick auf OpenStack ausrollen. Lokal läuft alles in Docker: Vue-Frontend, FastAPI-Backend, Celery-Worker, Keycloak als Identity Provider sowie PostgreSQL, RabbitMQ und Redis als Infrastruktur. Diese Anleitung führt von einem leeren Arbeitsverzeichnis bis zum eingeloggten Browser.

## Voraussetzungen

| Werkzeug | Version | Anmerkung |
|---|---|---|
| Docker Desktop (oder Docker Engine) | 24.x oder neuer | Compose v2 ist enthalten |
| Docker Compose | v2 (`docker compose`, nicht `docker-compose`) | Über Docker Desktop bereits dabei |
| Git | 2.x | |
| Python 3 | 3.11+ | Wird einmalig zum Generieren des Fernet-Keys gebraucht |
| GNU Make | Pflicht | Alle Schritte sind als `make`-Targets ausgelegt — wer kein Make hat, kann die zugrunde liegenden Befehle direkt aus dem [Makefile](./Makefile) ablesen |
| Freie Ports | 5173, 8000, 8080, 5432, 5672, 15672, 6379, 5050, 55433 | Bei Konflikt den entsprechenden Port in der `.env` überschreiben (z. B. `KEYCLOAK_PORT=8180`) — die zugehörige `VITE_*_URL` ebenfalls anpassen |


Ein GitHub Personal Access Token mit `repo`-Scope ist empfohlen. Ohne Token funktioniert das Setup, aber Deployments aus privaten App-Repos schlagen fehl.


## Schritt 1: Repository klonen

```bash
mkdir app-store
cd app-store
git clone https://github.com/NextAppStore/frontend
git clone https://github.com/NextAppStore/backend
git clone https://github.com/NextAppStore/worker
git clone https://github.com/NextAppStore/deployment
git clone https://github.com/NextAppStore/.github org-docs # optional (nur Dokumentation)
cd deployment
```

Alle weiteren Befehle werden aus `app-store/deployment` ausgeführt — dort liegen `Makefile`, `docker-compose.dev.yml` und `.env.example`.

Verzeichnislayout nach dem Klonen:

```
appstore/
├── frontend/        # Vue 3 + Vite
├── backend/         # FastAPI + Alembic
├── worker/          # Celery + Terraform/Packer
├── deployment/      # docker-compose.dev.yml, Makefile, .env.example, seed/, keycloak/
└── org-docs/        # Dokumentation
```

## Schritt 2: `.env` anlegen

> [!TIP]
> Auf Anfrage stellen wir eine fertig befüllte `.env` bereit. In dem Fall genügt es, die Datei direkt nach `deployment/.env` zu legen und mit Schritt 3 weiterzumachen — die folgenden Unterpunkte 2a–2d sind dann nicht nötig.

```bash
make env
```

Das kopiert `.env.example` nach `.env`. Die Vorlage enthält nur die Felder, die für Dev nötig sind — alle anderen Werte (DB-Passwörter, Ports, URLs) haben sinnvolle Defaults in `docker-compose.dev.yml` und müssen nicht in der `.env` stehen.

### 2a. `CREDENTIAL_ENCRYPTION_KEY` (Pflicht, sonst startet der Stack nicht)

Symmetrischer Fernet-Key, den Backend und Worker teilen, um OpenStack-Credentials zu ver-/entschlüsseln. Beim Container-Start wird er zwingend geprüft — fehlt er, bricht `docker compose up` mit der Meldung `CREDENTIAL_ENCRYPTION_KEY is required` ab.

Generieren:

```bash
python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'
```

Die Ausgabe — ein url-safe-base64-String, der mit `=` endet — als `CREDENTIAL_ENCRYPTION_KEY` in die `.env` eintragen.

Falls `cryptography` lokal nicht installiert ist:

```bash
pip install cryptography
```

### 2b. `KEYCLOAK_CLIENT_SECRET` (Pflicht für Login)

Das Secret kann erst nach dem ersten Keycloak-Start aus dem Admin-UI geholt werden. Für den Erst-Start in `.env` einfach einen Platzhalter eintragen:

```
KEYCLOAK_CLIENT_SECRET=changeme
```

In Schritt 5 wird der echte Wert nachgetragen.

### 2c. `GIT_ACCESS_TOKEN` (empfohlen)

GitHub Personal Access Token mit `repo`-Scope. Anlegen unter: GitHub → Settings → Developer settings → Personal access tokens (classic) → Generate new token.

```
GIT_ACCESS_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Für reines Testen ohne private Repos darf der Wert leer bleiben.

### 2d. `SMTP_*` (optional)

E-Mail-Benachrichtigungen (Approval-Workflow). Wenn nicht gebraucht, einfach `SMTP_ENABLED=false` lassen und die anderen Felder leer. Für Gmail ein App-Password verwenden, nicht das Account-Passwort.

## Schritt 3: Stack starten

```bash
make dev-up
```

Das startet zwölf Container: `frontend`, `backend`, `worker`, `keycloak`, `keycloak-postgres`, `postgres`, `postgres-test`, `postgres-tfstate`, `redis`, `rabbitmq`, `pgadmin`.

Beim ersten Start dauert der Boot 1–3 Minuten (Image-Pull + Keycloak-Init). Bevor Schritt 4 läuft, sicherstellen dass Keycloak fertig ist:

```bash
make dev-logs-keycloak | grep -i "listening on\|started in"
```

Erwartete Zeilen:

```
Listening on: http://0.0.0.0:8080
... started in XX.XXXs
```


## Schritt 4: Migrationen und Seed-Daten

Schema anlegen:

```bash
make migrate-dev
```

Seed-Daten einspielen (Realm-Import, Test-User, Beispiel-Apps, Kurse):

```bash
make seed-data
```

Das Skript ist idempotent — wiederholtes Ausführen schadet nicht und ist bei Timing-Problemen die richtige Antwort.

## Schritt 5: Echtes `KEYCLOAK_CLIENT_SECRET` eintragen

Der mit Schritt 4 importierte Realm bringt den `appstore-backend`-Client mit dem maskierten Secret `**********` aus dem Realm-Export mit. Das ist kein gültiger Wert — das echte Secret muss in Keycloak einmalig neu erzeugt und in die `.env` übernommen werden.

Vorbereitung: Der `master`-Realm verlangt per Default HTTPS, weshalb http://localhost:8080/admin sonst mit "HTTPS required" abbricht. Einmal abschalten:

```bash
make keycloak-disable-ssl
```

Anschließend:

1. http://localhost:8080/admin im Browser öffnen.
2. Mit `admin` / `admin` einloggen.
3. Oben links im Realm-Switcher von `master` auf `dhbw` umstellen.
4. Links auf "Clients" → `appstore-backend` öffnen.
5. Reiter "Credentials" → Button **"Regenerate"** klicken (das Feld zeigt vorher buchstäblich `**********` — das ist die Maskierung aus dem Realm-Export, kein nutzbarer Wert).
6. Den neu generierten Wert kopieren und in `.env` eintragen:

   ```
   KEYCLOAK_CLIENT_SECRET=<kopierter-wert>
   ```

7. Backend neu starten:

   ```bash
   make dev-restart-backend
   ```

Ab jetzt kann das Backend Tokens validieren.

## Verifikation

Smoke-Test per Make (curlt drei Endpoints):

```bash
make health
```

Oder im Browser einzeln öffnen:

| Dienst | URL | Erwartet |
|---|---|---|
| Frontend | http://localhost:5173 | Click-n-Deploy Login-Seite |
| Backend Swagger | http://localhost:8000/docs | OpenAPI-UI mit Endpoints `/users`, `/apps`, `/deployments` |
| Backend Health | http://localhost:8000/health | `{"status":"ok"}` |
| Keycloak Admin | http://localhost:8080/admin | Keycloak Welcome, Login `admin` / `admin` |
| Keycloak OIDC Discovery | http://localhost:8080/realms/dhbw/.well-known/openid-configuration | JSON mit `issuer: http://localhost:8080/realms/dhbw` |
| RabbitMQ UI | http://localhost:15672 | Login `admin` / `admin`, Queue `celery` mit zwei Connections |
| pgAdmin | http://localhost:5050 | Login `admin@admin.com` / `admin` |

Token-Check auf der Kommandozeile:

```bash
make keycloak-token USER=tobias.admin@dhbw.de PASS=1234
```

Liefert die ersten 50 Zeichen eines JWT. Wenn stattdessen `invalid_grant` kommt: Seed lief nicht durch (Schritt 4 wiederholen).

## Login

Im Browser http://localhost:5173 öffnen, "Login" klicken, mit einem der folgenden Test-User anmelden. Passwort ist für ALLE Seed-User `1234`.

**Administrator**

| E-Mail | Passwort | Rolle |
|---|---|---|
| `tobias.admin@dhbw.de` | `1234` | admin |

**Dozierende**

| E-Mail | Passwort |
|---|---|
| `michael.eichberg@dhbw.de` | `1234` |
| `henning.pagnia@dhbw.de` | `1234` |
| `sarah.detzler@dhbw.de` | `1234` |
| `frank.hubert@dhbw.de` | `1234` |
| `andrea.bauer@dhbw.de` | `1234` |
| `thomas.wagner@dhbw.de` | `1234` |

**Studierende**

| E-Mail | Passwort | Kurs |
|---|---|---|
| `luca.baeck@dhbw.de` | `1234` | WI SE B 23 |
| `felix.erhard@dhbw.de` | `1234` | WI SE B 23 |
| `okan.soenmez@dhbw.de` | `1234` | WI SE B 23 |
| `monika.piano@dhbw.de` | `1234` | WI SE B 23 |
| `anna.schulz@dhbw.de` | `1234` | WI SE B 24 |
| `jan.krueger@dhbw.de` | `1234` | INF TI 23 |

Hinweise zur E-Mail-Konvention: `<vorname>.<nachname>@dhbw.de`, alles klein, Umlaute werden ersetzt (`ä → ae`, `ö → oe`, `ü → ue`, `ß → ss`). Der Keycloak-Admin (`admin` / `admin`) ist NICHT identisch mit den Realm-Usern — er funktioniert nur unter http://localhost:8080/admin, nicht im Frontend.

## Stoppen, Neustarten, Zurücksetzen

### Sauber stoppen (Daten bleiben)

```bash
make dev-down
```

Container weg, Volumes (DBs, Keycloak-Daten) bleiben. Beim nächsten `make dev-up` startet alles im Zustand vor dem Stopp.

### Nur pausieren (schnellster Re-Start)

```bash
make dev-stop      # stoppt, Container bleiben
make dev-up        # läuft wieder
```

### Einzelnen Dienst neu starten

```bash
make dev-restart-backend
make dev-restart-frontend
make dev-restart-worker
```

### Logs verfolgen

```bash
make dev-logs                # alle
make dev-logs-backend        # nur Backend
make dev-logs-worker         # nur Worker
make dev-logs-keycloak       # nur Keycloak
```

### Komplett zurücksetzen (alle Daten weg)

```bash
make seed-reset
```

Das ruft intern `db-reset-dev` + `keycloak-reset` + `seed-data` — danach ist der Stand identisch zum frischen Erst-Setup.

### Maximal aufräumen (auch lokal gebaute Images löschen)

```bash
make clean-all
```

Nach `clean-all` baut der nächste `make dev-up` alle Images neu (kann 5–10 Minuten dauern).
