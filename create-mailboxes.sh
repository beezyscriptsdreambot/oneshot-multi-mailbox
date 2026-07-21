#!/usr/bin/env bash
#
# Create mailboxes with names picked from names.txt.
#
#   ./create-mailboxes.sh 50                 # only domain configured
#   ./create-mailboxes.sh 50 example.com     # that domain
#   ./create-mailboxes.sh 50 --all           # spread over all domains
#
# Addresses are two names glued together (mariesmith@example.com). Existing
# addresses are skipped and a new one is drawn instead. Logins are appended to
# mailboxes.txt as email:password, one per line.

set -euo pipefail

# mapfile and associative arrays need bash 4+
[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]] || { echo "Error: needs bash 4 or newer." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMES_FILE="names.txt"
OUT_FILE="mailboxes.txt"
MIN_NAME_LEN=3
MAX_ATTEMPT_FACTOR=50   # give up after count*this draws

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root (sudo ./create-mailboxes.sh ...)."
[[ $# -ge 1 ]] || die "Usage: $0 <count> [domain|--all]"

COUNT="$1"
[[ "$COUNT" =~ ^[0-9]+$ ]] && [[ "$COUNT" -gt 0 ]] || die "count must be a positive number."
TARGET="${2:-}"

[[ -f "$NAMES_FILE" ]] || die "$NAMES_FILE not found."
[[ -f /etc/maddy/maddy.conf ]] || die "maddy is not set up yet - run ./setup.sh first."

# --- domains ---------------------------------------------------------------

DOMAINS=()
if [[ -f domains.txt ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(printf '%s' "$line" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    [[ -z "$line" || "$line" == \#* ]] && continue
    DOMAINS+=("$line")
  done < domains.txt
fi
[[ ${#DOMAINS[@]} -gt 0 ]] || die "No domains configured (domains.txt is empty)."

USE_DOMAINS=()
case "$TARGET" in
  --all) USE_DOMAINS=("${DOMAINS[@]}") ;;
  "")
    if [[ ${#DOMAINS[@]} -eq 1 ]]; then
      USE_DOMAINS=("${DOMAINS[0]}")
    else
      echo "Several domains are configured:" >&2
      printf '  %s\n' "${DOMAINS[@]}" >&2
      die "Pick one (e.g. $0 $COUNT ${DOMAINS[0]}) or use --all."
    fi
    ;;
  *)
    for d in "${DOMAINS[@]}"; do [[ "$d" == "$TARGET" ]] && USE_DOMAINS=("$TARGET"); done
    [[ ${#USE_DOMAINS[@]} -gt 0 ]] || die "$TARGET is not configured. See domains.txt."
    ;;
esac

# --- names -----------------------------------------------------------------

echo "Loading names..."
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
# drop anything with apostrophes, hyphens or fewer than MIN_NAME_LEN letters
grep -E "^[A-Za-z]{${MIN_NAME_LEN},}$" "$NAMES_FILE" | tr 'A-Z' 'a-z' | sort -u > "$TMP"
mapfile -t NAMES < "$TMP"
TOTAL=${#NAMES[@]}
[[ $TOTAL -gt 1 ]] || die "$NAMES_FILE has no usable names."
echo "  $TOTAL usable names"

# RANDOM alone only goes to 32767, which is smaller than the name list
pick() { printf '%s' "${NAMES[$(( (RANDOM * 32768 + RANDOM) % TOTAL ))]}"; }

# --- existing accounts -----------------------------------------------------

# stopping maddy wipes /run/maddy (systemd RuntimeDirectory=), and the maddy
# user can't recreate it itself - so make sure it's there on every call
mc() {
  mkdir -p /run/maddy 2>/dev/null || true
  chown maddy:maddy /run/maddy 2>/dev/null || true
  runuser -u maddy -- maddy "$@"
}

declare -A TAKEN
while IFS= read -r acct; do
  acct="$(printf '%s' "$acct" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  [[ -n "$acct" ]] && TAKEN["$acct"]=1
done < <(mc creds list 2>/dev/null || true)
echo "  ${#TAKEN[@]} mailbox(es) already exist"

# --- create ----------------------------------------------------------------

restart_maddy() {
  systemctl reset-failed maddy 2>/dev/null || true
  systemctl start maddy 2>/dev/null || true
}
trap 'rm -f "$TMP"; restart_maddy' EXIT

# stop maddy so the CLI doesn't fight it over the sqlite files
systemctl stop maddy 2>/dev/null || true

created=0
attempts=0
max_attempts=$(( COUNT * MAX_ATTEMPT_FACTOR ))
di=0

echo "Creating $COUNT mailbox(es)..."
while [[ $created -lt $COUNT ]]; do
  attempts=$(( attempts + 1 ))
  [[ $attempts -le $max_attempts ]] || die "Gave up after $attempts draws - too many collisions."

  domain="${USE_DOMAINS[$(( di % ${#USE_DOMAINS[@]} ))]}"
  addr="$(pick)$(pick)@${domain}"
  [[ -n "${TAKEN[$addr]:-}" ]] && continue

  pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"; pw="${pw:0:20}"

  # only "already exists" counts as a collision - anything else is a real
  # failure and would otherwise look like an endless string of collisions
  if ! err="$(mc imap-acct create "$addr" 2>&1)"; then
    if printf '%s' "$err" | grep -qi 'exist'; then
      TAKEN["$addr"]=1; continue
    fi
    die "could not create mailbox $addr:
$err"
  fi
  if ! err="$(mc creds create --password "$pw" "$addr" 2>&1)"; then
    if printf '%s' "$err" | grep -qi 'exist'; then
      TAKEN["$addr"]=1; continue
    fi
    # older builds want the password on stdin instead of --password
    if ! err="$(printf '%s\n%s\n' "$pw" "$pw" | mc creds create "$addr" 2>&1)"; then
      die "could not set the password for $addr:
$err"
    fi
  fi

  printf '%s:%s\n' "$addr" "$pw" >> "$OUT_FILE"
  TAKEN["$addr"]=1
  created=$(( created + 1 ))
  di=$(( di + 1 ))
  printf '  %s:%s\n' "$addr" "$pw"
done

chown -R maddy:maddy /var/lib/maddy
chmod 600 "$OUT_FILE"

echo
echo "Created $created mailbox(es) in $attempts draw(s)."
echo "Logins appended to $(pwd)/$OUT_FILE"
echo "Log in at the webmail or over IMAP with the full address as username."
