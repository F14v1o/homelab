# homelab

Configuration and runbooks for my home server: a fanless ZimaBlade (Intel Celeron, 16 GB RAM, two 4 TB disks) running Debian and Docker. It serves media to the living-room TV, runs a linear "live TV" channel built from that library, hosts n8n for personal automations, and monitors itself. Everything is defined in one Compose file; the file in Git is the source of truth, nothing is edited through a GUI.

This repository is the public, cleaned-up version of the private ops repo that the server backs itself up into every week. The structure, scripts and lessons are the real ones.

## What runs

```
                 LAN / Tailscale
                        |
             +----------+-----------+
             |   Debian + Docker    |
             |                      |
   :3000     |  homepage  ----------+--> status widgets for every service
   :8096     |  jellyfin  --/dev/dri (Intel Quick Sync, HW transcoding)
   :8409     |  ersatztv  --reads the Jellyfin library, builds a 24/7 channel
   :5678     |  n8n       --personal automations, workflows exported to Git
   :3001     |  uptime-kuma --HTTP checks + push monitor for the backup job
             |                      |
             +----------+-----------+
                        |
        /mnt/storage1 (archive)   /mnt/storage2 (everything new)
```

| Service | Image | Purpose |
|---|---|---|
| Jellyfin | `linuxserver/jellyfin` | Media server with VAAPI/Quick Sync transcoding via `/dev/dri` |
| ErsatzTV | `ghcr.io/ersatztv/legacy` | Linear TV channel with a weekly schedule, consumed by Jellyfin as a Live TV source |
| Homepage | `ghcr.io/gethomepage/homepage` | One dashboard with Docker health, Jellyfin sessions and Kuma status; links switch between LAN and Tailscale |
| n8n | `n8nio/n8n` | Self-hosted automation; workflows are exported to Git on every backup run |
| Uptime Kuma | `louislam/uptime-kuma` | Monitoring with Discord alerts; a push monitor fires if the weekly backup misses its window |

Remote access is Tailscale only. No port is forwarded on the router.

## Repository layout

```
compose/docker-compose.yml   the stack (paths and IDs come from compose/.env)
compose/.env.example         copy to .env and fill in
scripts/config-backup.sh     weekly configuration snapshot into a Git repo, with secret redaction
scripts/codec-scan.sh        lists codec and pixel format of every media file (via ffprobe in the Jellyfin container)
systemd/                     service + timer for the backup script
docs/server.md               hardware, codec matrix, storage layout, operating rules
docs/restore-drill-2026-09-09.md   what a restore from Git alone gives you, and what it does not
docs/decisions.md            why things are the way they are
```

## Bring it up

```bash
git clone https://github.com/F14v1o/homelab ~/homelab
cd ~/homelab/compose
cp .env.example .env            # set APPDATA, MEDIA1, MEDIA2, PUID/PGID, TZ, allowed hosts
sudo docker compose up -d jellyfin ersatztv homepage n8n uptime-kuma
```

Rules I follow after learning them the hard way (details in `docs/server.md`):

- Always run Compose from this folder; a different folder is a different project and creates new, empty containers.
- Name the service on `up -d`. A bare `up -d` reconciles every container against the file.
- Only absolute paths in volumes. `~` and `./` resolve differently under `sudo`.

## Backups

`scripts/config-backup.sh` runs every Sunday at 03:00 via systemd timer. It collects the Compose file, the text configuration of every container that mounts `/config`, the n8n workflows, dotfiles and a system inventory (fstab, packages, enabled units, container topology), redacts API keys and tokens, drops data-protection key rings and logs, commits as the admin user and pushes. A successful push pings an Uptime Kuma push monitor, so a missed run shows up as an alert rather than silence.

What the backup does **not** contain, on purpose: media, SQLite databases, the n8n encryption key, anything that looks like a secret. A restore from Git gives you a running but empty stack within a minute; the drill that proved this, and the five problems it found, are in `docs/restore-drill-2026-09-09.md`.

Install the timer:

```bash
sudo GIT_USER=<admin user> REPO=/home/<admin user>/homelab ./scripts/config-backup.sh install
sudo systemctl start config-backup.service     # run once now
journalctl -u config-backup -n 40 --no-pager
```
