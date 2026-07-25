# Nocturne — the webmail theme

Dark, calm, compact. The accent is a line, not a surface.

`setup.sh` installs this folder into SnappyMail as a theme called **Nocturne**
and makes it the active one. Edit anything here, re-run `sudo ./setup.sh`, then
hard-reload the browser (Ctrl+Shift+R, Cmd+Shift+R on a Mac).

```
webmail-theme/
├── styles.css   the theme
├── fonts/       Inter, bundled locally
├── images/      optional assets
└── Login.html   reference copy of the form (not deployed)
```

---

## The palette

| | |
|--|--|
| Page | `#161826` with a soft radial lift towards the top |
| Card | `#232532`, 8px radius, hairline `#3f424d` |
| Fields | `#1b1d2b` on `#3f424d` |
| Accent | `#79c2a4` — mint, used for the line, focus ring, checkbox and button |
| Text | `#e9e9ed`, muted `#9397ab` |

Two mint glows drift slowly behind the card on a 22s and a 17s loop. They hold
still for anyone with "reduce motion" enabled.

## Editing it

`styles.css` has two halves:

1. **The variable block** (`:root`) — colours the entire app, login screen and
   mailbox alike. Change a value here and everything follows.
2. **The login rules below it** — a handful of details that variables cannot
   express: the glows, the accent line, the card width, the checkbox row.

Delete any variable you don't want; it falls back to SnappyMail's default.

### Fonts

Inter is bundled in `fonts/` as a variable woff2 — **not** loaded from Google's
CDN. A login page that phones home to a third party on every visit defeats the
point of running your own mail server. Two files, 132 KB total, and the
`latin-ext` one only downloads for languages that need it.

To swap the typeface, replace the `@font-face` blocks and the `--font` variable.
Keep it local.

### The heading

The text above the form comes from `WEBMAIL_LOGIN_TEXT` in `../setup.conf`, not
from this folder. The theme draws its accent line above that element, so if you
blank the text you lose the line too.

```bash
WEBMAIL_TITLE="Example Mail"      # browser tab
WEBMAIL_LOGIN_TEXT="Sign in"      # the heading
```

The design also had a subtitle under the heading. SnappyMail's login has only
one text element, so that line is not carried over — putting it back would mean
editing `Login.html`, which a SnappyMail update would overwrite.

## What survives an update

Themes live in SnappyMail's version directory
(`snappymail/v/2.38.2/themes/`), which a SnappyMail update replaces wholesale.
`setup.sh` re-copies this folder on **every** run, so re-running it after an
update puts the theme back. That is the whole reason the source of truth lives
here in the repo rather than on the server.

## Editing `Login.html`

The copy here is for reference — it is **not** deployed, and editing it changes
nothing. It shows which hooks exist:

| Selector | What it is |
|--|--|
| `.descWrapper` | the heading |
| `.alert` | the failed-login box |
| `form` | the card |
| `.controls` | one field row |
| `.e-checkbox` | "Keep me signed in" |
| `.buttonLogin` | the sign-in button |
| `#plugin-Login-BottomControlGroup` | empty slot you can style into |

If you ever do edit the real template on the server, keep every `data-bind`
attribute: they are the form's logic, not styling hooks. Remove one and login
stops working silently.

## Trying changes quickly

Re-running the setup for each colour tweak is slow. Open the webmail, edit the
variables live in the browser's dev tools (Elements → `:root`), and write only
the values you settled on back into `styles.css`.

## Going back to stock

```bash
sudo rm -rf /var/www/snappymail/snappymail/v/*/themes/Nocturne
sudo ./setup.sh
```

Then pick a built-in theme in the webmail's settings. Mailboxes, mail and
settings are untouched — this is cosmetic only.
