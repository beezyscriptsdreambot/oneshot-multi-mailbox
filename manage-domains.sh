#!/usr/bin/env bash
#
# Add, remove or list domains. Run on the server as root.
#
#   ./manage-domains.sh list
#   ./manage-domains.sh add    example.org [more.com ...]
#   ./manage-domains.sh remove example.org
#
# Adding only makes maddy accept mail for the domain - create the mailboxes
# with ./create-mailboxes.sh afterwards. Removing deletes every mailbox of
# that domain along with its stored mail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONF="/etc/maddy/maddy.conf"
OUT_FILE="$SCRIPT_DIR/mailboxes.txt"

usage() {
  echo "Usage:"
  echo "  $0 list"
  echo "  $0 add    <domain> [<domain> ...]"
  echo "  $0 remove <domain> [<domain> ...]"
  exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

# CLI has to run as maddy so the sqlite files stay owned by the service user
mc() {
  mkdir -p /run/maddy 2>/dev/null || true
  chown maddy:maddy /run/maddy 2>/dev/null || true
  runuser -u maddy -- maddy "$@"
}

read_domains() {
  DOMAINS=()
  [[ -f domains.txt ]] || return 0
  local line norm
  while IFS= read -r line || [[ -n "$line" ]]; do
    norm="$(printf '%s' "$line" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    [[ -z "$norm" || "$norm" == \#* ]] && continue
    DOMAINS+=("$norm")
  done < domains.txt
}

has_domain() {
  local d="$1" x
  for x in "${DOMAINS[@]:-}"; do [[ "$x" == "$d" ]] && return 0; done
  return 1
}

valid_domain() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

write_local_domains() {
  [[ -f "$CONF" ]] || die "$CONF not found - run ./setup.sh first."
  local list="${DOMAINS[*]:-}"
  # [\$] is a literal '$' - plain $ would be an anchor / shell expansion
  sed -i "s|^[\$](local_domains) = .*|\$(local_domains) = ${list}|" "$CONF"
}

# keeps comments and blank lines intact
drop_from_domains_file() {
  local d="$1" line norm tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    norm="$(printf '%s' "$line" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    [[ "$norm" == "$d" ]] && continue
    printf '%s\n' "$line" >> "$tmp"
  done < domains.txt
  mv "$tmp" domains.txt
}

restart_maddy() {
  systemctl reset-failed maddy 2>/dev/null || true
  systemctl start maddy 2>/dev/null || true
}

# --- pre-flight ---
[[ $EUID -eq 0 ]] || die "Please run as root or with sudo."
[[ $# -ge 1 ]] || usage
[[ -f setup.conf ]] && { set -a; source setup.conf; set +a; }
MAIL_HOSTNAME="${MAIL_HOSTNAME:-}"
[[ -n "$MAIL_HOSTNAME" ]] || die "hostname not set - check setup.conf."

CMD="$1"; shift || true

if [[ "$CMD" == "list" ]]; then
  read_domains
  echo "Configured domains (${#DOMAINS[@]}):"
  for d in "${DOMAINS[@]:-}"; do
    [[ -z "$d" ]] && continue
    n="$(mc creds list 2>/dev/null | grep -c "@${d}\$" || true)"
    echo "  - $d  (${n} mailbox(es))"
  done
  exit 0
fi

if [[ "$CMD" == "add" ]]; then
  [[ $# -ge 1 ]] || usage
  read_domains
  ADDED=()
  for raw in "$@"; do
    d="$(printf '%s' "$raw" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    valid_domain "$d" || { echo "  skip '$raw' - not a valid domain name."; continue; }
    if has_domain "$d"; then echo "  $d already configured - skipped."; continue; fi
    printf '%s\n' "$d" >> domains.txt
    ADDED+=("$d"); DOMAINS+=("$d")
  done
  [[ ${#ADDED[@]} -gt 0 ]] || { echo "Nothing to add."; exit 0; }

  write_local_domains
  restart_maddy
  echo
  echo "Added ${#ADDED[@]} domain(s). Set the DNS MX record for each:"
  for d in "${ADDED[@]}"; do echo "  ${d}.   MX   10   ${MAIL_HOSTNAME}."; done
  echo "Then create mailboxes:  ./create-mailboxes.sh <count> ${ADDED[0]}"
  exit 0
fi

if [[ "$CMD" == "remove" ]]; then
  [[ $# -ge 1 ]] || usage
  read_domains
  REMOVE=()
  for raw in "$@"; do
    d="$(printf '%s' "$raw" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    if has_domain "$d"; then REMOVE+=("$d"); else echo "  $d not configured - skipped."; fi
  done
  [[ ${#REMOVE[@]} -gt 0 ]] || { echo "Nothing to remove."; exit 0; }

  echo "This will DELETE every mailbox and ALL stored mail for:"
  for d in "${REMOVE[@]}"; do
    n="$(mc creds list 2>/dev/null | grep -c "@${d}\$" || true)"
    echo "  - $d  (${n} mailbox(es))"
  done
  read -rp "Type 'yes' to confirm: " ans
  [[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }

  trap restart_maddy EXIT
  systemctl stop maddy 2>/dev/null || true
  for d in "${REMOVE[@]}"; do drop_from_domains_file "$d"; done
  read_domains
  write_local_domains

  for d in "${REMOVE[@]}"; do
    while IFS= read -r acct; do
      [[ -z "$acct" ]] && continue
      mc creds remove --yes "$acct" >/dev/null 2>&1 || true
      mc imap-acct remove --yes "$acct" >/dev/null 2>&1 || true
      echo "  - removed $acct"
    done < <(mc creds list 2>/dev/null | grep "@${d}\$" || true)

    if [[ -f "$OUT_FILE" ]]; then
      tmp="$(mktemp)"
      grep -v "@${d}:" "$OUT_FILE" > "$tmp" || true
      mv "$tmp" "$OUT_FILE"
    fi
  done
  echo
  echo "Removed ${#REMOVE[@]} domain(s). You can delete their MX records at the registrar."
  exit 0
fi

usage
