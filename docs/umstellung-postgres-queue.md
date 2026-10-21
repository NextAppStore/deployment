# Umstellung auf die Postgres-Queue

Einmalige Anleitung für Staging und Prod: von RabbitMQ + Redis + Celery + `postgres-tfstate` auf Postgres als einzige Infrastruktur von Backend und Worker. Konzept: `other/Konzept Backend & Worker vereinfachen.md`.

Bei dieser Größe ist kein Parallelbetrieb nötig: Die alte Queue läuft leer, dann wird umgeschaltet. Rechne mit etwa 15 Minuten, in denen keine Deployments gestartet werden.

## Was sich ändert

| Vorher | Nachher |
|---|---|
| `rabbitmq`, `redis`, `postgres-tfstate` | entfallen, nur noch `postgres` |
| Backend schickt Tasks per Celery | Task-Zeile mit verschlüsseltem Payload, Commit = Übergabe |
| Worker liest RabbitMQ, schreibt Redis | Worker liest/schreibt `tasks`/`task_events` als Rolle `appstore_worker` |
| OpenTofu-State in `postgres-tfstate` + Kopie in `tasks.tf_state` | nur in `terraform_states` (verschlüsselt), über `/internal/tfstate` |
| `RABBITMQ_*`, `TFSTATE_DB_*`, `LTI_NONCE_REDIS_URL` in `.env` | entfallen; neu: `WORKER_DB_PASSWORD` |

## 1. Vorbereiten

1. In `.env` auf der VM `WORKER_DB_PASSWORD=<openssl rand -base64 24>` ergänzen. Die alten `TFSTATE_DB_*`-Werte **noch nicht löschen**, sie werden in Schritt 4 gebraucht.
2. Backups ziehen:
   ```bash
   docker exec postgres-prod pg_dumpall -U "$DB_USER" > backup-app-$(date +%F).sql
   docker exec postgres-tfstate-prod pg_dumpall -U "$TFSTATE_DB_USER" > backup-tfstate-$(date +%F).sql
   ```

## 2. Alte Queue leerlaufen lassen

Keine neuen Aktionen mehr starten (Kurs vorab informieren), dann warten, bis nichts mehr läuft:

```bash
docker exec postgres-prod psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT type, status, count(*) FROM tasks WHERE status IN ('PENDING','RUNNING') GROUP BY 1,2;"
```

Erst bei leerem Ergebnis weitermachen. Tasks, die doch noch offen sind, setzt die Migration auf FAILED mit dem Hinweis „Abgebrochen bei der Umstellung auf die Postgres-Queue“. Danach entscheidet ein Mensch in der UI, ob neu gestartet oder abgebaut wird.

## 3. Neue Version ausrollen

```bash
make prod-up          # bzw. Staging: Ansible-Playbook
```

**Ohne** `--remove-orphans`: Die alten Container `rabbitmq-prod`, `redis-prod` und `postgres-tfstate-prod` laufen als Waisen weiter, `postgres-tfstate-prod` wird in Schritt 4 noch gebraucht.

```bash
make prod-migrate     # alembic upgrade head + Passwort der Worker-Rolle
```

Bis `prod-migrate` durch ist, meldet der Worker im Log, dass er sich nicht verbinden kann. Er versucht es weiter und verbindet sich danach von selbst.

Das Staging-Playbook führt Migration und Rollen-Passwort automatisch aus. Nur Schritt 4 ist dort von Hand nötig.

## 4. Terraform-State übernehmen

Die Migration hat jeden Deployment-State schon aus dem letzten `tasks.tf_state`-Snapshot übernommen. Kanonisch ist aber der State in `postgres-tfstate`. Der folgende Schritt überschreibt die Snapshots damit. Das Backend erreicht den alten Container über das `worker-network`:

```bash
make prod-import-tfstate TFSTATE_DATABASE_URL=postgresql://$TFSTATE_DB_USER:$TFSTATE_DB_PASSWORD@postgres-tfstate:5432/$TFSTATE_DB_NAME
```

Vorher einmal mit `--dry-run` prüfen:

```bash
docker exec -e TFSTATE_DATABASE_URL=... backend-prod python scripts/import_tfstate.py --dry-run
```

## 5. Prüfen

```bash
make prod-logs SVC=worker      # "listening on task_queued with 4 slots"
docker exec postgres-prod psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT count(*) FROM terraform_states;"
```

Dann in der UI ein bestehendes Deployment pausieren und fortsetzen. Pause liest den State über `/internal/tfstate` und prüft damit den ganzen Weg: Queue, Live-Stream, State-Backend und Finalizer.

## 6. Aufräumen

```bash
docker compose -f docker-compose.prod.yml up -d --remove-orphans
```

Danach `RABBITMQ_*` und `TFSTATE_DB_*` aus `.env` und aus dem `STAGING_ENV_FILE`-Secret entfernen. Die Volumes `postgres_tfstate_prod_data`, `rabbitmq_prod_data` und `redis_prod_data` erst nach ein paar Wochen ohne Probleme löschen (`docker volume rm …`), sie sind das Rückfallnetz.

## Zurück

1. Alte Images und alte Compose-Datei ausrollen.
2. `docker exec backend-prod python -m alembic downgrade 4ce9d3e29956`. Die Spalten `celeryTaskId`/`tf_state` kommen zurück, aber **leer**. Die States liegen unverändert in `postgres-tfstate`, solange dessen Volume noch existiert.
3. Tasks, die nach der Umstellung gelaufen sind, haben ihren State nur in `terraform_states`. Vor dem Downgrade für diese Deployments `tofu state pull` gegen `/internal/tfstate` ausführen und in das alte `pg`-Backend schreiben, oder sie vorher abbauen.
