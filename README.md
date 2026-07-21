# One-Shot Multi Mailbox (Maddy + Webmail)

Set up a mail server on a fresh Linux KVM with a single command, then create as
many **individual mailboxes** as you want with one more command. Each mailbox
has its own address, its own password and its own inbox — users log in through
the browser or any IMAP client and only ever see their own mail.

Addresses are generated from `names.txt` (~195,000 names): two names are glued
together, e.g. **`mariesmith@yourdomain.tld`**. Logins are written to
`mailboxes.txt` as `email:password`, one per line.

Runs [Maddy](https://maddy.email) natively (no Docker) — around 50–200 MB RAM.

> **Receiving only.** This server collects mail; it does not send.

---

## Quick start

On a fresh server:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/beezyscriptsdreambot/oneshot-multi-mailbox.git
cd oneshot-multi-mailbox
chmod +x setup.sh create-mailboxes.sh manage-domains.sh
sudo ./setup.sh                   # installs everything
sudo ./create-mailboxes.sh 50     # creates 50 mailboxes
cat mailboxes.txt                 # email:password, one per line
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

`setup.sh` opens these in `ufw`, but that only covers the **server's own**
firewall. Most VPS providers have a **second firewall in their panel** that is
closed by default — open the ports there too.

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
```

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
6. opens the firewall (22/25/143/993, plus 80/443 with webmail)
7. optionally installs SnappyMail webmail behind nginx with a **Let's Encrypt** certificate
8. sets up daily retention, database backups and security updates
9. creates the initial batch of mailboxes, if you asked for any

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
- **appends** the login to `mailboxes.txt` as `email:password`

```
mariesmith@example.com:kP3nQx8ZmR2vLtY7bW4s
johndoe@example.com:aB9cD1eF2gH3iJ4kL5mN
```

Names are filtered to plain letters, at least 3 characters — entries like `A`,
`A-jay` or `O'brien` are skipped. That leaves ~195,000 names, so roughly
**38 billion** possible addresses; collisions are practically nonexistent but
handled anyway.

> `mailboxes.txt` is the only place the passwords exist in readable form. Maddy
> stores them hashed. Keep the file safe — it's in `.gitignore`.

---

## 5. Log in

### Browser (if webmail was installed)
**`https://mail.yourserver.tld/`** — username is the **full email address**,
password from `mailboxes.txt`.

### Mail app (IMAP)
| Setting | Value |
|--|--|
| Server | `mail.yourserver.tld` |
| Port | **993**, SSL/TLS |
| User | the full address, e.g. `mariesmith@example.com` |
| Password | from `mailboxes.txt` |
| Certificate | trusted (Let's Encrypt) if webmail was installed, otherwise self-signed |

Every user only sees their own mailbox.

---

## 6. Add or remove domains

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

## 7. Housekeeping

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

> The cleanup logs in over IMAP using the passwords in `mailboxes.txt`. If you
> change a password by hand, update that file too, or the mailbox is skipped
> (it says so in the log).

---

## 8. Useful commands

```bash
# which domains are configured?
grep local_domains /etc/maddy/maddy.conf

# which mailboxes exist?
runuser -u maddy -- maddy creds list
runuser -u maddy -- maddy creds list | wc -l

# all logins
cat mailboxes.txt

# reset one password (takes effect immediately)
runuser -u maddy -- maddy creds password --password 'NEWPASS' user@example.com

# status, logs, listening ports
systemctl status maddy
journalctl -u maddy -f
ss -tlnp '( sport = :25 or sport = :993 )'

# does everything come back after a reboot?
systemctl is-enabled maddy nginx certbot.timer maddy-cleanup.timer
```

Passwords are stored **hashed** and cannot be read back from Maddy — that's what
`mailboxes.txt` is for. If a password is lost, set a new one with the command
above (and update `mailboxes.txt`).

---

## 9. Limitations

- **Receiving only** — no sending/submission is configured.
- **Unknown addresses are rejected.** Only addresses you created exist; mail to
  anything else bounces. There is no catch-all.
- **Barely any spam filtering** — expect junk.
- **Passwords live in one file.** Anyone with `mailboxes.txt` has every mailbox.
- **Version-pinned** — `MADDY_VERSION` at the top of `setup.sh`.

---

## 10. Troubleshooting

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
the exact spelling in `mailboxes.txt`.

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

**Locked out of SSH** (`ssh` hangs) — a firewall blocks port 22, or the box is
out of memory. Use the provider's web/VNC console:
```bash
ufw allow 22/tcp && ufw reload
free -h
systemd-detect-virt     # must be 'kvm', not lxc/openvz
```

**Webmail: "Cannot assign null to property … type"**
The SnappyMail domain config is incomplete — re-run `./setup.sh`, it rewrites
`/var/www/snappymail/data/_data_/_default_/domains/default.json`.

**Start over**
```bash
systemctl stop maddy
rm -f /var/lib/maddy/*.db mailboxes.txt
sudo ./setup.sh
```

---

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | One-shot installer — mail server + optional webmail |
| `create-mailboxes.sh` | Create N mailboxes from `names.txt` |
| `manage-domains.sh` | Add/remove/list domains |
| `setup.conf.example` | Config template (copy to `setup.conf`) |
| `names.txt` | ~195,000 names used to build addresses |
| `domains.txt` | Your domains, kept in sync by the scripts |
| `mailboxes.txt` | Generated: `email:password` per line (git-ignored) |
