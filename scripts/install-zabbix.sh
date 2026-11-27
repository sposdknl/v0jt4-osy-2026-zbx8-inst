#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "CHYBA: radek ${LINENO}: ${BASH_COMMAND}" >&2' ERR

export DEBIAN_FRONTEND=noninteractive

DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASS="${ZBX_DB_PASSWORD:-}"
ADMIN_PASS="${ZBX_ADMIN_PASSWORD:-}"
ZBX_SERVER_NAME="${ZBX_SERVER_NAME:-Zabbix 8.0 LTS}"
ZBX_TIMEZONE="${ZBX_TIMEZONE:-Europe/Prague}"
RELEASE_URL="https://repo.zabbix.com/zabbix/8.0/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian13_all.deb"

APT_OPTS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log()  { echo "==> $*"; }
fail() { echo "CHYBA: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "skript musi bezet jako root"

if [[ -z "$DB_PASS" && -f /etc/zabbix/zabbix_server.conf ]]; then
  DB_PASS="$(sed -n 's/^DBPassword=//p' /etc/zabbix/zabbix_server.conf | head -n1)"
fi
[[ -n "$DB_PASS" ]] || fail "chybi ZBX_DB_PASSWORD (nastav ji v PowerShellu pred vagrant up)"
[[ "$DB_PASS" =~ ^[A-Za-z0-9]+$ ]] || fail "heslo k DB smi obsahovat jen pismena a cislice"

set_conf() {
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  elif grep -qE "^#[[:space:]]*${key}=" "$file"; then
    sed -i "0,/^#[[:space:]]*${key}=.*/s||${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

log "Aktualizace apt a zakladni balicky"
apt-get update -qq
apt-get install "${APT_OPTS[@]}" wget ca-certificates curl jq >/dev/null

if ! dpkg -s zabbix-release >/dev/null 2>&1; then
  log "Pridavam repozitar Zabbix 8.0 pro Debian 13"
  tmp="$(mktemp --suffix=.deb)"
  wget -q -O "$tmp" "$RELEASE_URL"
  dpkg -i "$tmp"
  rm -f "$tmp"
fi
apt-get update -qq

log "Instaluji MariaDB, Zabbix server, frontend, Apache a Agent 2"
apt-get install "${APT_OPTS[@]}" \
  mariadb-server apache2-utils \
  zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
  zabbix-sql-scripts zabbix-agent2 >/dev/null

systemctl enable --now mariadb

log "Vytvarim databazi a uzivatele"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

has_schema="$(mariadb -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='dbversion';")"
if [[ "$has_schema" -eq 0 ]]; then
  SQL_GZ=""
  for p in /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
           /usr/share/zabbix-sql-scripts/mysql/server.sql.gz; do
    [[ -f "$p" ]] && SQL_GZ="$p" && break
  done
  [[ -n "$SQL_GZ" ]] || fail "nenalezen server.sql.gz"

  log "Importuji schema ze ${SQL_GZ}"
  mariadb -e "SET GLOBAL log_bin_trust_function_creators = 1;"
  if ! zcat "$SQL_GZ" | mariadb --default-character-set=utf8mb4 "$DB_NAME"; then
    mariadb -e "SET GLOBAL log_bin_trust_function_creators = 0;" || true
    fail "import schematu selhal"
  fi
  mariadb -e "SET GLOBAL log_bin_trust_function_creators = 0;"

  [[ -n "$ADMIN_PASS" ]] || fail "chybi ZBX_ADMIN_PASSWORD (nastav ji v PowerShellu pred vagrant up)"
  log "Nastavuji heslo uzivatele Admin"
  ADMIN_HASH="$(htpasswd -bnBC 10 "" "$ADMIN_PASS" | tr -d ':\n')"
  mariadb "$DB_NAME" <<SQL
UPDATE users SET passwd='${ADMIN_HASH}' WHERE username='Admin';
SQL
else
  log "Schema uz existuje, import preskocen"
fi

log "Konfiguruji Zabbix server"
CONF=/etc/zabbix/zabbix_server.conf
set_conf DBName     "$DB_NAME" "$CONF"
set_conf DBUser     "$DB_USER" "$CONF"
set_conf DBPassword "$DB_PASS" "$CONF"
chown root:zabbix "$CONF"
chmod 640 "$CONF"

log "Konfiguruji Zabbix Agent 2"
ACONF=/etc/zabbix/zabbix_agent2.conf
set_conf Server       "127.0.0.1"     "$ACONF"
set_conf ServerActive "127.0.0.1"     "$ACONF"
set_conf Hostname     "Zabbix server" "$ACONF"

log "Generuji /etc/zabbix/web/zabbix.conf.php"
install -d -m 755 /etc/zabbix/web
cat > /etc/zabbix/web/zabbix.conf.php <<PHP
<?php
\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '${DB_NAME}';
\$DB['USER']     = '${DB_USER}';
\$DB['PASSWORD'] = '${DB_PASS}';

\$DB['SCHEMA'] = '';

\$DB['ENCRYPTION']    = false;
\$DB['KEY_FILE']      = '';
\$DB['CERT_FILE']     = '';
\$DB['CA_FILE']       = '';
\$DB['VERIFY_HOST']   = false;
\$DB['CIPHER_LIST']   = '';

\$DB['VAULT']            = '';
\$DB['VAULT_URL']        = '';
\$DB['VAULT_DB_PATH']    = '';
\$DB['VAULT_TOKEN']      = '';
\$DB['VAULT_CERT_FILE']  = '';
\$DB['VAULT_KEY_FILE']   = '';
\$DB['VAULT_PREFIX']     = '';

\$DB['DOUBLE_IEEE754'] = true;

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '${ZBX_SERVER_NAME}';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHP
chown root:www-data /etc/zabbix/web/zabbix.conf.php
chmod 640 /etc/zabbix/web/zabbix.conf.php

log "Konfiguruji Apache"
for f in /etc/zabbix/apache.conf /etc/apache2/conf-enabled/zabbix.conf; do
  [[ -f "$f" ]] && sed -i "s|^[[:space:]]*#[[:space:]]*php_value date.timezone .*|        php_value date.timezone ${ZBX_TIMEZONE}|" "$f" || true
done

cat > /etc/apache2/conf-available/zabbix-redirect.conf <<'APACHE'
RedirectMatch ^/$ /zabbix/
APACHE
a2enconf zabbix-redirect >/dev/null

log "Spoustim a povoluji sluzby"
systemctl enable mariadb zabbix-server zabbix-agent2 apache2 >/dev/null 2>&1
systemctl restart mariadb zabbix-server zabbix-agent2 apache2

log "Overuji beh sluzeb"
sleep 5
for s in mariadb zabbix-server zabbix-agent2 apache2; do
  systemctl is-active --quiet "$s" || { systemctl status "$s" --no-pager || true; fail "sluzba $s nebezi"; }
  printf '   %-15s %s\n' "$s" "$(systemctl is-active "$s")"
done

ok=0
for i in {1..15}; do
  if curl -fsS -o /dev/null http://127.0.0.1/zabbix/; then ok=1; break; fi
  sleep 2
done
[[ "$ok" -eq 1 ]] || fail "web neodpovida na http://127.0.0.1/zabbix/"

log "HOTOVO: http://127.0.0.1:8080/zabbix  (uzivatel Admin)"
