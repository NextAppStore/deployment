# Produktives Setup

Der App Store ist ein Web-System, in dem Studierende und Dozierende vorgefertigte Cloud-Apps (Packer + Terraform in einem Git-Repo) per Klick auf OpenStack ausrollen. In Prod läuft alles auf einer einzelnen Ubuntu-VM in zehn Containern: nginx als TLS-Terminator, Vue-Frontend, FastAPI-Backend, Celery-Worker, Keycloak als Identity Provider sowie PostgreSQL (App + Terraform-State + Keycloak), RabbitMQ und Redis als Infrastruktur. Alle Service-Images werden zur Laufzeit aus GHCR gezogen — auf der VM wird nichts gebaut. Diese Anleitung führt von einer leeren Ubuntu-VM bis zum eingeloggten Browser unter `https://<VM-IP>`.

> [!TIP]
> Im CI-Betrieb läuft der Staging-Stack automatisch über
> `infrastructure/ansible/staging.yml`. Diese Anleitung beschreibt den
> manuellen Weg für eine isolierte Prod-Instanz auf einer eigenen VM,
> die du per IP erreichst.

## Voraussetzungen

| Werkzeug | Version | Anmerkung |
|---|---|---|
| Ubuntu Server | 22.04 LTS | Auch 24.04 funktioniert |
| Docker Engine | 24.x oder neuer | Compose v2 ist enthalten |
| Docker Compose | v2 (`docker compose`, nicht `docker-compose`) | Über Docker Engine bereits dabei |
| Git | 2.x | |
| Python 3 | 3.11+ | Wird einmalig zum Generieren der Secrets gebraucht |
| OpenSSL | 3.x | Für das Self-signed-Zertifikat (Schritt 3) |
| GNU Make | Pflicht | Alle Schritte sind als `make`-Targets ausgelegt — wer kein Make hat, kann die zugrunde liegenden Befehle direkt aus dem [Makefile](../Makefile) ablesen |
| VM-IP | z. B. `203.0.113.42` | Die öffentliche IP, unter der die VM erreichbar ist |

Ein GitHub Personal Access Token mit `repo`-Scope ist **Pflicht** — der Worker klont damit private App-Repos und das Backend verifiziert GitHub-Hooks.

> [!NOTE]
> `<VM-IP>` ist in dieser Anleitung ein Platzhalter — überall durch die echte IP ersetzen (z. B. `141.72.12.185`). In Bash würde `<VM-IP>` als Redirect interpretiert und mit `syntax error near unexpected token` brechen.

## Schritt 0: VM vorbereiten

Ein frisches Ubuntu-Cloud-Image hat weder Docker noch Make installiert. Beides nachholen:

```bash
sudo apt update
sudo apt install -y git make ca-certificates curl gnupg
```

Docker Engine + Compose v2 aus dem offiziellen Docker-Repo (Ubuntus `docker.io`-Paket ist meist mehrere Versionen hinter dem, was Compose v2 voraussetzt):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Den aktuellen User in die `docker`-Gruppe legen, damit Docker-Befehle ohne `sudo` laufen — danach **neu einloggen** (`exit` + `ssh …`), sonst greift die Gruppenmitgliedschaft noch nicht:

```bash
sudo usermod -aG docker $USER
exit
```

Nach dem Wiedereinloggen Smoke-Test:

```bash
docker --version
docker compose version
make --version
```

## Schritt 1: Repository auf die VM klonen

```bash
sudo mkdir -p /opt/app-store
sudo chown $USER:$USER /opt/app-store
cd /opt/app-store
git clone https://github.com/NextAppStore/deployment
cd deployment
```

Alle weiteren Befehle werden aus `/opt/app-store/deployment` ausgeführt — dort liegen `Makefile`, `docker-compose.prod.yml`, das `nginx/`-Verzeichnis und der Keycloak-Realm-Export. `frontend/`, `backend/` und `worker/` werden in Prod nicht geklont, weil die Images aus GHCR gezogen werden.

> [!IMPORTANT]
> Alle `make`-Targets in dieser Anleitung müssen aus `/opt/app-store/deployment` laufen — Make sucht das `Makefile` im aktuellen Verzeichnis. Wenn der Prompt `ubuntu@prod-test:~$` zeigt (Home-Verzeichnis), kommt `make: *** No rule to make target '…'.  Stop.`. Vorher `cd /opt/app-store/deployment`.

## Schritt 2: `.env` anlegen

> [!TIP]
> Auf Anfrage stellen wir eine fertig befüllte `.env` bereit. In dem Fall genügt es, die Datei direkt nach `deployment/.env` zu legen, alle Vorkommen von `<VM-IP>` durch die IP der VM zu ersetzen, auf der der App Store läuft — und mit Schritt 3 weiterzumachen. Die folgenden Unterpunkte 2a–2j sind dann nicht nötig.

`docker-compose.prod.yml` markiert sämtliche kritischen Werte als `${VAR:?... is required}` — der Stack startet erst, wenn jeder Pflicht-Wert gesetzt ist. Anders als in Dev gibt es keine `.env.example` mit Defaults; jede Variable muss explizit gefüllt werden.

```bash
touch .env
chmod 600 .env
```

Die folgenden Felder in `.env` eintragen. Reihenfolge ist egal, Kommentare mit `#` sind erlaubt.

### 2a. VM-IP als Variable (zur einfacheren Wiederverwendung unten)

Im Folgenden verwende ich `<VM-IP>` als Platzhalter — ersetze ihn überall durch deine tatsächliche IP-Adresse, z. B. `203.0.113.42`. Wenn du auf derselben Maschine testest, kann auch `localhost` stehen.

### 2b. Datenbank-Credentials (Pflicht)

Drei voneinander isolierte Postgres-Instanzen — Anwendung, Terraform-State (Worker), Keycloak. Jede bekommt eigene Credentials. Passwörter generieren mit `openssl rand -base64 24`.

```
DB_USER=appstore
DB_PASSWORD=<random>
DB_NAME=appstore

TFSTATE_DB_USER=tfstate
TFSTATE_DB_PASSWORD=<random>
TFSTATE_DB_NAME=tfstate

KEYCLOAK_DB_USER=keycloak
KEYCLOAK_DB_PASSWORD=<random>
KEYCLOAK_DB_NAME=keycloak
```

### 2c. RabbitMQ-Credentials (Pflicht)

```
RABBITMQ_USER=appstore
RABBITMQ_PASSWORD=<random>
RABBITMQ_VHOST=/
```

### 2d. Keycloak-Admin (Pflicht)

```
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=<random>
```

Der Admin-User wird beim ersten Keycloak-Boot im `master`-Realm angelegt — danach lässt sich das Passwort ohne DB-Reset nicht mehr ändern. Den Wert gut sichern.

### 2e. `SECRET_KEY` (Pflicht)

Symmetrischer Schlüssel für die Backend-JWTs. In Dev hat dieser Wert einen Default — in Prod muss er explizit gesetzt werden.

```bash
python3 -c 'import secrets; print(secrets.token_hex(32))'
```

```
SECRET_KEY=<output>
```

### 2f. `CREDENTIAL_ENCRYPTION_KEY` (Pflicht, sonst startet der Stack nicht)

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

### 2g. `KEYCLOAK_CLIENT_SECRET` (Pflicht für Login)

Das Secret kann erst nach dem ersten Keycloak-Start aus dem Admin-UI geholt werden. Für den Erst-Start in `.env` einfach einen Platzhalter eintragen:

```
KEYCLOAK_CLIENT_SECRET=changeme
```

In Schritt 6 wird der echte Wert nachgetragen.

### 2h. `GIT_ACCESS_TOKEN` (Pflicht)

GitHub Personal Access Token mit `repo`-Scope. Wird vom Worker beim Klonen privater App-Repos und vom Backend für Hook-Verifikation verwendet. Anlegen unter: GitHub → Settings → Developer settings → Personal access tokens (classic) → Generate new token.

```
GIT_ACCESS_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### 2i. URLs (Pflicht)

Alle URLs zeigen auf deine VM. nginx terminiert HTTPS auf 443 und routet `/api` an das Backend, `/realms` und `/admin` an Keycloak, alles andere an das Frontend — deshalb laufen alle drei `VITE_*_URL`-Werte über dieselbe Origin:

```
APP_BASE_URL=https://<VM-IP>
CORS_ORIGINS=https://<VM-IP>

VITE_APP_URL=https://<VM-IP>
VITE_API_URL=https://<VM-IP>/api
VITE_KEYCLOAK_URL=https://<VM-IP>
```

> [!TIP]
> Wenn du eine Domain hast und Schritt 3 / Option A (ACME) nutzt, überall `<VM-IP>` durch `<TLS_DOMAIN>` ersetzen.

### 2j. `SMTP_*` (optional)

E-Mail-Benachrichtigungen (Approval-Workflow). Wenn nicht gebraucht, einfach `SMTP_ENABLED=false` lassen und die anderen Felder leer. Für Gmail ein App-Password verwenden, nicht das Account-Passwort.

```
SMTP_ENABLED=false
SMTP_HOST=smtp.gmail.com
SMTP_PORT=465
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM_EMAIL=
SMTP_FROM_NAME=Click-n-Deploy
```

## Schritt 3: TLS-Zertifikat erzeugen

In Dev terminiert das Frontend HTTP direkt; in Prod sitzt `nginx-prod` davor und erwartet zwei TLS-Dateien unter `nginx/certs/`. Es gibt zwei Wege, diese Dateien zu erzeugen — wähle einen:

### Option A: Echtes Zertifikat über den DHBW-ACME-Server (empfohlen, sobald eine Domain existiert)

Voraussetzung ist eine DNS-Zone unter `*.users.dhbw.site` (z. B. `s242808-at-student-dhbw-mannheim-de.users.dhbw.site`) mit einem TSIG-Key für DNS-01-Updates — beides stellt DHBW im Self-Service-Portal bereit.

In `.env` eintragen:

```
TLS_DOMAIN=s242808-at-student-dhbw-mannheim-de.users.dhbw.site
ACME_ACCOUNT_EMAIL=s242808@student.dhbw-mannheim.de
DNS_TSIG_KEY="key \"user-key-...\" { algorithm hmac-sha512; secret \"...\"; };"
```

`TLS_DOMAIN` ist die **nackte** Zone ohne `www.`-Präfix — Ansible/Make stellen automatisch ein Zertifikat für `TLS_DOMAIN` **und** `www.TLS_DOMAIN` aus; ein `www.` in `TLS_DOMAIN` selbst würde ein doppeltes `www.www....` erzeugen.

`DNS_TSIG_KEY` ist der komplette `key { ... }`-Block aus dem DHBW-Portal, als **eine** Zeile in `.env` (Zeilenumbrüche im Original einfach durch Leerzeichen ersetzen — BIND-Syntax ist whitespace-tolerant). Wichtig: der ganze Wert muss in doppelte Anführungszeichen gefasst werden und jedes `"` darin mit `\"` escaped werden — sowohl `make prod-cert-acme` (sourced `.env` per Bash) als auch der Ansible-Task erwarten diese Schreibweise. Ein unescapter Wert mit rohen `"` und `{` bricht das Sourcing mit `syntax error near unexpected token`.

```bash
make prod-cert-acme
```

Das Target installiert `acme.sh` (idempotent), schreibt den TSIG-Key nach `~/.acme-dns/tsig.key`, registriert den ACME-Account und stellt ein Zertifikat für `TLS_DOMAIN` (+ die `www.`-Variante) per DNS-01 (`nsupdate` gegen `ns.cloud-ns.dhbw-mannheim.de.`) beim DHBW-Server (`https://certificates.dhbw.cloud`) aus. Ergebnis landet direkt unter `nginx/certs/` — kein Browser-Warnhinweis mehr, da der Server-Betreiber (DHBW) als CA vertraut ist. Erneuerung läuft automatisch über den von `acme.sh` angelegten Cronjob; `make prod-cert-acme` erneut ausführen reicht als manueller Trigger.

Mit dieser Option **`APP_BASE_URL`, `CORS_ORIGINS` und die drei `VITE_*_URL`-Werte in Schritt 2i auf `https://<TLS_DOMAIN>` setzen statt auf `https://<VM-IP>`.**

### Option B: Self-signed-Zertifikat (Fallback, wenn nur eine IP verfügbar ist)

```bash
make prod-cert-self-signed PROD_HOST=<VM-IP>
```

Das Target legt das Verzeichnis an, erzeugt ein 10 Jahre gültiges Zertifikat mit `CN=<VM-IP>` und `subjectAltName=IP:<VM-IP>,DNS:<VM-IP>`, setzt die richtigen Permissions und gibt das Ablaufdatum aus. Resultat:

```
nginx/certs/cert.pem      # Public cert
nginx/certs/key.pem       # Private key, 600
```

Browser zeigen beim ersten Aufruf eine Sicherheitswarnung („Verbindung nicht sicher") — Ausnahme einmal bestätigen und gut.

## Schritt 4: Stack starten

```bash
make prod-up
```

Anders als in Dev wird hier nichts gebaut — das Target lädt zunächst alle `:latest`-Images aus GHCR (`pull_policy: always`) und startet danach die zehn Container: `nginx`, `frontend`, `backend`, `worker`, `keycloak`, `keycloak-postgres`, `postgres`, `postgres-tfstate`, `redis`, `rabbitmq`. Erstdurchlauf dauert je nach Bandbreite 2–5 Minuten.

Status prüfen:

```bash
make prod-ps
```

Alle zehn Container sollten `running (healthy)` melden, sobald die Healthchecks durchlaufen sind. Falls ein Container im Crash-Loop steckt, gezielt die Logs anschauen (in Prod gibt es keine `dev-logs-<svc>`-Aliasse, der Dienst wird per `SVC=` mitgegeben):

```bash
make prod-logs SVC=backend
make prod-logs SVC=keycloak
```

Bevor Schritt 5 läuft, sicherstellen dass Keycloak fertig hochgefahren ist:

```bash
make prod-logs SVC=keycloak | grep -i "listening on\|started in"
```

Erwartete Zeilen:

```
Listening on: http://0.0.0.0:8080
... started in XX.XXXs
```

`Ctrl-C` beendet das Tail.

## Schritt 5: Migrationen und Seed-Daten

Anders als in Dev sind Migrationen in Prod kein Teilschritt des Seeds, sondern ein eigenes Target — eine Migrate-Init-Container-Variante würde Fehler im Compose-Output verstecken. Schema anlegen:

```bash
make prod-migrate
```

Seed-Daten einspielen (Realm-Import, Test-User, Beispiel-Apps, Kurse):

```bash
make prod-seed
```

Das Skript ist idempotent — wiederholtes Ausführen schadet nicht und ist bei Timing-Problemen die richtige Antwort.

## Schritt 5.5: Keycloak-Client-URLs auf `APP_BASE_URL` setzen

Der mit `make prod-seed` importierte Realm-Export stammt aus einer Dev-Umgebung und enthält hartcodierte `http://localhost:3000` / `localhost:5173` / `localhost:8000` als Redirect-URIs, Web-Origins und Post-Logout-URIs der beiden Clients. Ohne diesen Schritt lehnt Keycloak **jeden Login/Logout** mit `Invalid redirect uri` ab.

```bash
make prod-set-keycloak-urls
```

Liest `APP_BASE_URL` aus der `.env`, loggt sich als Admin bei Keycloak ein und patcht für die beiden Clients:

- **`appstore-frontend`**: `redirectUris`, `webOrigins`, `post.logout.redirect.uris`
- **`appstore-backend`**: `rootUrl`, `adminUrl`, `redirectUris`, `webOrigins`

Idempotent — kann beliebig oft laufen. Erneut aufrufen, wenn sich `APP_BASE_URL` ändert (z. B. Umstieg von IP auf Domain).

> [!NOTE]
> Bewusst kein Teil von `prod-seed`: wer in Keycloak manuell zusätzliche Redirect-URIs ergänzt hat (z. B. fürs lokale Testen vom Mac aus gegen die Prod-VM), würde die sonst bei jedem Seed-Lauf verlieren. Dieses Target überschreibt die Listen explizit — Aufruf ist eine bewusste Entscheidung.

## Schritt 6: Echtes `KEYCLOAK_CLIENT_SECRET` eintragen

Der mit Schritt 5 importierte Realm bringt den `appstore-backend`-Client mit dem maskierten Secret `**********` aus dem Realm-Export mit. Das ist kein gültiger Wert — das echte Secret muss in Keycloak einmalig neu erzeugt und in die `.env` übernommen werden.

Anders als in Dev entfällt der Vorlauf mit `make keycloak-disable-ssl` — nginx terminiert HTTPS schon, der `master`-Realm akzeptiert die Admin-UI direkt.

1. `https://<VM-IP>/admin` im Browser öffnen (Cert-Warnung akzeptieren).
2. Mit `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` aus Schritt 2d einloggen.
3. Oben links im Realm-Switcher von `master` auf `dhbw` umstellen.
4. Links auf "Clients" → `appstore-backend` öffnen.
5. Reiter "Credentials" → Button **"Regenerate"** klicken (das Feld zeigt vorher buchstäblich `**********` — das ist die Maskierung aus dem Realm-Export, kein nutzbarer Wert).
6. Den neu generierten Wert kopieren und in `.env` eintragen:

   ```
   KEYCLOAK_CLIENT_SECRET=<kopierter-wert>
   ```

7. Backend neu starten (in Prod gibt es keinen `dev-restart-backend`-Alias, der Dienst wird per `SVC=` mitgegeben):

   ```bash
   make prod-restart SVC=backend
   ```

Ab jetzt kann das Backend Tokens validieren.

## Verifikation

In Dev gibt es `make health`, das drei Endpoints curlt — in Prod fehlt das Target, weil nginx HTTPS mit Self-signed-Cert terminiert. Stattdessen einzeln per `curl -k` (ignoriert die Cert-Warnung) oder im Browser prüfen:

```bash
curl -k https://<VM-IP>/health
curl -k https://<VM-IP>/api/health
curl -k https://<VM-IP>/realms/dhbw/.well-known/openid-configuration | head
```

Oder im Browser einzeln öffnen:

| Dienst | URL | Erwartet |
|---|---|---|
| Frontend | `https://<VM-IP>` | Click-n-Deploy Login-Seite |
| Backend Swagger | `https://<VM-IP>/api/docs` | OpenAPI-UI mit Endpoints `/users`, `/apps`, `/deployments` |
| Backend Health | `https://<VM-IP>/api/health` | `{"status":"ok"}` |
| Keycloak Admin | `https://<VM-IP>/admin` | Keycloak Welcome, Login mit `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` aus Schritt 2d |
| Keycloak OIDC Discovery | `https://<VM-IP>/realms/dhbw/.well-known/openid-configuration` | JSON mit `issuer: https://<VM-IP>/realms/dhbw` |

RabbitMQ-UI und pgAdmin sind in Prod nicht über nginx exponiert (kein Port-Mapping nach außen); für Debugging per Container-Shell oder SSH-Tunnel zugreifen.

## Login

Im Browser `https://<VM-IP>` öffnen, "Login" klicken, mit einem der folgenden Test-User anmelden. Passwort ist für ALLE Seed-User `1234`.

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

Hinweise zur E-Mail-Konvention: `<vorname>.<nachname>@dhbw.de`, alles klein, Umlaute werden ersetzt (`ä → ae`, `ö → oe`, `ü → ue`, `ß → ss`). Der Keycloak-Admin (`KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD`) ist NICHT identisch mit den Realm-Usern — er funktioniert nur unter `https://<VM-IP>/admin`, nicht im Frontend.

## Stoppen, Neustarten, Zurücksetzen

### Sauber stoppen (Daten bleiben)

```bash
make prod-down
```

Container weg, Volumes (DBs, Keycloak-Daten, RabbitMQ) bleiben. Beim nächsten `make prod-up` startet alles im Zustand vor dem Stopp.

### Nur pausieren (schnellster Re-Start)

```bash
make prod-stop     # stoppt, Container bleiben
make prod-up       # läuft wieder
```

### Einzelnen Dienst neu starten

In Prod gibt es keine pro-Dienst-Aliasse wie in Dev — der Dienst wird per `SVC=` mitgegeben:

```bash
make prod-restart SVC=backend
make prod-restart SVC=frontend
make prod-restart SVC=worker
```

### Images neu ziehen (nach GHCR-Release)

```bash
make prod-pull
```

Zieht alle `:latest`-Images neu und rekreiert die Container, deren Image sich geändert hat. In Dev gibt es kein Pendant, weil dort lokal gebaut wird.

### Logs verfolgen

In Prod ebenfalls per `SVC=…`:

```bash
make prod-logs                  # alle
make prod-logs SVC=backend      # nur Backend
make prod-logs SVC=worker       # nur Worker
make prod-logs SVC=keycloak     # nur Keycloak
make prod-logs SVC=nginx        # nur nginx (TLS-Terminator)
```

### Komplett zurücksetzen (alle Daten weg)

```bash
make prod-reset
```

Stoppt den Stack und löscht alle Volumes — irreversibel. Anders als `make seed-reset` in Dev wird **nicht** automatisch neu gemigriert und geseedet; danach von Schritt 4 an wieder durchlaufen (`prod-up` → `prod-migrate` → `prod-seed`). Den Wert für `KEYCLOAK_CLIENT_SECRET` muss man dabei erneut über die Admin-UI regenerieren (Schritt 6), weil der Realm aus dem Export wieder mit dem maskierten Platzhalter importiert wird.
