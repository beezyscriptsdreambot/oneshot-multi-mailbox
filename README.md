# One-Shot Multi Mailbox (Maddy + Webmail)

Set up a mail server on a fresh Linux KVM with a single command, then create as
many **individual mailboxes** as you want with one more command. Each mailbox
has its own address, its own password and its own inbox — users log in through
the browser or any IMAP client and only ever see their own mail.

Addresses are generated from `names.txt` (~195,000 names): two names are glued
together, e.g. **`mariesmith@yourdomain.tld`**. Logins are written as
`email:password`, one per line, into **one file per day** —
`mailboxes/mailboxes-2026-07-24.txt` — so every batch stays separate and you can
tell at a glance which accounts came from which run.

Runs [Maddy](https://maddy.email) natively (no Docker) — around 50–200 MB RAM.

> **Receiving only.** This server collects mail; it does not send.

---

## Quick start

On a fresh server:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/beezyscriptsdreambot/oneshot-multi-mailbox.git
cd oneshot-multi-mailbox
chmod +x setup.sh create-mailboxes.sh delete-mailboxes.sh manage-domains.sh
sudo ./setup.sh                    # installs everything
sudo ./create-mailboxes.sh 50      # creates 50 mailboxes
sudo cat mailboxes/*.txt           # email:password, one per line
```

The scripts need root — run them with `sudo` (or as root, then drop the `sudo`).

**Set your DNS first** (step 2) — otherwise no mail can reach the server.

---

## 1. What you need before you start

| | |
|--|--|
| **Server** | Fresh **Ubuntu 22.04/24.04** or **Debian 12**, real **KVM** (not LXC/OpenVZ), ≥1 GB RAM, root |
| **Ports** | See the table below — **port 25 usually needs a support request** |
| **Domain** | At least one domain where you can edit DNS |
| **Dedicated** | Don't run this next to other web/mail services — they fight over ports 25/80/443 |

### Ports that must be open

If you let `setup.sh` turn on the firewall (it asks), it switches `ufw` to
"deny everything except these ports". That only covers the **server's own**
firewall — most VPS providers have a **second firewall in their panel** that is
closed by default, so open the ports there too.

| Port | Protocol | Needed for | Source |
|--|--|--|--|
| **22** | TCP | SSH — don't lock yourself out | your IP or `0.0.0.0/0` |
| **25** | TCP | **receiving mail** — nothing arrives without it | `0.0.0.0/0` |
| **80** | TCP | Let's Encrypt renewal + HTTP→HTTPS redirect | `0.0.0.0/0` |
| **443** | TCP | webmail | `0.0.0.0/0` |
| **993** | TCP | IMAP over TLS (mail apps) | `0.0.0.0/0` |
| 143 | TCP | IMAP+STARTTLS — optional, 993 is usually enough | `0.0.0.0/0` |

> **The mail ports must accept `0.0.0.0/0`.** Mail arrives from arbitrary
> servers worldwide, so the source cannot be restricted. Only port 22 can
> sensibly be limited to your own IP.

> **Port 80 matters even though webmail runs on 443.** certbot renews the
> certificate over port 80 every 90 days — close it and HTTPS works today but
> silently breaks in three months.

> ⚠️ **Port 25 is special.** Nearly every provider blocks it by default to fight
> spam, and a panel firewall rule often isn't enough — the block sits in their
> network. If port 25 is refused or times out from outside while your server is
> listening, open a support ticket:
> *"Please unblock inbound SMTP port 25 for my instance &lt;IP&gt;, I run a mail server."*

---

## 2. Set up DNS (do this first)

```dns
; ONE A record for the mail server itself
mail.yourserver.tld.   A    <your-server-ip>

; ONE MX record per domain, all pointing at that same hostname
yourdomain.tld.        MX   10   mail.yourserver.tld.
otherdomain.com.       MX   10   mail.yourserver.tld.
```

- The MX **target** must be the hostname from the A record — never an IP.
- In most DNS panels the MX "host/name" field stays **empty** (= domain root).
- Check it worked:
  ```bash
  dig +short A  mail.yourserver.tld
  dig +short MX yourdomain.tld
  ```

DNS can take minutes to hours. For receiving, A + MX is all you need —
SPF/DKIM/DMARC and reverse DNS only matter for *sending*.

---

## 3. Run the setup

```bash
sudo ./setup.sh
```

It asks for everything it needs:

```
Mail server hostname (FQDN, e.g. mail.example.tld): mail.yourserver.tld
Domains to receive mail for (space-separated): yourdomain.tld
Install browser webmail (SnappyMail + HTTPS)? yes/no [yes]: yes
How many mailboxes to create right away? (0 = none) [0]: 50
Delete mail older than how many days? (0 = never) [30]: 30
Keep how many days of database backups? (0 = none) [7]: 7
Install automatic security updates? yes/no [yes]: yes
Turn on the ufw firewall (only the needed ports stay open)? yes/no [yes]: yes
SSH port to keep open (a wrong value locks you out) [22]: 22
Install fail2ban (bans brute-force on SSH and IMAP)? yes/no [yes]: yes
```

Answer `no` to the last three and nothing firewall- or fail2ban-related is
installed or changed — see [section 5](#5-firewall-and-brute-force-protection).

Prefer a config file? Fill it in beforehand and nothing is asked:

```bash
cp setup.conf.example setup.conf
nano setup.conf
sudo ./setup.sh
```

The setup then:

1. prefers IPv4 (many VPS have broken IPv6 outbound — avoids long hangs)
2. installs the Maddy binaries (pinned version)
3. creates a TLS certificate for the mail ports
4. writes `/etc/maddy/maddy.conf` — one mailbox per address, unknown recipients rejected
5. installs a systemd service (**auto-starts on every reboot**)
6. optionally turns on the firewall (SSH/25/143/993, plus 80/443 with webmail)
7. optionally installs fail2ban against password guessing
8. optionally installs SnappyMail webmail behind nginx with a **Let's Encrypt** certificate
9. sets up daily retention, database backups and security updates
10. creates the initial batch of mailboxes, if you asked for any

Re-running is safe: existing mailboxes keep their passwords.

---

## 4. Create mailboxes

```bash
sudo ./create-mailboxes.sh 50                  # the only configured domain
sudo ./create-mailboxes.sh 50 example.com      # a specific domain
sudo ./create-mailboxes.sh 50 --all            # spread across all domains
```

Each run:

- picks two random names from `names.txt` → `mariesmith@example.com`
- **skips addresses that already exist** and draws a new one instead
- generates a 20-character random password
- **appends** the login to today's file, `mailboxes/mailboxes-YYYY-MM-DD.txt`

At the end it logs into one of the new mailboxes over IMAP to confirm the
password actually works, instead of assuming the account creation succeeded.

```
mariesmith@example.com:kP3nQx8ZmR2vLtY7bW4s
johndoe@example.com:aB9cD1eF2gH3iJ4kL5mN
```

Names are filtered to plain letters, at least 3 characters — entries like `A`,
`A-jay` or `O'brien` are skipped. That leaves ~195,000 names, so roughly
**38 billion** possible addresses; collisions are practically nonexistent but
handled anyway.

> The files in `mailboxes/` are the only place the passwords exist in readable
> form. Maddy stores them hashed. Keep them safe — the folder is in
> `.gitignore`.

### One file per day

Every run appends to a file named after the date, so batches never get mixed up:

```
mailboxes/
├── mailboxes-2026-07-20.txt     ← 50 created on the 20th
├── mailboxes-2026-07-22.txt     ← 15 created on the 22nd
└── mailboxes-2026-07-24.txt     ← today's batch
```

Two runs on the **same day** land in the same file. Deleting a mailbox removes
its line from whichever file it's in, and a file that ends up empty is removed.

### Show the logins

The files are owned by root with `chmod 600`, so **`sudo` is needed** — a plain
`cat` gives "Permission denied".

```bash
cd ~/oneshot-multi-mailbox

sudo ls -1 mailboxes/                              # which batches exist
sudo cat mailboxes/mailboxes-2026-07-24.txt        # one specific day
sudo cat mailboxes/*.txt                           # every login
sudo wc -l mailboxes/*.txt                         # how many per day
```

Filtering across all batches:

```bash
sudo grep -h '@example.com:' mailboxes/*.txt       # only one domain
sudo grep -l 'mariesmith@' mailboxes/*.txt         # which day was it created?
sudo cat mailboxes/mailboxes-2026-07-2*.txt        # a date range
sudo head -1 mailboxes/mailboxes-2026-07-24.txt    # just one, for a quick test
```

`-h` hides the filename prefix that `grep` adds when reading several files;
`-l` shows only the filename, which is how you find out when an account was made.

Nicer to read (address and password in two columns):

```bash
sudo column -t -s: mailboxes/mailboxes-2026-07-24.txt
```

> Careful with redirects: `sudo wc -l < mailboxes/x.txt` fails, because the `<`
> is done by your shell, not by sudo. Pass the file as an argument instead.

Split into address and password separately:

```bash
sudo cut -d: -f1 mailboxes/*.txt            # addresses only
sudo cut -d: -f2 mailboxes/*.txt            # passwords only
```

### Copy the logins to your own computer

`scp` runs as your login user and can't read root-owned 0600 files, so make a
readable copy first:

```bash
# on the server - one day, or everything in one file
sudo cp mailboxes/mailboxes-2026-07-24.txt /tmp/logins.txt
sudo cat mailboxes/*.txt > /tmp/logins.txt      # or all batches at once
sudo chown $USER /tmp/logins.txt

# on your own machine
scp ubuntu@<server-ip>:/tmp/logins.txt .

# back on the server, clean up - it's world-readable in /tmp otherwise
rm -f /tmp/logins.txt
```

---

## 4b. Delete mailboxes

```bash
sudo ./delete-mailboxes.sh --list                    # what exists
sudo ./delete-mailboxes.sh user@example.com          # one or more addresses
sudo ./delete-mailboxes.sh --domain example.com      # every mailbox of a domain
sudo ./delete-mailboxes.sh --all                     # everything
```

Deleting removes the mailbox **and all mail in it**, and drops the line from
whichever batch file in `mailboxes/` it sits in. You get a confirmation prompt
first — add `--yes` to skip it (for scripts).

---

## 5. Firewall and brute-force protection

Both are **optional** and off unless you say yes. `setup.sh` asks about them, or
you set them in `setup.conf`:

```bash
ENABLE_FIREWALL=yes    # ufw: deny everything except the ports below
SSH_PORT=22            # stays open when the firewall goes on
INSTALL_FAIL2BAN=yes   # ban IPs that guess passwords
```

Answer `no` (or set `no`) and the setup touches neither — no packages are
installed, no rules are written, and an existing `ufw` configuration is left
exactly as it is.

### Firewall (ufw)

With `ENABLE_FIREWALL=yes` the setup allows SSH, 25, 143 and 993 (plus 80 and
443 if you install webmail), sets the default to *deny incoming*, and only then
switches `ufw` on. The order matters: enabling a firewall before allowing SSH
ends your session permanently.

The SSH port is read from `sshd_config` and shown as the default, so a
non-standard port doesn't lock you out — but **check the value it offers** before
pressing Enter.

```bash
sudo ufw status verbose      # what's open
sudo ufw allow 8443/tcp      # open something else later
sudo ufw disable             # turn it off again
```

### fail2ban

With `INSTALL_FAIL2BAN=yes` you get two jails: `sshd` and `maddy`. Both ban an
IP for **1 hour after 5 failed logins within 10 minutes**. Without this, nothing
stops someone from trying passwords against port 993 all day.

```bash
sudo fail2ban-client status              # which jails are active
sudo fail2ban-client status sshd         # failures and current bans
sudo fail2ban-client status maddy
sudo fail2ban-client set maddy unbanip 1.2.3.4    # unban yourself
```

Bans are written through `ufw` when the firewall is on, otherwise straight into
iptables.

> **Worth verifying once.** The `sshd` jail is standard and reliable. The
> `maddy` jail depends on how Maddy words its log lines, which can change
> between releases. After the server has seen some real traffic, run
> `sudo fail2ban-client status maddy` — if `Total failed` stays at 0 while
> `journalctl -u maddy | grep -i auth` clearly shows failed logins, the filter
> in `/etc/fail2ban/filter.d/maddy.conf` needs its regex adjusted.

### Adding them later

Set the values in `setup.conf` and re-run `sudo ./setup.sh` — it only adds what
is missing and leaves your mailboxes and mail alone.

---

## 6. Log in

### Browser (if webmail was installed)
**`https://mail.yourserver.tld/`** — username is the **full email address**,
password from the batch file in `mailboxes/`.

### Mail app (IMAP)
| Setting | Value |
|--|--|
| Server | `mail.yourserver.tld` |
| Port | **993**, SSL/TLS |
| User | the full address, e.g. `mariesmith@example.com` |
| Password | from `mailboxes/mailboxes-<date>.txt` |
| Certificate | trusted (Let's Encrypt) if webmail was installed, otherwise self-signed |

Every user only sees their own mailbox. The username is always the **full
address** — not just the part before the `@`.

Test a login from the server at any time:

```bash
line=$(cat mailboxes/*.txt | head -1); user="${line%%:*}"; pass="${line#*:}"
python3 - "$user" "$pass" <<'EOF'
import imaplib, ssl, sys
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
M = imaplib.IMAP4_SSL("127.0.0.1", 993, ssl_context=ctx)
M.login(sys.argv[1], sys.argv[2]); print("LOGIN OK"); M.select("INBOX"); M.logout()
EOF
```

---

## 7. Add or remove domains

```bash
sudo ./manage-domains.sh list                  # domains + mailbox counts
sudo ./manage-domains.sh add    newdomain.com
sudo ./manage-domains.sh remove olddomain.com  # deletes its mailboxes and mail!
```

Adding a domain only makes Maddy accept mail for it — create the mailboxes
afterwards with `sudo ./create-mailboxes.sh <count> newdomain.com`. The webmail needs
no change; it routes every domain to the local Maddy.

Don't forget the **MX record** for each new domain.

---

## 8. Housekeeping

Configured in `setup.conf`:

```bash
RETENTION_DAYS=30    # delete mail older than 30 days (0 = keep forever)
BACKUP_DAYS=7        # keep 7 days of database backups (0 = none)
AUTO_UPDATES=yes     # unattended security updates
```

| What | How |
|--|--|
| **Old mail deleted** | daily via `maddy-cleanup.timer`, using IMAP `SEARCH BEFORE` across every folder |
| **Backups** | daily to `/var/backups/maddy`, online-safe `sqlite3 .backup`, rotated |
| **Security updates** | `unattended-upgrades` |

```bash
systemctl list-timers 'maddy-*'
systemctl start maddy-cleanup.service   # run the cleanup now
journalctl -u maddy-cleanup -n 20
```

> The cleanup logs in over IMAP using the passwords in `mailboxes/`. If you
> change a password by hand, update that file too, or the mailbox is skipped
> (it says so in the log).

---

## 9. Useful commands

```bash
# which domains are configured?
grep local_domains /etc/maddy/maddy.conf

# which mailboxes exist? (runuser needs root)
sudo runuser -u maddy -- maddy creds list
sudo runuser -u maddy -- maddy creds list | wc -l

# logins - per day, or all of them (files are root-owned, 0600)
sudo ls -1 mailboxes/
sudo cat mailboxes/mailboxes-2026-07-24.txt
sudo cat mailboxes/*.txt

# reset one password (takes effect immediately)
sudo runuser -u maddy -- maddy creds password --password 'NEWPASS' user@example.com

# status, logs, listening ports
systemctl status maddy
sudo journalctl -u maddy -f
sudo ss -tlnp '( sport = :25 or sport = :993 )'

# firewall and bans (if you installed them)
sudo ufw status verbose
sudo fail2ban-client status sshd

# does everything come back after a reboot?
systemctl is-enabled maddy nginx certbot.timer maddy-cleanup.timer
```

Passwords are stored **hashed** and cannot be read back from Maddy — that's what
the files in `mailboxes/` are for. If a password is lost, set a new one with the
command above (and update the batch file).

---

## 10. Limitations

- **Receiving only** — no sending/submission is configured.
- **Unknown addresses are rejected.** Only addresses you created exist; mail to
  anything else bounces. There is no catch-all.
- **Barely any spam filtering** — expect junk.
- **Passwords live in plain text.** Anyone who can read `mailboxes/` has every
  mailbox. Splitting by date limits the blast radius of a single leaked file,
  nothing more.
- **Version-pinned** — `MADDY_VERSION` at the top of `setup.sh`.

---

## 11. Troubleshooting

**Maddy won't start**
```bash
journalctl -u maddy -n 50 --no-pager
```
It names the exact `maddy.conf` line it choked on.

**IMAP times out from outside, but works on the server**
```bash
openssl s_client -connect 127.0.0.1:993 -brief </dev/null   # must show a certificate
ufw status
```
If that works, the block is **outside** the machine — open 993 (and 25) in the
provider's firewall. `timeout` means packets are dropped; `connection refused`
means something actively rejects them (typical for a provider port-25 block).

**Mail never arrives (but IMAP/webmail work)**
Port 25 is closed. Everything else can be perfect and the mailbox stays empty.

**Mail bounces with "User does not exist"**
That address has no mailbox. Create it with `sudo ./create-mailboxes.sh`, or check
the exact spelling in `mailboxes/`.

**Downloads hang for minutes / `connection timed out`**
Broken IPv6 outbound. `setup.sh` sets IPv4 preference; elsewhere:
```bash
echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
```

**`address already in use` (port 25/80/443)**
```bash
ss -tlnp '( sport = :25 or sport = :80 or sport = :443 )'
systemctl disable --now apache2   # or nginx / postfix / dovecot
sudo ./setup.sh
```

**Locked out of SSH** (`ssh` hangs) — a firewall blocks port 22, the box is out
of memory, or fail2ban banned you after too many wrong passwords. Use the
provider's web/VNC console:
```bash
ufw allow 22/tcp && ufw reload
fail2ban-client status sshd                  # is your IP in the ban list?
fail2ban-client set sshd unbanip <your-ip>
free -h
systemd-detect-virt     # must be 'kvm', not lxc/openvz
```

**fail2ban never bans anything on IMAP**
`fail2ban-client status maddy` shows `Total failed: 0` even though the journal
clearly has failed logins. The filter regex doesn't match your Maddy version's
log wording. Compare the two:
```bash
journalctl -u maddy | grep -i 'auth' | tail -5
fail2ban-regex "$(journalctl -u maddy -n 2000 --no-pager)" /etc/fail2ban/filter.d/maddy.conf
```
Adjust `failregex` in that file to match, then `systemctl restart fail2ban`.
The `sshd` jail is unaffected and keeps working either way.

**Webmail: "Cannot assign null to property … type"**
The SnappyMail domain config is incomplete — re-run `./setup.sh`, it rewrites
`/var/www/snappymail/data/_data_/_default_/domains/default.json`.

**Start over**
```bash
systemctl stop maddy
rm -rf /var/lib/maddy/*.db mailboxes/ mailboxes.txt
sudo ./setup.sh
```

---

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | One-shot installer — mail server + optional webmail |
| `create-mailboxes.sh` | Create N mailboxes from `names.txt` |
| `delete-mailboxes.sh` | Delete mailboxes (single, per domain, or all) |
| `manage-domains.sh` | Add/remove/list domains |
| `setup.conf.example` | Config template (copy to `setup.conf`) |
| `names.txt` | ~195,000 names used to build addresses |
| `domains.txt` | Your domains, kept in sync by the scripts |
| `mailboxes/` | Generated: one `mailboxes-YYYY-MM-DD.txt` per day, `email:password` per line (git-ignored) |
