#!/usr/bin/env bash
#
# Mail server (Maddy) with individual mailboxes + optional SnappyMail webmail.
#
#   cp setup.conf.example setup.conf && nano setup.conf && ./setup.sh
#   or just ./setup.sh and answer the questions
#
# Mailboxes are created afterwards with ./create-mailboxes.sh.
#
# Needs Ubuntu 22.04/24.04 or Debian 12, root, an A record pointing here and
# port 25 open at the provider. Safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MADDY_VERSION="0.8.0"
MADDY_REPO="foxcpp/maddy"
CONF="/etc/maddy/maddy.conf"
MAILBOX_DIR="$SCRIPT_DIR/mailboxes"
LEGACY_MAILBOX_FILE="$SCRIPT_DIR/mailboxes.txt"   # older versions used one file
WEBROOT="/var/www/snappymail"
SM_FALLBACK_URL="https://snappymail.eu/repository/latest.tar.gz"
CONFIG_FILE="setup.conf"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

die() { echo "Error: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

# ask VAR "question" [default] - skipped if VAR already has a value
ask() {
  local __var="$1" __q="$2" __def="${3:-}" __ans
  [[ -n "${!__var:-}" ]] && return 0
  [[ -t 0 ]] || die "$__var is not set and there is no terminal to ask. Set it in $CONFIG_FILE."
  if [[ -n "$__def" ]]; then
    read -rp "$__q [$__def]: " __ans; __ans="${__ans:-$__def}"
  else
    read -rp "$__q: " __ans
  fi
  printf -v "$__var" '%s' "$__ans"
}

yesno() {
  case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
    y|yes|true|1) return 0 ;; *) return 1 ;;
  esac
}

# put the Let's Encrypt cert on the mail ports and keep it there after renewals
install_mail_cert() {
  local le="/etc/letsencrypt/live/${MAIL_HOSTNAME}"
  [[ -f "$le/fullchain.pem" ]] || return 1
  install -m 0644 -o maddy -g maddy "$le/fullchain.pem" "$CERT_DIR/fullchain.pem"
  install -m 0640 -o maddy -g maddy "$le/privkey.pem"   "$CERT_DIR/privkey.pem"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/maddy-cert.sh <<HOOK
#!/bin/sh
set -e
LE="/etc/letsencrypt/live/${MAIL_HOSTNAME}"
DST="${CERT_DIR}"
[ -f "\$LE/fullchain.pem" ] || exit 0
install -m 0644 -o maddy -g maddy "\$LE/fullchain.pem" "\$DST/fullchain.pem"
install -m 0640 -o maddy -g maddy "\$LE/privkey.pem"   "\$DST/privkey.pem"
systemctl restart maddy || true
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/maddy-cert.sh
  systemctl restart maddy || true
  MAIL_CERT="trusted (Let's Encrypt)"
}

# set one key inside one ini section, without ever duplicating either
ini_set() {
  local f="$1" sect="$2" key="$3" val="$4" tmp
  if [[ ! -f "$f" ]]; then
    printf '[%s]\n%s = %s\n' "$sect" "$key" "$val" > "$f"
    return
  fi
  tmp="$(mktemp)"
  awk -v sect="[$sect]" -v key="$key" -v val="$val" '
    { lines[NR]=$0 }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { hit=1 }
    index($0, sect) == 1 { sec=NR }
    END {
      for (i=1;i<=NR;i++) {
        l=lines[i]
        if (l ~ "^[[:space:]]*" key "[[:space:]]*=") {
          if (!p) { print key " = " val; p=1 }
          continue
        }
        print l
        if (i==sec && !hit) { print key " = " val; p=1 }
      }
      if (!p) { print ""; print sect; print key " = " val }
    }' "$f" > "$tmp"
  mv "$tmp" "$f"
}

# read the real SSH port so enabling the firewall can't lock anyone out
detect_ssh_port() {
  local p
  p="$(grep -shiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
        /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
      | awk '{print $2}' | head -1 || true)"
  [[ "$p" =~ ^[0-9]+$ ]] && printf '%s' "$p" || printf '22'
}

# --- config ----------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Please run as root (sudo ./setup.sh)."

[[ -f "$CONFIG_FILE" ]] && { set -a; source "$CONFIG_FILE"; set +a; }

MAIL_HOSTNAME="${MAIL_HOSTNAME:-}"
DOMAINS="${DOMAINS:-}"
INSTALL_WEBMAIL="${INSTALL_WEBMAIL:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
INITIAL_MAILBOXES="${INITIAL_MAILBOXES:-}"
RETENTION_DAYS="${RETENTION_DAYS:-}"
BACKUP_DAYS="${BACKUP_DAYS:-}"
AUTO_UPDATES="${AUTO_UPDATES:-}"
ENABLE_FIREWALL="${ENABLE_FIREWALL:-}"
SSH_PORT="${SSH_PORT:-}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-}"
MAX_MESSAGE_SIZE="${MAX_MESSAGE_SIZE:-5M}"
JOURNAL_MAX_SIZE="${JOURNAL_MAX_SIZE:-500M}"
WEBMAIL_TITLE="${WEBMAIL_TITLE:-}"
# the theme draws its accent line above this text, so it needs to be there;
# "Sign in" is what the design uses
WEBMAIL_LOGIN_TEXT="${WEBMAIL_LOGIN_TEXT:-Sign in}"
WEBMAIL_THEME="${WEBMAIL_THEME:-}"
WEBMAIL_FAVICON="${WEBMAIL_FAVICON:-}"
THEME_SRC="$SCRIPT_DIR/webmail-theme"
THEME_NAME="Nocturne"

if [[ -z "$DOMAINS" && -f domains.txt ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(printf '%s' "$line" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    [[ -z "$line" || "$line" == \#* ]] && continue
    DOMAINS="${DOMAINS} ${line}"
  done < domains.txt
fi

echo "=== Mail server setup (individual mailboxes) ==="
[[ "$MAIL_HOSTNAME" == "mail.yourserver.tld" ]] && MAIL_HOSTNAME=""
ask MAIL_HOSTNAME "Mail server hostname (FQDN, e.g. mail.example.tld)"
ask DOMAINS       "Domains to receive mail for (space-separated)"
ask INSTALL_WEBMAIL "Install browser webmail (SnappyMail + HTTPS)? yes/no" "yes"
ask INITIAL_MAILBOXES "How many mailboxes to create right away? (0 = none)" "0"
ask RETENTION_DAYS  "Delete mail older than how many days? (0 = never)" "30"
ask BACKUP_DAYS     "Keep how many days of database backups? (0 = none)" "7"
ask AUTO_UPDATES    "Install automatic security updates? yes/no" "yes"
ask ENABLE_FIREWALL "Turn on the ufw firewall (only the needed ports stay open)? yes/no" "yes"
if yesno "$ENABLE_FIREWALL"; then
  ask SSH_PORT      "SSH port to keep open (a wrong value locks you out)" "$(detect_ssh_port)"
fi
ask INSTALL_FAIL2BAN "Install fail2ban (bans brute-force on SSH and IMAP)? yes/no" "yes"
if yesno "$INSTALL_WEBMAIL" && [[ -z "$LETSENCRYPT_EMAIL" ]] && [[ -t 0 ]]; then
  read -rp "Email for Let's Encrypt notices (optional, Enter to skip): " LETSENCRYPT_EMAIL || true
fi

# still needed for the fail2ban jail even when the firewall stays off
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT="$(detect_ssh_port)"

DOMAIN_LIST=()
for d in ${DOMAINS//,/ }; do
  d="$(printf '%s' "$d" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  [[ -z "$d" ]] && continue
  DOMAIN_LIST+=("$d")
done
[[ ${#DOMAIN_LIST[@]} -gt 0 ]] || die "No domains given."
[[ -n "$MAIL_HOSTNAME" ]] || die "No hostname given."
LOCAL_DOMAINS="${DOMAIN_LIST[*]}"
CERT_DIR="/etc/maddy/certs/${MAIL_HOSTNAME}"

{
  echo "# One domain per line. Managed by setup.sh and manage-domains.sh."
  printf '%s\n' "${DOMAIN_LIST[@]}"
} > domains.txt

# don't overwrite a config the user edited by hand
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" <<CONF
# Written by setup.sh. Edit a value and re-run ./setup.sh to apply it.

MAIL_HOSTNAME=${MAIL_HOSTNAME}
DOMAINS="${DOMAIN_LIST[*]}"
INSTALL_WEBMAIL=${INSTALL_WEBMAIL}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
INITIAL_MAILBOXES=${INITIAL_MAILBOXES}
RETENTION_DAYS=${RETENTION_DAYS}
BACKUP_DAYS=${BACKUP_DAYS}
AUTO_UPDATES=${AUTO_UPDATES}
ENABLE_FIREWALL=${ENABLE_FIREWALL}
SSH_PORT=${SSH_PORT}
INSTALL_FAIL2BAN=${INSTALL_FAIL2BAN}
MAX_MESSAGE_SIZE=${MAX_MESSAGE_SIZE}
JOURNAL_MAX_SIZE=${JOURNAL_MAX_SIZE}
WEBMAIL_TITLE=${WEBMAIL_TITLE}
WEBMAIL_LOGIN_TEXT=${WEBMAIL_LOGIN_TEXT}
WEBMAIL_THEME=${WEBMAIL_THEME}
WEBMAIL_FAVICON=${WEBMAIL_FAVICON}
CONF
  chmod 600 "$CONFIG_FILE"
  echo "  (answers saved to ${CONFIG_FILE})"
fi

echo
echo "  Hostname  : $MAIL_HOSTNAME"
echo "  Domains   : ${DOMAIN_LIST[*]}"
echo "  Mailboxes : individual, created with ./create-mailboxes.sh"
if yesno "$INSTALL_WEBMAIL"; then
  echo "  Webmail   : yes -> https://${MAIL_HOSTNAME}/"
else
  echo "  Webmail   : no (IMAP only)"
fi
echo
if [[ -t 0 ]]; then
  read -rp "Start the installation? [Y/n]: " _go
  case "$(printf '%s' "${_go:-y}" | tr 'A-Z' 'a-z')" in n|no) die "Aborted." ;; esac
fi

# --- install ---------------------------------------------------------------

step "[1/11] Network preference"
# lots of VPS have broken IPv6 out; without this, downloads and certbot hang
if ! grep -qs '^precedence ::ffff:0:0/96  100' /etc/gai.conf; then
  echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
  echo "    Preferring IPv4 (IPv6 stays available)."
else
  echo "    IPv4 preference already set."
fi

step "[2/11] Installing base packages"
apt-get update -y
apt-get install -y curl ca-certificates openssl zstd tar

step "[3/11] Installing Maddy ${MADDY_VERSION}"
if command -v maddy >/dev/null 2>&1 && maddy version 2>/dev/null | grep -q "$MADDY_VERSION"; then
  echo "    Already installed - skipping download."
else
  TMP="$(mktemp -d)"
  API_JSON="$(curl -4 -fsSL --connect-timeout 30 \
    "https://api.github.com/repos/${MADDY_REPO}/releases/tags/v${MADDY_VERSION}" || true)"
  [[ -n "$API_JSON" ]] || die "Could not reach the GitHub API (rate limit or network). Retry later."
  ASSET_URL="$(printf '%s\n' "$API_JSON" \
    | grep -oE '"browser_download_url"[^,]*' \
    | sed -E 's/.*"(https[^"]+)".*/\1/' \
    | grep -iE 'linux' | grep -iE 'x86_64|amd64' | head -1 || true)"
  [[ -n "$ASSET_URL" ]] || die "No linux x86_64 asset for Maddy v${MADDY_VERSION}."
  echo "    Downloading $ASSET_URL"
  curl -4 -fsSL --connect-timeout 30 "$ASSET_URL" -o "$TMP/maddy.tar"
  case "$ASSET_URL" in
    *.zst) tar --zstd -xf "$TMP/maddy.tar" -C "$TMP" ;;
    *.gz)  tar -xzf "$TMP/maddy.tar" -C "$TMP" ;;
    *)     tar -xf "$TMP/maddy.tar" -C "$TMP" ;;
  esac
  MADDY_BIN="$(find "$TMP" -type f -name maddy | head -1 || true)"
  [[ -n "$MADDY_BIN" ]] || die "Maddy binary not found in the archive."
  install -m 0755 "$MADDY_BIN" /usr/local/bin/maddy
  # pre-0.7 shipped a separate maddyctl
  MADDYCTL_BIN="$(find "$TMP" -type f -name maddyctl | head -1 || true)"
  if [[ -n "$MADDYCTL_BIN" ]]; then install -m 0755 "$MADDYCTL_BIN" /usr/local/bin/maddyctl; fi
  rm -rf "$TMP"
fi

# systemd creates /run/maddy via RuntimeDirectory=, but the CLI needs it too
id -u maddy >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin maddy
mkdir -p /etc/maddy "$CERT_DIR" /var/lib/maddy /run/maddy
chown -R maddy:maddy /var/lib/maddy /run/maddy

step "[4/11] Mail TLS certificate"
if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
    -days 3650 -subj "/CN=${MAIL_HOSTNAME}" \
    -addext "subjectAltName=DNS:${MAIL_HOSTNAME}" 2>/dev/null
  echo "    Self-signed certificate created."
else
  echo "    Certificate already present."
fi
chown -R maddy:maddy /etc/maddy/certs
chmod 640 "$CERT_DIR/privkey.pem"

step "[5/11] Writing ${CONF}"
cat > "$CONF" <<'MADDYCONF'
# Generated by setup.sh - one mailbox per address.

$(hostname) = __HOSTNAME__
$(local_domains) = __DOMAINS__

# $(hostname) above is just a macro; the endpoints need this directive too
hostname $(hostname)

tls file /etc/maddy/certs/$(hostname)/fullchain.pem /etc/maddy/certs/$(hostname)/privkey.pem

auth.pass_table local_authdb {
    table sql_table {
        driver sqlite3
        dsn /var/lib/maddy/credentials.db
        table_name passwords
    }
}

storage.imapsql local_mailboxes {
    driver sqlite3
    dsn /var/lib/maddy/imapsql.db
}

smtp tcp://0.0.0.0:25 {
    # anything bigger is rejected at SMTP time, so it never touches the disk
    max_message_size __MAXSIZE__
    limits {
        all rate 20 1s
        all concurrency 10
    }
    # delivered to the mailbox matching the recipient; unknown ones are rejected
    destination $(local_domains) {
        deliver_to &local_mailboxes
    }
    default_destination {
        reject 550 5.1.1 "User does not exist"
    }
}

imap tls://0.0.0.0:993 tcp://0.0.0.0:143 {
    auth &local_authdb
    storage &local_mailboxes
}
MADDYCONF
sed -i "s|__HOSTNAME__|${MAIL_HOSTNAME}|g; s|__DOMAINS__|${LOCAL_DOMAINS}|g; s|__MAXSIZE__|${MAX_MESSAGE_SIZE}|g" "$CONF"
chmod 644 "$CONF"
echo "    Message size limit: ${MAX_MESSAGE_SIZE}"

step "[6/11] systemd service"
cat > /etc/systemd/system/maddy.service <<'UNIT'
[Unit]
Description=maddy mail server
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=maddy
Group=maddy
ExecStart=/usr/local/bin/maddy run
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
StateDirectory=maddy
RuntimeDirectory=maddy
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

step "[7/11] Firewall + starting Maddy"
# 80 is needed either way - Let's Encrypt validates over it, also on renewal
FW_PORTS=("$SSH_PORT" 25 143 993 80)
yesno "$INSTALL_WEBMAIL" && FW_PORTS+=(443)
FIREWALL_STATE="off"
if yesno "$ENABLE_FIREWALL"; then
  apt-get install -y ufw >/dev/null
  # allow the ports first - enabling with SSH closed ends the session for good
  for p in "${FW_PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null; done
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  echo "    ufw is active, open: ${FW_PORTS[*]}"
  FIREWALL_STATE="active (${FW_PORTS[*]})"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  for p in "${FW_PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
  echo "    ufw was already on - opened ${FW_PORTS[*]}"
  FIREWALL_STATE="active (${FW_PORTS[*]})"
else
  echo "    Firewall off - your provider's firewall is the only filter."
fi
systemctl enable maddy >/dev/null 2>&1 || echo "WARNING: could not enable maddy for auto-start." >&2
systemctl reset-failed maddy 2>/dev/null || true
systemctl restart maddy || true   # don't abort here, the check below is more useful
sleep 3
if systemctl is-active --quiet maddy; then
  echo "    Maddy is running (auto-start on reboot: enabled)."
  MADDY_OK=yes
else
  echo "WARNING: Maddy did not start. Check: journalctl -u maddy -n 50 --no-pager" >&2
  MADDY_OK=no
fi

# --- brute-force protection ------------------------------------------------

step "[8/11] Brute-force protection"
FAIL2BAN_STATE="not installed"
SECURITY_SERVICES=""
if yesno "${INSTALL_FAIL2BAN:-no}"; then
  SECURITY_SERVICES="fail2ban"
  # python3-systemd is what lets the jails read the journal
  apt-get install -y fail2ban python3-systemd >/dev/null

  # maddy logs to the journal, not to a file, so the filter reads it from there
  cat > /etc/fail2ban/filter.d/maddy.conf <<'F2B'
[Definition]
failregex = auth(?:entication)?[ _-]?(?:failed|error).*"(?:src_ip|remote_ip|ip)"\s*:\s*"<HOST>"
            auth(?:entication)?[ _-]?(?:failed|error).*"(?:src|remote_addr)"\s*:\s*"<HOST>(?::\d+)?"
            (?:invalid credentials|authentication failed).*<HOST>
ignoreregex =

[Init]
journalmatch = _SYSTEMD_UNIT=maddy.service
F2B

  # with ufw on, let fail2ban write its bans through ufw instead of raw iptables
  F2B_BANACTION="iptables-multiport"
  [[ "$FIREWALL_STATE" != off ]] && F2B_BANACTION="ufw"

  cat > /etc/fail2ban/jail.d/mailserver.local <<JAIL
[DEFAULT]
banaction = ${F2B_BANACTION}
backend   = systemd
maxretry  = 5
findtime  = 10m
bantime   = 1h

# backend is repeated per jail on purpose - jail.conf sets its own for [sshd],
# and a section value beats anything in [DEFAULT]
[sshd]
enabled = true
port    = ${SSH_PORT}
backend = systemd

[maddy]
enabled = true
filter  = maddy
port    = 25,143,993
backend = systemd
JAIL

  systemctl enable fail2ban >/dev/null 2>&1 || true
  if systemctl restart fail2ban 2>/dev/null; then
    sleep 2
    JAILS="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p' || true)"
    if [[ -n "$JAILS" ]]; then
      echo "    fail2ban running - jails: ${JAILS}"
      echo "    5 failed logins in 10 min = 1 hour ban."
      FAIL2BAN_STATE="active (${JAILS})"
    else
      echo "WARNING: fail2ban started but has no active jail." >&2
      FAIL2BAN_STATE="started, no jails"
    fi
  else
    echo "WARNING: fail2ban did not start. Check: journalctl -u fail2ban -n 30" >&2
    FAIL2BAN_STATE="failed to start"
  fi
  # the SSH jail is a known quantity; maddy's log format is not guaranteed
  echo "    Check the IMAP jail once real traffic has hit it:"
  echo "      fail2ban-client status maddy"
else
  echo "    Skipped - nothing limits failed login attempts."
fi

# --- webmail ---------------------------------------------------------------

WEBMAIL_OK=skipped
CERT_SERVICES=""
if ! yesno "$INSTALL_WEBMAIL"; then
  step "[9/11] Mail certificate (Let's Encrypt)"
  # no nginx here, so certbot serves the challenge on port 80 itself
  apt-get install -y certbot >/dev/null
  CERTBOT_ARGS=(--register-unsafely-without-email)
  [[ -n "$LETSENCRYPT_EMAIL" ]] && CERTBOT_ARGS=(-m "$LETSENCRYPT_EMAIL")
  if certbot certonly --standalone -d "$MAIL_HOSTNAME" \
       --non-interactive --agree-tos "${CERTBOT_ARGS[@]}"; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 \
      || echo "WARNING: could not enable certbot.timer - renew manually." >&2
    CERT_SERVICES="certbot.timer"
    if install_mail_cert; then
      echo "    Mail ports now use a trusted certificate."
    else
      echo "WARNING: certificate issued but not found - keeping the self-signed one." >&2
    fi
  else
    echo "WARNING: Let's Encrypt failed - keeping the self-signed certificate." >&2
    echo "         Port 80 reachable? A record correct? Then re-run:" >&2
    echo "         certbot certonly --standalone -d ${MAIL_HOSTNAME}" >&2
  fi
else
  step "[9/11] Webmail (SnappyMail + nginx + Let's Encrypt)"
  apt-get install -y nginx certbot python3-certbot-nginx \
    php-fpm php-cli php-curl php-xml php-mbstring php-zip php-intl php-gd php-sqlite3

  PHP_FPM_SVC="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | head -1 || true)"
  [[ -n "$PHP_FPM_SVC" ]] && systemctl enable --now "$PHP_FPM_SVC" >/dev/null 2>&1 || true
  PHP_SOCK="$(ls /run/php/php*-fpm.sock 2>/dev/null | sort | tail -1 || true)"
  [[ -n "$PHP_SOCK" ]] || die "No PHP-FPM socket found under /run/php/."
  echo "    PHP-FPM socket: $PHP_SOCK"

  if [[ -f "$WEBROOT/index.php" ]]; then
    echo "    SnappyMail already present - skipping download."
  else
    rm -rf "$WEBROOT"; mkdir -p "$WEBROOT"
    TMP="$(mktemp -d)"
    # only the plain snappymail-<version>.tar.gz; the -cpanel/-nextcloud
    # builds have a different layout and no top-level index.php
    SM_DL="$(curl -4 -fsSL --connect-timeout 30 \
      https://api.github.com/repos/the-djmaze/snappymail/releases/latest 2>/dev/null \
      | grep -oE '"browser_download_url"[^,]*' \
      | sed -E 's/.*"(https[^"]+)".*/\1/' \
      | grep -E 'snappymail-[0-9.]+\.tar\.gz$' | head -1 || true)"
    [[ -z "$SM_DL" ]] && SM_DL="$SM_FALLBACK_URL"
    echo "    Downloading $SM_DL"
    curl -4 -fsSL --connect-timeout 30 "$SM_DL" -o "$TMP/snappymail.tar.gz" \
      || die "Could not download SnappyMail. Test: curl -4 -I https://github.com"
    tar -xzf "$TMP/snappymail.tar.gz" -C "$WEBROOT"
    rm -rf "$TMP"
  fi
  [[ -f "$WEBROOT/index.php" ]] || die "SnappyMail did not extract correctly."

  # fallback config for any domain -> everyone logs in to local maddy.
  # every section needs its own "type" or SnappyMail throws a null error.
  DOMAINS_DIR="$WEBROOT/data/_data_/_default_/domains"
  mkdir -p "$DOMAINS_DIR"
  cat > "$DOMAINS_DIR/default.json" <<'JSON'
{
    "IMAP": {
        "host": "127.0.0.1",
        "port": 993,
        "type": 1,
        "timeout": 300,
        "shortLogin": false,
        "lowerLogin": true,
        "sasl": ["SCRAM-SHA-256", "SCRAM-SHA-1", "PLAIN", "LOGIN"],
        "ssl": {
            "verify_peer": false,
            "verify_peer_name": false,
            "allow_self_signed": true,
            "SNI_enabled": true,
            "disable_compression": true,
            "security_level": 1
        },
        "disabled_capabilities": [],
        "use_expunge_all_on_delete": false,
        "fast_simple_search": true,
        "force_select": false,
        "message_all_headers": false,
        "message_list_limit": 10000,
        "search_filter": ""
    },
    "SMTP": {
        "host": "127.0.0.1",
        "port": 25,
        "type": 0,
        "timeout": 60,
        "shortLogin": false,
        "lowerLogin": true,
        "sasl": ["PLAIN", "LOGIN"],
        "ssl": {
            "verify_peer": false,
            "verify_peer_name": false,
            "allow_self_signed": true,
            "SNI_enabled": true,
            "disable_compression": true,
            "security_level": 1
        },
        "useAuth": false,
        "setSender": false,
        "usePhpMail": false
    },
    "Sieve": {
        "host": "127.0.0.1",
        "port": 4190,
        "type": 0,
        "timeout": 10,
        "shortLogin": false,
        "lowerLogin": true,
        "sasl": ["PLAIN", "LOGIN"],
        "ssl": {
            "verify_peer": false,
            "verify_peer_name": false,
            "allow_self_signed": true,
            "SNI_enabled": true,
            "disable_compression": true,
            "security_level": 1
        },
        "enabled": false
    },
    "whiteList": ""
}
JSON

  SM_INI="$WEBROOT/data/_data_/_default_/configs/application.ini"
  mkdir -p "$(dirname "$SM_INI")"

  # the setup writes the domain config itself, so nobody needs /?admin - and an
  # exposed admin panel can repoint IMAP or enable plugins
  ini_set "$SM_INI" security allow_admin_panel Off
  echo "    SnappyMail admin panel disabled."

  # themes live inside the versioned directory, so a SnappyMail update wipes
  # them - copying on every run is what makes the custom one survive
  if [[ -d "$THEME_SRC" ]]; then
    THEME_DST=""
    for d in "$WEBROOT"/snappymail/v/*/themes; do [[ -d "$d" ]] && THEME_DST="$d"; done
    if [[ -n "$THEME_DST" && -f "$THEME_SRC/styles.css" ]]; then
      rm -rf "${THEME_DST:?}/${THEME_NAME}"
      mkdir -p "${THEME_DST}/${THEME_NAME}"
      cp "$THEME_SRC/styles.css" "${THEME_DST}/${THEME_NAME}/"
      # assets referenced from styles.css - fonts are bundled so the login
      # page never calls out to a CDN
      for sub in images fonts; do
        [[ -d "$THEME_SRC/$sub" ]] && cp -r "$THEME_SRC/$sub" "${THEME_DST}/${THEME_NAME}/"
      done
      # the folder is only listed as a theme if styles.css is there
      echo "    Theme '${THEME_NAME}' installed from webmail-theme/."
      [[ -z "$WEBMAIL_THEME" ]] && WEBMAIL_THEME="$THEME_NAME"
    fi
  fi

  [[ -n "$WEBMAIL_THEME"      ]] && ini_set "$SM_INI" webmail theme "$WEBMAIL_THEME"
  [[ -n "$WEBMAIL_TITLE"      ]] && ini_set "$SM_INI" webmail title "$WEBMAIL_TITLE"
  [[ -n "$WEBMAIL_LOGIN_TEXT" ]] && ini_set "$SM_INI" webmail loading_description "$WEBMAIL_LOGIN_TEXT"
  [[ -n "$WEBMAIL_FAVICON"    ]] && ini_set "$SM_INI" webmail favicon_url "$WEBMAIL_FAVICON"

  chown -R www-data:www-data "$WEBROOT"

  # http only for now, certbot rewrites this to https below
  cat > /etc/nginx/sites-available/snappymail <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name __HOSTNAME__;
    root /var/www/snappymail;
    index index.php;

    client_max_body_size 50M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:__PHPSOCK__;
    }

    location ^~ /data {
        deny all;
        return 403;
    }
}
NGINX
  sed -i "s|__HOSTNAME__|${MAIL_HOSTNAME}|g; s|__PHPSOCK__|${PHP_SOCK}|g" \
    /etc/nginx/sites-available/snappymail
  ln -sf /etc/nginx/sites-available/snappymail /etc/nginx/sites-enabled/snappymail
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx >/dev/null 2>&1 || true
  systemctl reload nginx

  CERTBOT_ARGS=(--register-unsafely-without-email)
  [[ -n "$LETSENCRYPT_EMAIL" ]] && CERTBOT_ARGS=(-m "$LETSENCRYPT_EMAIL")
  if certbot --nginx -d "$MAIL_HOSTNAME" --non-interactive --agree-tos --redirect \
       "${CERTBOT_ARGS[@]}"; then
    WEBMAIL_OK="https"
    # certs last 90 days
    systemctl enable --now certbot.timer >/dev/null 2>&1 \
      || echo "WARNING: could not enable certbot.timer - renew manually." >&2

    # use the same cert for the mail ports so clients stop warning; the deploy
    # hook copies it again after each renewal
    if install_mail_cert; then
      echo "    Mail ports now use the Let's Encrypt certificate."
    fi
  else
    echo "WARNING: Let's Encrypt failed - webmail runs over http:// for now." >&2
    echo "         Ports 80/443 open? A record correct? Then re-run:" >&2
    echo "         certbot --nginx -d ${MAIL_HOSTNAME} --redirect" >&2
    WEBMAIL_OK="http"
  fi
  WEBMAIL_SERVICES="nginx ${PHP_FPM_SVC:-} certbot.timer"
fi

# --- housekeeping ----------------------------------------------------------

step "[10/11] Housekeeping"
HOUSEKEEPING_SERVICES=""

# maddy logs every rejected message; on a busy server an uncapped journal is a
# second way to fill the disk that mail retention doesn't cover
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-maddy.conf <<EOF
[Journal]
SystemMaxUse=${JOURNAL_MAX_SIZE}
EOF
systemctl restart systemd-journald 2>/dev/null || true
echo "    Journal capped at ${JOURNAL_MAX_SIZE}."

if [[ "${RETENTION_DAYS:-0}" =~ ^[0-9]+$ ]] && [[ "${RETENTION_DAYS:-0}" -gt 0 ]]; then
  # maddy's CLI only deletes by message number, so go through IMAP instead -
  # SEARCH BEFORE is standard and doesn't change between maddy releases
  cat > /usr/local/bin/maddy-cleanup <<'PYEOF'
#!/usr/bin/env python3
"""Delete mail older than RETENTION_DAYS from every mailbox login on disk."""
import glob, imaplib, os, re, ssl, sys
from datetime import datetime, timedelta

days = int(os.environ.get("RETENTION_DAYS", "0"))
mdir = os.environ.get("MAILBOX_DIR", "")
legacy = os.environ.get("LEGACY_MAILBOX_FILE", "")
host, port = "127.0.0.1", 993

if days <= 0:
    sys.exit(0)

# logins are split into one file per day, so read the whole directory
paths = []
if legacy and os.path.exists(legacy):
    paths.append(legacy)
if mdir and os.path.isdir(mdir):
    paths += sorted(glob.glob(os.path.join(mdir, "*.txt")))
if not paths:
    print("no mailbox files found in %s" % (mdir or "?"), file=sys.stderr)
    sys.exit(1)

accounts, seen = [], set()
for p in paths:
    with open(p, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            user, pw = line.split(":", 1)      # password may contain ':'
            user, pw = user.strip(), pw.strip()
            if user and pw and user not in seen:
                seen.add(user)
                accounts.append((user, pw))

cutoff = (datetime.now() - timedelta(days=days)).strftime("%d-%b-%Y")
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

LIST_RE = re.compile(r'\([^)]*\)\s+"[^"]*"\s+(?P<name>.+)$')
total = 0

for user, pw in accounts:
    try:
        M = imaplib.IMAP4_SSL(host, port, ssl_context=ctx)
        M.login(user, pw)
    except Exception as e:
        print("skip %s: %s" % (user, e), file=sys.stderr)
        continue
    try:
        typ, boxes = M.list()
        names = []
        for raw in boxes or []:
            text = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw)
            m = LIST_RE.search(text)
            if m:
                names.append(m.group("name").strip().strip('"'))
        for name in names or ["INBOX"]:
            try:
                typ, _ = M.select('"%s"' % name)
                if typ != "OK":
                    continue
                typ, data = M.search(None, "BEFORE", cutoff)
                if typ != "OK" or not data or not data[0]:
                    continue
                ids = data[0].split()
                M.store(b",".join(ids), "+FLAGS", "\\Deleted")
                M.expunge()
                total += len(ids)
                print("%s/%s: deleted %d" % (user, name, len(ids)))
            except Exception as e:
                print("%s/%s: %s" % (user, name, e), file=sys.stderr)
    finally:
        try:
            M.logout()
        except Exception:
            pass

print("done: %d message(s) older than %d day(s) deleted" % (total, days))
PYEOF
  chmod +x /usr/local/bin/maddy-cleanup

  apt-get install -y sqlite3 >/dev/null
  # deleting mail only frees pages inside the sqlite file - the file itself
  # keeps its size, so without this the space never returns to the filesystem
  cat > /usr/local/bin/maddy-vacuum <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MIN_PCT="${VACUUM_MIN_FREE_PCT:-20}"
stopped=no

finish() {
  if [ "$stopped" = yes ]; then
    chown -R maddy:maddy /var/lib/maddy 2>/dev/null || true
    systemctl start maddy 2>/dev/null || true
  fi
}
trap finish EXIT

for db in /var/lib/maddy/*.db; do
  [ -e "$db" ] || continue
  name="$(basename "$db")"
  pages="$(sqlite3 "$db" 'PRAGMA page_count;' 2>/dev/null || echo 0)"
  freed="$(sqlite3 "$db" 'PRAGMA freelist_count;' 2>/dev/null || echo 0)"
  [ "$pages" -gt 0 ] 2>/dev/null || continue

  pct=$(( freed * 100 / pages ))
  if [ "$pct" -lt "$MIN_PCT" ]; then
    echo "${name}: ${pct}% reclaimable, below ${MIN_PCT}% - skipped"
    continue
  fi

  # VACUUM builds a full copy before replacing the original
  size_kb="$(du -k "$db" | cut -f1)"
  avail_kb="$(df -Pk /var/lib/maddy | awk 'NR==2{print $4}')"
  if [ "$avail_kb" -lt $(( size_kb * 2 )) ]; then
    echo "${name}: not enough free disk to rebuild it - skipped" >&2
    continue
  fi

  # sqlite needs the file to itself for this
  if [ "$stopped" = no ]; then
    systemctl stop maddy 2>/dev/null || true
    stopped=yes
  fi

  before="$(du -h "$db" | cut -f1)"
  sqlite3 "$db" 'VACUUM;'
  echo "${name}: ${before} -> $(du -h "$db" | cut -f1) (${pct}% was reclaimable)"
done

[ "$stopped" = yes ] && echo "maddy was stopped briefly to rebuild the files." || true
EOF
  chmod +x /usr/local/bin/maddy-vacuum

  cat > /etc/systemd/system/maddy-cleanup.service <<UNIT
[Unit]
Description=Delete old mail from Maddy mailboxes and reclaim the space
After=maddy.service
Requires=maddy.service

[Service]
Type=oneshot
Environment=RETENTION_DAYS=${RETENTION_DAYS}
Environment=MAILBOX_DIR=${MAILBOX_DIR}
Environment=LEGACY_MAILBOX_FILE=${LEGACY_MAILBOX_FILE}
Environment=VACUUM_MIN_FREE_PCT=20
# first delete the old mail over IMAP, then shrink the files it freed up
ExecStart=/usr/local/bin/maddy-cleanup
ExecStart=/usr/local/bin/maddy-vacuum
UNIT

  cat > /etc/systemd/system/maddy-cleanup.timer <<'UNIT'
[Unit]
Description=Daily mail retention cleanup

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now maddy-cleanup.timer >/dev/null 2>&1 || true
  HOUSEKEEPING_SERVICES="$HOUSEKEEPING_SERVICES maddy-cleanup.timer"
  echo "    Mail older than ${RETENTION_DAYS} days is deleted daily,"
  echo "    then the database is shrunk so the disk space comes back."
else
  systemctl disable --now maddy-cleanup.timer >/dev/null 2>&1 || true
  echo "    Mail retention: disabled."
fi

if [[ "${BACKUP_DAYS:-0}" =~ ^[0-9]+$ ]] && [[ "${BACKUP_DAYS:-0}" -gt 0 ]]; then
  apt-get install -y sqlite3 >/dev/null
  cat > /usr/local/bin/maddy-backup <<'EOF'
#!/usr/bin/env bash
# sqlite .backup is safe while maddy is running, unlike copying the file
set -euo pipefail
DEST="/var/backups/maddy"
KEEP="${BACKUP_DAYS:-7}"
mkdir -p "$DEST"
stamp="$(date +%F)"
for db in /var/lib/maddy/*.db; do
  [ -e "$db" ] || continue
  name="$(basename "$db" .db)"
  sqlite3 "$db" ".backup '${DEST}/${name}-${stamp}.db'"
done
find "$DEST" -name '*.db' -mtime +"$KEEP" -delete
echo "backup written to $DEST (keeping ${KEEP} days)"
EOF
  chmod +x /usr/local/bin/maddy-backup

  cat > /etc/systemd/system/maddy-backup.service <<UNIT
[Unit]
Description=Backup Maddy databases

[Service]
Type=oneshot
Environment=BACKUP_DAYS=${BACKUP_DAYS}
ExecStart=/usr/local/bin/maddy-backup
UNIT

  cat > /etc/systemd/system/maddy-backup.timer <<'UNIT'
[Unit]
Description=Daily Maddy database backup

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now maddy-backup.timer >/dev/null 2>&1 || true
  HOUSEKEEPING_SERVICES="$HOUSEKEEPING_SERVICES maddy-backup.timer"
  echo "    Daily backups to /var/backups/maddy (keeping ${BACKUP_DAYS} days)."
else
  systemctl disable --now maddy-backup.timer >/dev/null 2>&1 || true
  echo "    Backups: disabled."
fi

if yesno "${AUTO_UPDATES:-no}"; then
  apt-get install -y unattended-upgrades >/dev/null
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  HOUSEKEEPING_SERVICES="$HOUSEKEEPING_SERVICES unattended-upgrades"
  echo "    Automatic security updates enabled."
else
  echo "    Automatic security updates: skipped."
fi

# --- initial mailboxes -----------------------------------------------------

step "[11/11] Mailboxes"
if [[ "${INITIAL_MAILBOXES:-0}" =~ ^[0-9]+$ ]] && [[ "${INITIAL_MAILBOXES:-0}" -gt 0 ]]; then
  chmod +x ./create-mailboxes.sh 2>/dev/null || true
  if [[ ${#DOMAIN_LIST[@]} -eq 1 ]]; then
    ./create-mailboxes.sh "$INITIAL_MAILBOXES" || echo "WARNING: mailbox creation failed." >&2
  else
    ./create-mailboxes.sh "$INITIAL_MAILBOXES" --all || echo "WARNING: mailbox creation failed." >&2
  fi
else
  echo "    None requested - create them with ./create-mailboxes.sh <count>"
fi

# --- summary ---------------------------------------------------------------

MAILBOX_COUNT=0
for f in "$LEGACY_MAILBOX_FILE" "$MAILBOX_DIR"/*.txt; do
  [[ -f "$f" ]] || continue
  MAILBOX_COUNT=$(( MAILBOX_COUNT + $(grep -c ':' "$f" || true) ))
done

echo
echo "============================================================"
echo " SETUP COMPLETE"
echo "------------------------------------------------------------"
echo " Mail server : ${MAIL_HOSTNAME}"
echo " Domains     : ${DOMAIN_LIST[*]}"
echo " Maddy       : $( [[ "$MADDY_OK" == yes ]] && echo "running" || echo "NOT running - see journalctl -u maddy" )"
echo " Mailboxes   : ${MAILBOX_COUNT} (logins in ${MAILBOX_DIR}/, one file per day)"
echo " Firewall    : ${FIREWALL_STATE}"
echo " fail2ban    : ${FAIL2BAN_STATE}"
echo " Max mail    : ${MAX_MESSAGE_SIZE} (bigger messages are rejected)"
echo
echo " IMAP access : ${MAIL_HOSTNAME}   port 993 (SSL/TLS)"
echo "               certificate: ${MAIL_CERT:-self-signed -> accept it in your client}"
echo "               user = the full email address"
case "$WEBMAIL_OK" in
  https) echo " Webmail     : https://${MAIL_HOSTNAME}/  (valid certificate)" ;;
  http)  echo " Webmail     : http://${MAIL_HOSTNAME}/   (certificate pending)" ;;
  skipped) echo " Webmail     : not installed" ;;
esac
echo "------------------------------------------------------------"
echo " Create more mailboxes:  ./create-mailboxes.sh <count> [domain|--all]"
echo " Add/remove domains   :  ./manage-domains.sh add|remove|list"
echo "------------------------------------------------------------"
echo " Auto-start after a reboot:"
for svc in maddy ${WEBMAIL_SERVICES:-} ${CERT_SERVICES:-} ${HOUSEKEEPING_SERVICES:-} ${SECURITY_SERVICES:-}; do
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    echo "   [x] ${svc} - enabled"
  else
    echo "   [ ] ${svc} - NOT enabled!  fix: systemctl enable ${svc}"
  fi
done
echo "------------------------------------------------------------"
echo " DNS you must set (at your registrar):"
echo "   ${MAIL_HOSTNAME}.  A   <this server's IP>"
for d in "${DOMAIN_LIST[@]}"; do
  echo "   ${d}.  MX  10  ${MAIL_HOSTNAME}."
done
echo "============================================================"
