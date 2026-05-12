# EC2 Deployment Guide — Meridian Wealth Analyst Agent

End-to-end guide for deploying the Meridian Wealth Financial Analyst Agent
(FastAPI + LangGraph + FAISS + Tavily) on a fresh AWS EC2 Ubuntu 24.04
instance.

After SSHing into the instance, you have two paths to choose between:

- **Path A (automated)** — run `deployment/ec2/setup.sh`, which installs
  and enables the systemd unit and nginx site.
- **Path B (manual)** — do everything `setup.sh` does, by hand.

Both paths share the same one-time bootstrap (apt, clone, venv, deps, env).

---

## Prerequisites

### 1. AWS EC2 Instance

| | |
|---|---|
| OS              | Ubuntu Server 24.04 LTS |
| Instance type   | `t3.small` or larger (2 vCPU / 2 GiB minimum; 4 GiB recommended) |
| Storage         | 20 GB EBS |
| Security Group  | Inbound: `22` (SSH from your IP), `80` (HTTP from `0.0.0.0/0`), `443` (HTTPS from `0.0.0.0/0`) |

> The AWS **Security Group** and the on-host **UFW** firewall are *two
> different layers*. Both must allow the port. UFW is configured below;
> the Security Group must be set in the AWS Console.

### 2. API keys

- **OPENAI_API_KEY** — required (LLM + embeddings). Get one at
  https://platform.openai.com/api-keys.
- **TAVILY_API_KEY** — required (live web search). Get one at
  https://app.tavily.com.

### 3. Domain name (optional, for HTTPS)

Required only if you want HTTPS via Let's Encrypt. Add an `A` record at
your DNS provider pointing to the EC2 public IP **before** running
certbot — the HTTP-01 challenge needs to reach the box.

---

## Step 0 — SSH into the instance

On your local machine:

```bash
# Lock down the keypair (one-time)
chmod 400 meridian-wealth-keypair.pem        # macOS/Linux
# Windows PowerShell:
#   icacls .\meridian-wealth-keypair.pem /inheritance:r /grant:r "$($env:USERNAME):(R)"

# Connect
ssh -i meridian-wealth-keypair.pem ubuntu@<EC2_PUBLIC_DNS_OR_IP>
```

Everything below runs **on the EC2 instance** unless stated otherwise.

---

## Step 1 — Update the system

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get \
  -o Dpkg::Options::='--force-confdef' \
  -o Dpkg::Options::='--force-confold' \
  upgrade -y
```

## Step 2 — Install OS packages

Python tooling, build deps, git, nginx, certbot, curl:

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip python3-dev \
  git build-essential curl \
  nginx certbot python3-certbot-nginx
```

Verify:

```bash
python3 --version    # Python 3.12.x
nginx -v             # nginx/1.24.x
certbot --version    # certbot 2.9.x
```

## Step 3 — Clone the repository

```bash
cd ~
git clone https://github.com/prashant9501/meridian-wealth-deployment.git
cd meridian-wealth-deployment
```

> The repo is public; no GitHub auth needed. If you later make it
> private, clone over SSH and add your EC2 host's public key as a
> deploy key in GitHub.

## Step 4 — Python venv + dependencies

```bash
cd ~/meridian-wealth-deployment
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

This installs FastAPI, uvicorn, langchain, langgraph, faiss-cpu,
openai, tavily-python, etc. Takes 2–5 minutes on a small instance.

## Step 5 — Create the `.env` file

From your **local** machine, SCP your local `.env` to the EC2:

```bash
# Run this on your LOCAL machine
scp -i meridian-wealth-keypair.pem .env \
    ubuntu@<EC2_PUBLIC_DNS_OR_IP>:~/meridian-wealth-deployment/.env
```

Or, on the EC2, copy the template and edit:

```bash
cp .env.example .env
nano .env
```

Required values:

```bash
OPENAI_API_KEY=sk-...
TAVILY_API_KEY=tvly-...
AGENT_MODEL=gpt-5-mini
EMBEDDING_MODEL=text-embedding-3-small
API_HOST=0.0.0.0          # ignored by systemd (we bind 127.0.0.1 there)
API_PORT=8000
LOG_LEVEL=info
```

## Step 6 — Grant nginx permission to traverse the home directory

Ubuntu 24.04 sets `/home/ubuntu` to mode `750` by default, which means
nginx (running as `www-data`) can't traverse into it to read static
files. Grant traverse only (no read):

```bash
sudo chmod o+x /home/ubuntu
```

This is the **minimal** fix: others gain traverse only, so nginx can
follow paths into the home directory but cannot `ls` it.

---

## Step 7A — Automated install with `setup.sh`

If you went the automated route:

```bash
cd ~/meridian-wealth-deployment
sudo bash deployment/ec2/setup.sh
```

The script installs the systemd unit and nginx site, enables the site,
removes the default site, runs `nginx -t`, and reloads nginx.

Skip to **Step 8**.

---

## Step 7B — Manual install (what `setup.sh` does)

If you'd rather do it by hand, run each block:

### 7B.1 — systemd unit

```bash
# Copy the unit file into systemd's directory
sudo install -m 0644 \
  ~/meridian-wealth-deployment/deployment/ec2/systemd/meridian-wealth.service \
  /etc/systemd/system/meridian-wealth.service

# Let systemd pick up the new unit
sudo systemctl daemon-reload

# Enable on boot
sudo systemctl enable meridian-wealth.service
```

### 7B.2 — nginx site

```bash
# Copy the site config into sites-available
sudo install -m 0644 \
  ~/meridian-wealth-deployment/deployment/ec2/nginx/sites-available/meridian-wealth \
  /etc/nginx/sites-available/meridian-wealth

# Enable the site (symlink into sites-enabled)
sudo ln -sf /etc/nginx/sites-available/meridian-wealth \
            /etc/nginx/sites-enabled/meridian-wealth

# Disable the default site
sudo rm -f /etc/nginx/sites-enabled/default
```

### 7B.3 — Test and reload nginx

```bash
sudo nginx -t                 # must report "syntax is ok"
sudo systemctl reload nginx
```

---

## Step 8 — Start the service

```bash
sudo systemctl start meridian-wealth

# Wait a few seconds; first start builds the FAISS index from the
# policy PDFs (~30–60s) if the vectorstore/ dir is empty.
sleep 15

systemctl is-active meridian-wealth          # → active
sudo systemctl status meridian-wealth        # show details
```

If the service is `active (running)` you're good. Otherwise see
**Troubleshooting** at the bottom.

---

## Step 9 — Configure the UFW firewall

Allow only SSH, HTTP, HTTPS:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'      # opens 80 AND 443
sudo ufw --force enable          # --force skips the interactive y/n
sudo ufw status verbose
```

Expected:

```
Status: active
22/tcp (OpenSSH)           ALLOW IN  Anywhere
80,443/tcp (Nginx Full)    ALLOW IN  Anywhere
```

## Step 10 — Smoke test over HTTP

From the EC2 (`localhost` = nginx; `127.0.0.1:8000` = direct app):

```bash
curl -s http://127.0.0.1:8000/health        # direct
curl -s http://localhost/health             # via nginx
curl -sI http://localhost/static/styles.css # static asset
```

All three should return `HTTP/1.1 200`. From your browser:

- http://&lt;EC2_IP&gt;/ — the chat UI
- http://&lt;EC2_IP&gt;/docs — Swagger
- http://&lt;EC2_IP&gt;/agent/info — agent metadata

---

## Step 11 — HTTPS via Let's Encrypt (optional)

Skip this section if you don't have a domain.

### 11.1 — Point DNS at the EC2

Add an `A` record at your DNS provider:

```
yourdomain.com.  IN  A  <EC2_PUBLIC_IP>
```

Verify propagation from your local machine:

```bash
nslookup yourdomain.com        # should return the EC2 IP
```

### 11.2 — Update nginx with your domain

Edit `/etc/nginx/sites-available/meridian-wealth` and change:

```nginx
server_name _;
```

to:

```nginx
server_name yourdomain.com www.yourdomain.com;
```

Then:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

### 11.3 — Run certbot

```bash
sudo certbot --nginx \
  -d yourdomain.com \
  -d www.yourdomain.com \
  --non-interactive \
  --agree-tos \
  -m you@yourdomain.com \
  --redirect
```

`--redirect` tells certbot to add a 301 from HTTP → HTTPS to the nginx
config automatically. Certbot writes new `listen 443 ssl;` blocks into
the same site file and reloads nginx.

### 11.4 — Verify HTTPS is live

```bash
curl -sI https://yourdomain.com/health      # should be 200
curl -sI http://yourdomain.com/health       # should be 301 → https://
```

In a browser, the padlock should appear.

### 11.5 — Confirm auto-renewal

Certbot on Ubuntu 24.04 (apt-installed) ships a systemd timer:

```bash
systemctl list-timers --all | grep certbot
#   NEXT      LEFT  LAST  PASSED  UNIT                ACTIVATES
#   ...       ...   ...   ...     certbot.timer       certbot.service
systemctl status certbot.timer

# Dry-run renewal end-to-end (no certs are actually replaced)
sudo certbot renew --dry-run
```

Certbot renews any cert with <30 days left. The timer fires twice
daily by default.

---

## Step 12 — Final restart

After SSL is in place (or if you changed anything else):

```bash
sudo systemctl restart meridian-wealth
sudo systemctl status meridian-wealth
```

Visit **https://yourdomain.com/** and you should see the chat UI over
HTTPS.

---

## Service management cheatsheet

```bash
# Status / logs
systemctl status meridian-wealth
sudo journalctl -u meridian-wealth -n 100 --no-pager
sudo journalctl -u meridian-wealth -f          # tail follow

# Lifecycle
sudo systemctl start meridian-wealth
sudo systemctl stop meridian-wealth
sudo systemctl restart meridian-wealth
sudo systemctl enable meridian-wealth          # auto-start on boot
sudo systemctl disable meridian-wealth

# nginx
sudo nginx -t
sudo systemctl reload nginx
sudo tail -f /var/log/nginx/meridian-wealth.access.log
sudo tail -f /var/log/nginx/meridian-wealth.error.log
```

---

## Updating after a code change

```bash
cd ~/meridian-wealth-deployment
git pull origin main

# Only if requirements.txt changed:
source venv/bin/activate
pip install -r requirements.txt

# Re-apply systemd / nginx changes if the files in deployment/ec2/
# were updated:
sudo bash deployment/ec2/setup.sh

# Restart the app
sudo systemctl restart meridian-wealth
```

---

## Troubleshooting

### Service won't start

```bash
sudo journalctl -u meridian-wealth -n 200 --no-pager
```

Common causes:

| Symptom | Fix |
|---|---|
| `Missing required env vars: OPENAI_API_KEY` | `.env` is missing or incomplete |
| `Address already in use` on 8000 | `sudo lsof -i :8000` then `kill -9 <PID>` |
| `ImportError` for langchain/faiss | Reinstall: `source venv/bin/activate && pip install -r requirements.txt` |
| Stuck on FAISS build | Check OpenAI key is valid + has credits |

### Static files return 404 from nginx

`/home/ubuntu` permissions:

```bash
sudo chmod o+x /home/ubuntu
ls -ld /home/ubuntu          # should be drwxr-x--x
```

### nginx config rejected

```bash
sudo nginx -t                # always read the line number it points at
```

### Permission errors on the project dir

```bash
sudo chown -R ubuntu:ubuntu /home/ubuntu/meridian-wealth-deployment
```

### Certbot fails the HTTP-01 challenge

- DNS not propagated yet — wait and re-run.
- AWS Security Group blocking port 80 — open `80` to `0.0.0.0/0`.
- nginx not serving on port 80 — check `sudo systemctl status nginx`.

### Reset everything

```bash
sudo systemctl stop meridian-wealth
sudo systemctl disable meridian-wealth
sudo rm -f /etc/systemd/system/meridian-wealth.service
sudo rm -f /etc/nginx/sites-enabled/meridian-wealth
sudo rm -f /etc/nginx/sites-available/meridian-wealth
sudo systemctl daemon-reload
sudo systemctl reload nginx
# Then start over from Step 7.
```

---

## Security checklist

- [ ] AWS Security Group: SSH locked to **your IP** (not `0.0.0.0/0`)
- [ ] `.env` not committed to git (covered by `.gitignore`)
- [ ] UFW active with default-deny inbound
- [ ] HTTPS enabled and HTTP redirected to HTTPS
- [ ] Certbot auto-renewal verified with `certbot renew --dry-run`
- [ ] EC2 instance kept patched (`sudo apt update && sudo apt upgrade`)

---

## File reference

| File on the EC2 | Source in the repo |
|---|---|
| `/etc/systemd/system/meridian-wealth.service` | `deployment/ec2/systemd/meridian-wealth.service` |
| `/etc/nginx/sites-available/meridian-wealth`  | `deployment/ec2/nginx/sites-available/meridian-wealth` |
| `/etc/nginx/sites-enabled/meridian-wealth`    | symlink to the above |
| `/home/ubuntu/meridian-wealth-deployment/`    | `git clone` of this repo |
| `/home/ubuntu/meridian-wealth-deployment/.env` | `scp` from your local `.env` |
