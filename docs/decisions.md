# Decisions

Short notes on why things are the way they are, so I do not re-litigate them every few months.

## One Compose file, no GUI edits

CasaOS came with the board and is handy for a file manager and a first look. But a stack that is edited in two places drifts, and drift is how I lost n8n's data in May 2026 (a Compose run from a different folder created a second, empty project). Since then the Compose file in Git is the only definition; CasaOS is read-only for the stack.

## Configuration in Git, data elsewhere

Text configuration is small, diffable and worth a weekly commit. Databases and media are neither. So the backup script captures config and inventory into Git and leaves databases to the applications' own backup features; a restic job to object storage for `/opt/appdata` is the next step. A backup that has never been restored is a hope, not a backup, which is why there is a dated restore drill in this folder.

## Redaction in the backup script, not in my head

I will forget to strip a key once. The script will not. Everything that looks like a secret is replaced before `git add`, key rings and logs are deleted from the snapshot, and `.gitignore` blocks the obvious file names as a second net. The public version of this repo was still audited by hand before publishing, and the history of the private one was rewritten after that audit found a key in an old log file.

## Tailscale instead of port forwarding

No inbound ports on the router, no reverse proxy exposed to the internet, no certificate renewals to babysit. Tailscale gives me the same addresses from anywhere, and the dashboard swaps its links depending on whether I am at home or not. A local reverse proxy with TLS is still on the list, for the browser warnings, not for security.

## Hardware transcoding and a codec policy

A fanless Celeron cannot transcode on the CPU in realtime. Quick Sync can, but only for H.264 and HEVC. Instead of fighting that per file, the library follows a policy: no AV1, no 10-bit H.264. `codec-scan.sh` enforces it after the fact.

## ErsatzTV for "just put something on"

A linear channel built from my own library with a weekly schedule, consumed by Jellyfin as Live TV. It removes the choice paralysis of a media library and gave me a reason to understand ffmpeg hardware pipelines properly.

## Monitoring that watches the backup

An Uptime Kuma push monitor expects a ping from the backup job every week. If the ping is missing, Kuma alerts on Discord. The failure mode I care about is silence, and this turns silence into a notification.
