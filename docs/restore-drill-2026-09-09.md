# Restore drill, 2026-09-09

**Question:** if the server died tonight, what would the Git backup alone give me back?

**Setup:** fresh clone of the ops repo on my Arch desktop, Docker installed, nothing else. Brought the stack up from the committed Compose file and the last snapshot.

**Result:** all five containers start from the repo in about one minute. All of them are empty.

## What Git gives me

- the Compose file and the environment layout
- application settings in text form (XML/JSON from every `/config` mount)
- fstab, package list, enabled systemd units, container topology, network layout

## What Git does not give me

- application databases: Jellyfin library and users, n8n workflows and credentials, Kuma monitors, ErsatzTV schedule
- the media disks
- logins and tokens: Tailscale, the n8n encryption key, widget API keys

That is by design for the secrets and the media. For the databases it is a gap: a restore gets me a running stack and a long evening of re-configuring.

## Problems found

1. **Relative mounts resolve differently under `sudo`.** `~/appdata/...` in the Compose file pointed to `/root/appdata` when run as root and to my user's home when not. Two sets of containers, two sets of data. Fix: absolute paths only (`APPDATA=/opt/appdata` in `.env`).
2. **n8n had no volume.** Its data lived in an anonymous Docker volume, which a `docker compose up --force-recreate` silently replaces. Fix: explicit bind mount `${APPDATA}/n8n:/home/node/.n8n`.
3. **Data-protection key rings were in Git.** The `key-*.xml` files under some `/config` directories hold the master key that encrypts stored credentials. The backup script now deletes them from the snapshot and `.gitignore` blocks them.
4. **Mixed UIDs.** Jellyfin ran as 911, everything else as 1000, so permissions on shared media folders had to be opened up more than I like. Fix: one service user for all containers, `PUID/PGID` from `.env`.
5. **Every port bound on 0.0.0.0.** Fine behind a NAT with no port forwarding, but not deliberate. Remote access stays Tailscale only; a reverse proxy with TLS is on the list.

## Follow-ups

- [x] absolute paths and a single UID in the Compose file
- [x] key rings, secret stores and logs excluded from the backup (script and `.gitignore`)
- [x] first unattended timer run confirmed (Sun 13 Sep)
- [ ] restic backup of `/opt/appdata` databases to object storage, with its own restore test
- [ ] reverse proxy with TLS in front of the dashboard and Jellyfin
