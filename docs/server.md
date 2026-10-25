# Server reference

Single source of truth for the box. Updated when something changes, backed up with everything else.

## Hardware

| | |
|---|---|
| Board | ZimaBlade, Intel Celeron (Apollo Lake), 16 GB RAM, fanless |
| GPU | Intel Quick Sync via `/dev/dri/renderD128` (groups `render` and `video`) |
| HW decode (vainfo, iHD) | H.264, HEVC 8-bit, HEVC 10-bit, VP9, VP8, MPEG-2 |
| HW encode | H.264, HEVC 8-bit. **No AV1, no H.264 10-bit (Hi10P)** |
| Low-power encoder | listed by the driver but does not work (missing GuC firmware); keep it off in Jellyfin |
| Disks | two 4 TB SATA, `/mnt/storage1` (archive, no new writes) and `/mnt/storage2` (everything new) |
| OS | Debian 11 with CasaOS as an admin backend only; the stack itself is managed with Compose |

Anything that draws into the picture (watermark, overlay, burned-in subtitles) forces `hwdownload -> CPU filter -> hwupload`: one core at 100 %, no realtime playback. Avoid it on this chip.

The TV plays H.264 8-bit and HEVC 8/10-bit directly. AV1 and Hi10P play neither on the TV nor in hardware on the server, so they would be CPU-transcoded. That is why `scripts/codec-scan.sh` exists: a few times a year the library is scanned and anything AV1 or Hi10P is replaced.

## Storage model

- Media folders belong to the admin user; containers run as one service user (`PUID/PGID` from `.env`).
- Config of every container lives under `${APPDATA}/<service>` on the system disk, never on the media disks.
- `storage1` is full-ish and frozen. Everything new goes to `storage2`.
- A cleanup in September 2026 removed 369 broken files (sparse leftovers of aborted transfers: 434 GB apparent, 42 GB real; `moov atom not found`) and all AV1/Hi10P material. The codec scan is what found them.

## Operating rules

1. Run Compose only from the repo's `compose/` folder, with `sudo`. A different folder is a different Compose project and creates new empty containers. That is how n8n lost its data once.
2. Name the service: `sudo docker compose up -d <service>`. A bare `up -d` reconciles every container against the file.
3. Absolute paths only in volumes. `~` and `./` resolve differently under `sudo`.
4. Never press Save in the CasaOS compose dialog; it overwrites the Git-managed file.
5. Change the Compose file -> `git commit`, `git pull --rebase`, `git push`. The server's clone is what the backup job commits into, so it must stay fast-forwardable.
6. After `docker compose stop <service>` continue with `start`, not `up -d`. Then check with `docker ps --filter name=<service>`; Compose once reported a container as running that was not.
7. `.env` changes need `up -d --force-recreate <service>`; Homepage's YAML is read live.

## Backup pipeline

| | |
|---|---|
| Script | `scripts/config-backup.sh`, runs as root, commits and pushes as the admin user with its SSH deploy key |
| Timer | `config-backup.timer`, Sunday 03:00 plus up to 15 min random delay, `Persistent=true` |
| Log | `journalctl -u config-backup`, `/var/log/config-backup.log` |
| Captures | Compose + `.env`, CasaOS app composes, text configs from every `/config` mount (xml/json/conf/ini/yml; no logs, definitions, caches, backup archives), n8n workflow export, dotfiles, fstab/hosts/smb/daemon.json, package list, enabled units and timers, interfaces and routes, container topology |
| Redacts | `<ApiKey>` in XML, `PASSWORD|TOKEN|SECRET|API_KEY=` in env files, `"apiKey": "..."`-style values in JSON/YAML; deletes `key-*.xml` key rings and any `logs/` directory |
| Does not capture | media, SQLite databases, the n8n encryption key and credentials, anything in `.gitignore` |
| Success signal | push to Uptime Kuma push monitor after a successful `git push`; the monitor alerts on Discord if no ping arrives within the window |

Restore path: clone the repo -> read `snapshot/system/container-topology.txt` -> bring the stack up from `snapshot/compose/` -> copy app configs back from `snapshot/apps/` -> regenerate API keys -> re-create `homepage/.env` with the new keys. What that leaves you with is documented in `restore-drill-2026-09-09.md`.

## Monitoring

Uptime Kuma checks every service over HTTP and has one push monitor for the backup job. Alerts go to a Discord channel. The dashboard (Homepage) shows Docker container health, Jellyfin sessions and Kuma status on one page; its links switch between LAN and Tailscale addresses depending on where it is opened from.
