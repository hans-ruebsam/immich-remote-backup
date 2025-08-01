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
