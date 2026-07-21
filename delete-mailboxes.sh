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
# confirmation prompt. The addresses are also dropped from mailboxes.txt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUT_FILE="mailboxes.txt"

die() { echo "Error: $*" >&2; exit 1; }

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
  # drop it from the list; index()==1 is an exact prefix, so no regex surprises
  if [[ -f "$OUT_FILE" ]]; then
    tmp="$(mktemp)"
    awk -v a="${addr}:" 'index($0, a) != 1' "$OUT_FILE" > "$tmp" || true
    mv "$tmp" "$OUT_FILE"
    chmod 600 "$OUT_FILE"
  fi
done

chown -R maddy:maddy /var/lib/maddy

echo
echo "Deleted ${deleted} mailbox(es)$( [[ $missing -gt 0 ]] && echo ", ${missing} did not exist" )."
[[ -f "$OUT_FILE" ]] && echo "$(grep -c ':' "$OUT_FILE" || true) left in ${OUT_FILE}."
