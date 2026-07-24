#!/usr/bin/env bash
#
# Delete mailboxes. Run on the server as root.
#
#   ./delete-mailboxes.sh --list
#   ./delete-mailboxes.sh user@example.com [more@example.com ...]
#   ./delete-mailboxes.sh --domain example.com
#   ./delete-mailboxes.sh --all
#
# This deletes the mailbox and everything stored in it. Add --yes to skip the
# confirmation prompt. The addresses are also dropped from every batch file in
# mailboxes/, so the logins on disk stay in sync.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MAILBOX_DIR="mailboxes"
LEGACY_FILE="mailboxes.txt"      # what older versions wrote everything into

die() { echo "Error: $*" >&2; exit 1; }

# every dated batch file, plus the old single file if it's still around
login_files() {
  [[ -f "$LEGACY_FILE" ]] && printf '%s\n' "$LEGACY_FILE"
  [[ -d "$MAILBOX_DIR" ]] && find "$MAILBOX_DIR" -maxdepth 1 -type f -name '*.txt' | sort
  return 0
}

usage() {
  echo "Usage:"
  echo "  $0 --list"
  echo "  $0 <address> [<address> ...]"
  echo "  $0 --domain <domain>"
  echo "  $0 --all"
  echo "  (add --yes to skip the confirmation)"
  exit 1
}

# stopping maddy wipes /run/maddy (systemd RuntimeDirectory=), and the maddy
# user can't recreate it itself - so make sure it's there on every call
mc() {
  mkdir -p /run/maddy 2>/dev/null || true
  chown maddy:maddy /run/maddy 2>/dev/null || true
  runuser -u maddy -- maddy "$@"
}

[[ $EUID -eq 0 ]] || die "Please run as root (sudo $0 ...)."
[[ $# -ge 1 ]] || usage
[[ -f /etc/maddy/maddy.conf ]] || die "maddy is not set up yet."

ASSUME_YES=no
ARGS=()
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=yes ;;
    *) ARGS+=("$a") ;;
  esac
done
[[ ${#ARGS[@]} -ge 1 ]] || usage

existing_accounts() { mc creds list 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d'; }

if [[ "${ARGS[0]}" == "--list" ]]; then
  n=0
  while IFS= read -r a; do echo "  $a"; n=$(( n + 1 )); done < <(existing_accounts)
  echo "$n mailbox(es)."
  exit 0
fi

# --- work out what to delete ----------------------------------------------

TARGETS=()
case "${ARGS[0]}" in
  --all)
    mapfile -t TARGETS < <(existing_accounts)
    ;;
  --domain)
    [[ ${#ARGS[@]} -ge 2 ]] || die "--domain needs a domain name."
    dom="$(printf '%s' "${ARGS[1]}" | tr 'A-Z' 'a-z')"
    mapfile -t TARGETS < <(existing_accounts | grep -i "@${dom}\$" || true)
    ;;
  --*)
    usage
    ;;
  *)
    for a in "${ARGS[@]}"; do
      TARGETS+=("$(printf '%s' "$a" | tr 'A-Z' 'a-z')")
    done
    ;;
esac

[[ ${#TARGETS[@]} -gt 0 ]] || { echo "Nothing matched - nothing to do."; exit 0; }

echo "This deletes these mailboxes and ALL mail in them:"
printf '  %s\n' "${TARGETS[@]}"
echo "(${#TARGETS[@]} total)"
if [[ "$ASSUME_YES" != yes ]]; then
  [[ -t 0 ]] || die "Not a terminal - pass --yes if you really mean it."
  read -rp "Type 'yes' to confirm: " ans
  [[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

# --- delete ----------------------------------------------------------------

restart_maddy() {
  systemctl reset-failed maddy 2>/dev/null || true
  systemctl start maddy 2>/dev/null || true
}
trap restart_maddy EXIT
systemctl stop maddy 2>/dev/null || true

deleted=0
missing=0
for addr in "${TARGETS[@]}"; do
  [[ -z "$addr" ]] && continue
  ok=no
  mc creds remove --yes "$addr" >/dev/null 2>&1 && ok=yes
  mc imap-acct remove --yes "$addr" >/dev/null 2>&1 && ok=yes
  if [[ "$ok" == yes ]]; then
    echo "  - $addr"
    deleted=$(( deleted + 1 ))
  else
    echo "  ? $addr - did not exist"
    missing=$(( missing + 1 ))
  fi
done

chown -R maddy:maddy /var/lib/maddy

# --- drop the addresses from the batch files -------------------------------

PRUNE_LIST="$(mktemp)"
printf '%s\n' "${TARGETS[@]}" > "$PRUNE_LIST"
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] || continue
  tmp="$(mktemp)"
  # compare against the part before the first ':' so a password can't match
  awk -F: 'NR==FNR { gone[$0]=1; next } !($1 in gone)' "$PRUNE_LIST" "$f" > "$tmp" || true
  mv "$tmp" "$f"
  chmod 600 "$f"
  [[ -s "$f" ]] || rm -f "$f"      # an emptied batch file is just noise
done < <(login_files)
rm -f "$PRUNE_LIST"

remaining=0
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] || continue
  remaining=$(( remaining + $(grep -c ':' "$f" || true) ))
done < <(login_files)

echo
echo "Deleted ${deleted} mailbox(es)$( [[ $missing -gt 0 ]] && echo ", ${missing} did not exist" )."
echo "${remaining} login(s) left in ${MAILBOX_DIR}/."
