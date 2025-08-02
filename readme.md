# Immich Backup – PostgreSQL und Mediendateien automatisiert in die Cloud sichern

## ℹ️ Szenario

Die hier beschriebene Lösung folgt der immich Dokumentation zur Datensicherung: <https://immich.app/docs/administration/backup-and-restore/>  

Das immich System wird auf einem headless Linux Server (Ubuntu 24.04.2 LTS) mit Docker betrieben. Datenbank und `UPLOAD_LOCATION` sind als bind mounts in das System eingebunden.

### Voraussetzungen zur eigenen Nutzung  

**Nicht Bestandteil** der hier beschriebenen Sicherungsstrategie sind:

- Die Installation und das Setup von immich mit Docker Compose. Eine Anleitung dazu befindet sich z.B. hier: [immich Docker Compose](https://immich.app/docs/install/docker-compose/)
- Die Installation von `rclone` auf dem System.  
  (**Hinweis**: `rclone` nicht per `apt` installieren, besser die aktuelle Version direkt von der [rclone Webseite]([https://rclone.org/install/) verwenden.)  

**Vorraussetzungen** an das System für das Setup:  

- Eine **immich** Installation mit Docker Compose (s.o.)
- Ein Linux Host mit adäquater Internetverbindung.  
  (**Achtung:** Die hier verwendeten Bandbreiten-Parameter `--transfers=16 --checkers=16 --tpslimit=10` beziehen sich auf einen verfügbaren Upload von 300 Mbit/s und sollten entsprechend angepasst werden)
- Eine vorhanden `rclone` Installation (hier verwendet: v1.70.3)
- Ein **Remote Storage Provider** mit WebDAV Unterstützung (hier verwendet: kdrive)

## 📌 Ziel

Dieses Backup-System sichert täglich:

- Die **PostgreSQL-Datenbank** von Immich (`pg_dumpall`)
- Die **Mediendateien** aus dem lokalen Verzeichnis `/home/<user>/docker/immich/library`
- In ein **Cloud-Ziel** via `rclone` (z. B. krDrive mit WebDAV)
- Automatisch per `systemd`-Timer
- Mit Archivierung geänderter/gelöschter Dateien
- Mit Logdatei unter `/var/log/immich-backup.log`
- Mit automatischer Löschung alter Datenbankdumps

> 🔐 Die Daten werden im Cloud-Ziel **nicht verschlüsselt** gespeichert.

---

## 🗂️ Cloud-Zielstruktur

```text
<rclone-remote>:<remote-path>/
├── media/                              # Aktueller Stand aller Mediendateien
├── archive/
│   └── YYYY-MM-DD/
│       └── media/                      # Geänderte oder gelöschte Dateien
└── daily/
    └── YYYY-MM-DD/
        └── db/
            └── dump.YYYY-MM-DD.sql.gz
````

---

## ⚙️ Bash-Skript: `/usr/local/bin/backup-immich.sh`

### ❗ Voraussetzung

```bash
chmod +x /usr/local/bin/backup-immich.sh
```

### ✅ Inhalt

```bash
#!/bin/bash
set -euo pipefail

# === Konfiguration ===
DATE=$(date +%F)
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$BASE_DIR/backup"
DB_DIR="$BACKUP_DIR/db"
SRC_MEDIA="/home/<user>/docker/immich/library"
TARGET_MEDIA="<rclone-remote>:<remote-path>/media"
ARCHIVE_MEDIA="<rclone-remote>:<remote-path>/archive/$DATE/media"
DB_REMOTE="<rclone-remote>:<remote-path>/daily/$DATE/db"
LOGFILE="/var/log/immich-backup.log"
RETENTION_DAYS=14
RCLONE_CONF="/root/.config/rclone/rclone.conf"

# === Vorbereitungen ===
mkdir -p "$DB_DIR"
echo "[$DATE] Starte Immich-Backup" | tee -a "$LOGFILE"

# === 1. PostgreSQL-Dump ===
DB_DUMP="$DB_DIR/dump.$DATE.sql.gz"
echo "[$DATE] Erstelle PostgreSQL-Dump..." | tee -a "$LOGFILE"

if docker exec immich_postgres pg_isready -U postgres >/dev/null 2>&1; then
  docker exec -t immich_postgres \
    pg_dumpall --clean --if-exists --username=postgres \
    | gzip > "$DB_DUMP"
  echo "[$DATE] PostgreSQL-Dump erfolgreich: $DB_DUMP" | tee -a "$LOGFILE"
else
  echo "[$DATE] FEHLER: PostgreSQL ist nicht erreichbar!" | tee -a "$LOGFILE"
  exit 1
fi

# === 2. Upload PostgreSQL-Dump ===
echo "[$DATE] Lade Datenbankdump in die Cloud..." | tee -a "$LOGFILE"
rclone copy "$DB_DIR/" "$DB_REMOTE" \
  --config="$RCLONE_CONF" \
  --transfers=4 --checkers=4 \
  --log-level INFO --log-file="$LOGFILE"

# === 3. Sync Mediendateien ===
echo "[$DATE] Synchronisiere Mediendateien nach $TARGET_MEDIA ..." | tee -a "$LOGFILE"
rclone sync "$SRC_MEDIA" "$TARGET_MEDIA" \
  --backup-dir="$ARCHIVE_MEDIA" \
  --suffix=".$DATE" \
  --config="$RCLONE_CONF" \
  --transfers=16 --checkers=16 --tpslimit=10 \
  --log-level INFO --log-file="$LOGFILE"

# === 4. Lokale DB-Dumps bereinigen ===
echo "[$DATE] Entferne lokale Dumps älter als $RETENTION_DAYS Tage..." | tee -a "$LOGFILE"
find "$DB_DIR" -type f -name "*.sql.gz" -mtime +$RETENTION_DAYS -print -delete >> "$LOGFILE"

# === Abschluss ===
echo "[$DATE] Backup abgeschlossen." | tee -a "$LOGFILE"
exit 0
```

---

## 📄 Logdatei

* **Pfad:** `/var/log/immich-backup.log`
* **Inhalte:**

  * Zeitstempel und Fortschritt jedes Sicherungslaufs
  * Fehlerdiagnose (z. B. bei nicht erreichbarem Docker-Container)
  * Ausgabe von `rclone` (inkl. Dateinamen und Übertragungsstatus)

> Die Logdatei wird **fortlaufend** beschrieben. Eine Rotation kann über `logrotate` eingerichtet werden.

---

## ⏱️ Automatisierung via systemd

### `/etc/systemd/system/immich-cloud-backup.service`

```ini
[Unit]
Description=Immich Cloud Backup to krDrive

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-immich.sh
```

### `/etc/systemd/system/immich-cloud-backup.timer`

```ini
[Unit]
Description=Tägliches Immich Cloud Backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

---

## 🚀 Einrichtung & Nutzung

```bash
# systemd neu laden
sudo systemctl daemon-reexec

# Timer aktivieren
sudo systemctl enable --now immich-cloud-backup.timer

# Manuelles Backup starten
sudo systemctl start immich-cloud-backup.service

# Nächste Ausführung anzeigen
systemctl list-timers --all | grep immich

# Log anzeigen
tail -n 100 /var/log/immich-backup.log

# Status anzeigen
systemctl status immich-cloud-backup.service
```

---

## 🧼 Pflege und Wartung

* Lokale Dumps werden automatisch nach `RETENTION_DAYS` gelöscht.
* Geänderte/gelöschte Mediendateien werden archiviert nach Datum.
* Die Logdatei `/var/log/immich-backup.log` sollte regelmäßig über `logrotate` begrenzt werden, z. B.:

### Beispiel `/etc/logrotate.d/immich-backup`

```conf
/var/log/immich-backup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root adm
}
```

Aktivieren mit:

```bash
sudo logrotate --force /etc/logrotate.d/immich-backup
```