# snow — self-hosted personal triage

A single-box, Docker-Compose triage system. Messages and events from your
sources are classified by a local LLM and, only when they actually need your
attention, pushed to your phone.

```
 source trigger ──▶ Ollama (local LLM, JSON out) ──▶ IF needs attention ──▶ ntfy ──▶ phone
```

Everything is local and version-controlled. Nothing leaves the box except the
final push notification (over your private Tailscale network).

---

## Stack

| Service    | Image                   | Role                                            | Host port            |
|------------|-------------------------|-------------------------------------------------|----------------------|
| `postgres` | `pgvector/pgvector:pg16`| n8n's database now; pgvector for ranking later  | **none**             |
| `ollama`   | `ollama/ollama`         | CPU-only local LLM, reached over the network    | **none**             |
| `n8n`      | `n8nio/n8n`             | automation + AI orchestration                   | `127.0.0.1:5678`     |
| `ntfy`     | `binwiederhier/ntfy`    | push notifications to your phone                | `127.0.0.1:8080`     |

**Secure by default:** `postgres` and `ollama` have no published ports at all —
they're reachable only by other containers on the internal `snow` network. `n8n`
and `ntfy` bind to `127.0.0.1`, so they're not exposed to your LAN or the
internet. You reach them through Tailscale (below). All state is in named Docker
volumes; every service is `restart: unless-stopped`.

---

## Quickstart

```bash
git clone <this-repo> snow && cd snow
./bootstrap.sh
```

`bootstrap.sh` is idempotent. It will:

1. install Docker + the Compose plugin if missing,
2. create `.env` from `.env.example` with strong random secrets **once**
   (so `N8N_ENCRYPTION_KEY` stays stable — re-runs never regenerate it),
3. `docker compose up -d`,
4. pull the Ollama model named in `.env` (`OLLAMA_MODEL`, default `gemma3:4b` —
   Google's open Gemma 3, sized for a 12GB CPU-only box).

When it finishes:

- **n8n editor:** http://127.0.0.1:5678 — first visit, create your owner account.
- **ntfy:** http://127.0.0.1:8080
- Your **ntfy topic** is printed by bootstrap and stored as `NTFY_TOPIC` in `.env`.
  That random topic *is* your access control — keep it secret.

To reach these from your laptop without opening ports, SSH-tunnel:

```bash
ssh -L 5678:127.0.0.1:5678 -L 8080:127.0.0.1:8080 you@yourbox
```

---

## Import the workflows

In the n8n editor: **⋯ menu → Import from File**, and import both:

- `workflows/slack-triage.json`
- `workflows/google-calendar-triage.json`

Each imported workflow needs its **trigger credential** set (the LLM and ntfy
steps need no credentials — they're plain HTTP calls to other containers). After
wiring credentials, open each workflow and toggle it **Active**.

### Credentials

**Slack** (`Slack Trigger` node → `slackApi` credential):

1. Create a Slack app at <https://api.slack.com/apps> → *From scratch*.
2. **OAuth & Permissions** → Bot Token Scopes: `app_mentions:read`, `im:history`,
   `chat:write`. Install to your workspace and copy the **Bot User OAuth Token**
   (`xoxb-…`) into an n8n *Slack API* credential.
3. **Event Subscriptions** → enable, set the Request URL to the webhook shown on
   the n8n `Slack Trigger` node (this needs a public URL — see *Slack* under
   Tailscale below). Subscribe to bot events: `app_mention` and `message.im`.

**Google Calendar** (`Events Starting Soon` node → `googleCalendarOAuth2Api`):

1. In Google Cloud Console create OAuth credentials (Web application). Add n8n's
   OAuth callback as an authorized redirect URI (n8n shows it on the credential).
2. Enable the Google Calendar API for the project.
3. Paste client ID/secret into an n8n *Google Calendar OAuth2 API* credential and
   complete the OAuth consent.

---

## The shared pattern (this is the whole point)

Every source is the **same five nodes**. Only the trigger and the one-line
prompt label change:

```
trigger ──▶ Ollama Triage ──▶ Parse Triage ──▶ Needs My Attention? ──▶ Push to ntfy
 (source)   HTTP→Ollama       Code (1 line)     IF                     HTTP→ntfy
```

1. **trigger** — whatever produces an item (Slack event, schedule + Calendar
   query, …).
2. **Ollama Triage** — an HTTP Request to `http://ollama:11434/api/generate`
   with `"format": "json"`, asking the model to return a fixed schema:

   ```json
   {
     "needs_response":   true,
     "action":           "Reply to Dana about the contract",
     "deadline":         "2026-06-02T17:00:00Z",
     "urgency":          "high",
     "one_line_summary": "Dana needs the signed contract before EOD."
   }
   ```

   The model name comes from `$env.OLLAMA_MODEL`, so changing the model is a
   one-line `.env` edit. Using an HTTP node (instead of a native node with a
   credential) keeps the exported JSON fully self-contained — it imports and runs
   with zero credential setup.

3. **Parse Triage** — a one-line Code node turning the model's JSON string into
   real fields: `JSON.parse($json.response)`.
4. **Needs My Attention?** — an IF node. Continues only when
   `needs_response` is true **or** `urgency` is `high`/`critical`. Everything
   else is silently dropped — that's the noise filter.
5. **Push to ntfy** — an HTTP Request POSTing JSON to `http://ntfy:80/` with your
   `$env.NTFY_TOPIC`, mapping `urgency` → ntfy priority (low=2 … critical=5).

### How to add a new source

1. **Duplicate** `workflows/slack-triage.json` → `workflows/<source>-triage.json`
   (commit it — workflows are version-controlled).
2. **Replace only the trigger** (node 1) with your source's trigger. If the
   source is poll-based rather than push-based (like Calendar), use a
   `Schedule Trigger` + a "fetch recent items" node, exactly like the Calendar
   workflow.
3. **Tweak one sentence** of the prompt in `Ollama Triage` so it names the source
   (e.g. "A new email arrived…"). Leave the JSON-schema instruction untouched.
4. Leave **Parse Triage → IF → Push to ntfy** exactly as-is. They're source-agnostic.
5. Import, set the trigger credential, activate.

That's it. The classification, filtering, and notification half is identical for
every source forever; you only ever write a trigger and one sentence.

> Tuning the filter: edit the `Needs My Attention?` IF conditions in one place
> per workflow. Want a daily digest instead of per-item pushes? Add a
> `Schedule Trigger` + an aggregation step before `Push to ntfy` — the pattern
> doesn't change.

---

## Your phone, via Tailscale

ntfy binds to `127.0.0.1` only, so nothing is exposed publicly. [Tailscale](https://tailscale.com)
puts your phone and your box on the same private network, and **Tailscale Serve**
reverse-proxies the localhost port onto your tailnet over HTTPS — no port ever
opens to the internet.

On the box:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# Expose ntfy to your tailnet only (HTTPS, private):
sudo tailscale serve --bg --https 443 http://127.0.0.1:8080
sudo tailscale serve status     # shows https://yourbox.your-tailnet.ts.net
```

Then:

1. Set `NTFY_BASE_URL=https://yourbox.your-tailnet.ts.net` in `.env` and
   `docker compose up -d` to apply.
2. Install the **ntfy** app on your phone (with the Tailscale app running).
3. In ntfy: **Default server** → your `https://…ts.net` URL, then **Subscribe**
   to your `NTFY_TOPIC`.
4. Test end-to-end:
   ```bash
   curl -d "hello from snow" https://yourbox.your-tailnet.ts.net/<NTFY_TOPIC>
   ```

### Slack needs a *public* webhook (Funnel)

Slack's servers must POST events to n8n, so that one endpoint must be reachable
from the public internet — `tailscale serve` (tailnet-only) isn't enough.
**Tailscale Funnel** exposes just the n8n webhook publicly over HTTPS while every
other service stays private:

```bash
sudo tailscale funnel --bg --https 443 http://127.0.0.1:5678
```

Set `WEBHOOK_URL=https://yourbox.your-tailnet.ts.net/` (and `N8N_HOST` to that
hostname, `N8N_PROTOCOL=https`) in `.env`, `docker compose up -d`, then use the
webhook URL n8n shows on the `Slack Trigger` node as the Slack Request URL.
Slack signs its requests and n8n verifies them, so the public endpoint only
accepts genuine Slack events. (Calendar is poll-based and needs no inbound URL.)

---

## Alternative public ingress: Cloudflare Tunnel

If you'd rather use Cloudflare than Tailscale Funnel for the public Slack
webhook (e.g. you already run `cloudflared`), the stack ships an **opt-in**
`cloudflared` service. It's outbound-only — it dials Cloudflare and never opens a
port on the box — and it's disabled by default so the normal local setup is
unaffected.

1. In the **Cloudflare Zero Trust dashboard** → *Networks → Tunnels*, create a
   tunnel and copy its **token**. Put it in `.env`:
   ```
   CLOUDFLARE_TUNNEL_TOKEN=eyJ...
   ```
2. In the tunnel's **Public Hostnames**, add a route to n8n. The service URL uses
   the internal Docker name — Cloudflared is on the same `snow` network:
   - Hostname: `snow.yourdomain.com`  →  Service: `http://n8n:5678`
   - (optional) `ntfy.yourdomain.com`  →  Service: `http://ntfy:80`
3. Point n8n at the public hostname in `.env` and bring the tunnel up:
   ```
   N8N_HOST=snow.yourdomain.com
   N8N_PROTOCOL=https
   WEBHOOK_URL=https://snow.yourdomain.com/
   ```
   ```bash
   docker compose --profile tunnel up -d
   ```
4. Use the webhook URL n8n shows on the `Slack Trigger` node as the Slack Event
   Subscriptions Request URL.

The `cloudflared` container only starts when you pass `--profile tunnel`; a plain
`docker compose up -d` (and `bootstrap.sh`) leaves it off. To stop just the
tunnel: `docker compose --profile tunnel stop cloudflared`. If you expose ntfy
this way too, set `NTFY_BASE_URL` to its public hostname.

> Tailscale vs Cloudflare: Tailscale `serve` keeps ntfy **private** to your
> devices (best for personal push); Cloudflare Tunnel makes a hostname
> **public** (needed for Slack's inbound webhook). Pick per service — they
> coexist fine.

---

## Backups

All durable state is in named volumes: `postgres_data` (n8n's data — workflows,
credentials, executions), plus `ollama_data`, `n8n_data`, `ntfy_data`.

The credentials are encrypted with `N8N_ENCRYPTION_KEY`, so **back up `.env`
together with the database** — one is useless without the other.

Logical Postgres backup (recommended — small, restorable):

```bash
# dump
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
  | gzip > backup-$(date +%F).sql.gz

# restore
gunzip -c backup-YYYY-MM-DD.sql.gz \
  | docker compose exec -T postgres psql -U "$POSTGRES_USER" "$POSTGRES_DB"
```

Also keep a copy of `.env` somewhere safe (a password manager). Your workflows
are already in git, so they don't need backing up separately.

To restore on a new box: copy the repo and `.env`, run `./bootstrap.sh`, then
restore the Postgres dump.

---

## Operations

```bash
docker compose ps                 # status
docker compose logs -f n8n        # follow a service's logs
docker compose pull && docker compose up -d   # update images
docker compose down               # stop (volumes/state preserved)
docker compose exec ollama ollama list        # models on disk
```

Changing the model: edit `OLLAMA_MODEL` in `.env`, then
`docker compose exec ollama ollama pull <model>` and `docker compose up -d`.

---

## What's next (designed-for, not yet built)

`pgvector` is already in the database image. The intended next step is to embed
incoming items and store them, so the triage step can rank by similarity to
things you've historically cared about — a smarter `Needs My Attention?` than the
current rule. The shared pattern doesn't change: it slots in between
*Parse Triage* and the IF.
