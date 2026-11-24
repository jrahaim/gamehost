# gamehost

One Docker container that serves static web game builds (Godot web exports first, any static bundle in practice)
on automatic subdomains: `mygame.games.example.com` goes live on its first deploy, with no per-game DNS or proxy work.
You deploy by uploading a zip and a manifest to an HTTP API, from GitHub Actions or with `curl`.

- One container, one volume (`/data`), no database.
- One manifest per game repo: [`gamehost.toml`](docs/manifest.md).
- Atomic deploys, instant rollback, optional branch previews.
- Correct Godot serving: `application/wasm`, precompressed Brotli and gzip, optional cross-origin isolation, and
  stable ETags so returning players get `304` for unchanged files.

Inside the container, Caddy terminates TLS and serves files, and a small Swift (Vapor) API on `127.0.0.1:8080` takes
uploads, manages releases and writes one Caddy config snippet per site.

```
                    ┌──────────────────────── container ────────────────────────┐
 player  ──443──▶   │ Caddy ── file_server ──▶ /data/sites/{key}/current/files/ │
 CI/curl ──443──▶   │ Caddy ── reverse_proxy ─▶ Deploy API (127.0.0.1:8080)     │
                    │                              │ writes releases + snippets │
                    │                              └─ caddy reload (admin :2019)│
                    └────────────────────────── /data volume ───────────────────┘
```

## 1. DNS

Once, point a wildcard record at the host:

```
*.games.example.com.   A     203.0.113.10
*.games.example.com.   AAAA  2001:db8::10      (if you have IPv6)
```

This also covers the API hostname (`deploy.games.example.com` by default).

## 2. Run it

```sh
export GAMEHOST_ADMIN_TOKEN=$(openssl rand -base64 36)   # keep this somewhere safe
# edit compose.yml: GAMEHOST_BASE_DOMAIN and GAMEHOST_ACME_EMAIL
docker compose up -d --build
curl https://deploy.games.example.com/healthz             # {"ok":true}
```

Caddy obtains a certificate per hostname from Let's Encrypt the first time it is needed. Let's Encrypt limits
certificates per registered domain per week (50 at the time of writing; check the current limit). That is plenty for
games, but heavy preview use is the reason a wildcard mode is planned.

### Behind an existing reverse proxy

If something else already owns ports 80/443, set `GAMEHOST_TLS_MODE=external` and publish `127.0.0.1:8081:8081`
instead ([`examples/compose.external.yml`](examples/compose.external.yml) is a ready stack using the published image).
Caddy then serves plain HTTP on 8081 and your proxy must forward `*.games.example.com` there with the `Host` header
preserved. Set `GAMEHOST_TRUSTED_PROXIES` to the proxy's address so per-IP auth rate limiting sees real client IPs.
The API reports game URLs as `https://{name}.{BASE_DOMAIN}/`, which is what players reach through the proxy; change
that with `GAMEHOST_PUBLIC_SCHEME` / `GAMEHOST_PUBLIC_PORT`. First deploys of a large engine `.wasm` spend a minute or
more compressing, so give the proxy a generous upstream timeout (for example 10 minutes).

### Prebuilt image

`.github/workflows/image.yml` publishes `ghcr.io/<owner>/gamehost:latest` on every push to `main` (plus `:sha-…`
and version tags). Use `image: ghcr.io/<owner>/gamehost:latest` instead of `build: .` to skip building on the server.
If the package is private, log the server in to ghcr.io (or add the registry in Portainer) with a token that has
`read:packages`.

## 3. Configuration

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `GAMEHOST_BASE_DOMAIN` | yes | — | e.g. `games.example.com`. Sites live at `{name}.` this. |
| `GAMEHOST_API_HOST` | no | `deploy.{BASE_DOMAIN}` | Hostname the API answers on. Its first label becomes a reserved site name. |
| `GAMEHOST_ADMIN_TOKEN` | yes | — | Bearer token for admin endpoints. Refuses to start if shorter than 32 characters. |
| `GAMEHOST_TLS_MODE` | no | `per-site` | `per-site` or `external`. (`wildcard` is not implemented yet.) |
| `GAMEHOST_ACME_EMAIL` | per-site | — | Contact address for Let's Encrypt. |
| `GAMEHOST_MAX_UPLOAD_MB` | no | `512` | Max zip size, enforced by Caddy and by the API while streaming. |
| `GAMEHOST_MAX_UNPACKED_MB` | no | `2048` | Max total unpacked size, counted from bytes actually written. |
| `GAMEHOST_MAX_FILES` | no | `20000` | Max entries per zip. |
| `GAMEHOST_PREVIEW_TTL_DAYS` | no | `14` | Previews whose last deploy is older than this are deleted (checked daily). |
| `GAMEHOST_TRUSTED_PROXIES` | no | — | Space/comma separated IPs or CIDRs of proxies in front of Caddy. |
| `GAMEHOST_PUBLIC_SCHEME` | no | `https` | Scheme of the game URLs the API reports. Set `http` only in `external` mode when nothing in front terminates TLS. |
| `GAMEHOST_PUBLIC_PORT` | no | — | Port of the game URLs the API reports, if players don't use the scheme's default port. |

Ports and paths inside the container (`GAMEHOST_DATA_DIR`, `GAMEHOST_EXTERNAL_PORT`, `GAMEHOST_API_LISTEN_PORT`,
`GAMEHOST_CADDY_ADMIN`, `GAMEHOST_CADDY_BIN`) can be overridden for local development but should be left alone in
the image. The API and the Caddy admin API only ever listen on loopback.

## 4. First site

```sh
API=https://deploy.games.example.com
ADMIN="Authorization: Bearer $GAMEHOST_ADMIN_TOKEN"

# Create the site (admin only). The deploy token is shown once.
curl -sS -X POST "$API/api/sites" -H "$ADMIN" -H 'Content-Type: application/json' -d '{"name":"mygame"}'
# {"name":"mygame","token":"gh_…","url":"https://mygame.games.example.com/"}

# In the game repo, with gamehost.toml at the root (see examples/gamehost.toml):
cd build/web && zip -qr ../../bundle.zip . && cd ../..
curl -sS --fail-with-body -X POST "$API/api/deploy" \
  -H "Authorization: Bearer $GAMEHOST_TOKEN" \
  -F "manifest=@gamehost.toml" \
  -F "bundle=@bundle.zip"
```

A site must be created by an admin before its first deploy. That stops a leaked token for one repo from claiming
new subdomains, and bounds certificate issuance.

For CI, copy [`examples/deploy.yml`](examples/deploy.yml) to `.github/workflows/deploy.yml` and add the repository
secrets `GAMEHOST_URL` and `GAMEHOST_TOKEN`. Pushes to `main` deploy production; pull requests deploy previews.

## 5. API

Base URL `https://{GAMEHOST_API_HOST}`. JSON everywhere. Every endpoint except `/healthz` needs
`Authorization: Bearer <token>`. Errors look like
`{"error": {"code": "manifest_invalid", "message": "…", "details": […]}}`.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/healthz` | none | `{"ok":true}` |
| POST | `/api/sites` | admin | Create a site: `{"name":"mygame"}`. Returns the deploy token once. 409 if it exists. |
| GET | `/api/sites` | admin | Sites with URL, current release, size and preview labels. |
| GET | `/api/sites/{name}` | admin or site | Detail: releases (newest first) and previews. |
| DELETE | `/api/sites/{name}` | admin | Remove the site, its releases, previews, snippets and token. |
| POST | `/api/sites/{name}/token` | admin | Rotate the deploy token; the old one stops working immediately. |
| POST | `/api/deploy` | admin or site | Deploy (multipart, below). |
| POST | `/api/sites/{name}/rollback` | admin or site | `{"release":"<id>"}`, or an empty body for the previous release. |
| DELETE | `/api/sites/{name}/previews/{label}` | admin or site | Remove one preview. |

A site token can deploy, roll back and read its own site and that site's previews, and nothing else (403).
Ten failed authentications from one IP within a minute block that IP for the rest of the minute (429).

`POST /api/deploy` takes `multipart/form-data` parts: `manifest` (the repo's `gamehost.toml`), `bundle` (zip of the
contents of `dir`), and optionally `preview` (label), `commit` and `ref` (stored as metadata). The bundle is
streamed to disk, never held in memory. Success is `201`:

```json
{"site":"mygame","preview":null,"url":"https://mygame.games.example.com/",
 "release":"20261120T060712Z-3fa9c1d2","files":7,"bytes":41873920,"bytes_brotli":9120331,
 "previous_release":"20261118T221500Z-a01b77e0"}
```

Error codes you may see: `unauthorized` (401), `forbidden` (403), `site_not_found` (404), `release_not_found`
(404), `deploy_in_progress` (409, another change to the same site is running), `manifest_invalid`,
`bundle_invalid` (zip-slip, absolute path, symlink, device file, not a zip), `entry_missing`,
`preview_label_invalid` (422), `upload_too_large`, `bundle_unpacked_too_large`, `bundle_too_many_files` (413),
`rate_limited` (429), `proxy_config_failed` (500, the live site is unchanged).

### How a deploy works

1. Authenticate, validate the manifest, check the token may deploy that site and that the site exists.
2. Stream the bundle to `/data/tmp`, hashing it; enforce the upload limit while streaming.
3. Unpack with zip-slip, symlink, device-file, file-count and real-bytes size checks. `__MACOSX/` and `.DS_Store`
   are skipped; a zip of the folder (one top-level directory, nothing at the root) is treated as its contents.
4. Check `entry` exists.
5. Hard-link every file whose SHA-256 matches the same path in the current release (keeps its mtime, hence its
   ETag), along with its `.br`/`.gz` sidecars.
6. Precompress new files over 1 KB with a compressible extension (`.wasm .pck .js .html .css .json .svg .txt .map`)
   to Brotli 11 and gzip 9; keep a sidecar only if it is smaller; give it the original's mtime.
7. Move the release into place and write `release.json`.
8. Render the site's Caddy snippet; if it changed, validate the whole config and reload Caddy. On failure the old
   snippet is restored and the deploy fails with the old release still live.
9. Go live by atomically renaming a new `current` symlink over the old one.
10. Prune releases beyond `releases.keep`.

Any failure before step 9 leaves the live site untouched; temp files are removed on every path and swept at startup.
Rollback repoints `current` the same way and re-renders the snippet from that release's stored manifest, so headers
roll back too.

Brotli 11 is slow: a 40 MB engine `.wasm` can take a minute or more the first time. Unchanged files are hard-linked,
not recompressed, so later deploys of the same engine version are fast.

## 6. Previews

`preview=<label>` on a deploy publishes to `{name}--{label}.{BASE_DOMAIN}` instead of production. Labels are
1–20 characters of `a-z 0-9 -` with no leading, trailing or doubled `-`; CI is responsible for sanitising branch
names (the example workflow uses `pr-<number>`). A preview keeps one release, is authorised by its parent site's
token, is deleted with its site, and is removed automatically `GAMEHOST_PREVIEW_TTL_DAYS` after its last deploy.

## 7. On-disk layout, backup and restore

```
/data
├── caddy/
│   ├── Caddyfile                # main config, regenerated from env at every start
│   ├── sites/{key}.caddy        # generated snippets (re-rendered at start)
│   └── state/                   # Caddy's data: certificates, ACME account
├── sites/{key}/
│   ├── site.json                # name, created, preview parent/label if any
│   ├── current -> releases/{release_id}
│   └── releases/{release_id}/
│       ├── release.json         # manifest, commit, ref, sizes, deployer token id, per-file hashes
│       └── files/               # the game (+ .br / .gz sidecars); this is what Caddy serves
├── tokens.json                  # [{id, site, sha256, created}], mode 0600
└── tmp/
```

(Game files sit in `files/` rather than next to `release.json` so release metadata is never served publicly.)

`/data` is the only state. Losing it loses sites, tokens and certificates. Releases share unchanged files through
hard links, so back up with a tool that preserves them, and stop the container for a consistent copy:

```sh
docker compose stop gamehost
docker run --rm -v gamehost_gamehost-data:/data -v "$PWD":/backup ubuntu:24.04 \
  tar --create --gzip --file /backup/gamehost-data.tgz -C /data .
docker compose start gamehost
```

Restore into an empty volume with `tar --extract --gzip --same-owner --file /backup/gamehost-data.tgz -C /data`
(same command shape, with the container stopped). The container re-renders all Caddy config at startup, so
restoring onto a host with a different base domain works too; sites then appear under the new domain.

## 8. Security notes

- Every game is its own origin (subdomain), so games cannot read each other's storage.
- Bundles are checked for zip-slip, absolute paths, symlinks, device files, file count, and unpacked size counted
  from bytes actually written.
- Manifest values are validated and quoted before they reach the Caddy config; header values cannot contain newlines
  or Caddy placeholders. This is covered by tests that round-trip hostile values through Caddy's own parser.
- Tokens are stored as SHA-256 hashes and compared in constant time; the admin token must be at least 32 characters.
- Failed authentication is rate-limited per IP. Logs never contain tokens (Caddy redacts `Authorization`).
- The API and the Caddy admin API listen only on loopback; uploads are size-limited by both Caddy and the API.
- Both processes run as a non-root user; Caddy gets `cap_net_bind_service` to bind 80/443.

## 9. Development

```sh
swift build
swift test                                   # unit tests
GAMEHOST_TEST_CADDY=$(which caddy) swift test   # also round-trips generated config through Caddy

# Acceptance tests (spec §14, 1–13) against a native Caddy + API stack, no Docker needed:
CADDY_BIN=$(which caddy) Tests/integration/run-local.sh
# …or against the built image:
Tests/integration/run-docker.sh
```

`gamehost print-caddyfile` prints the main Caddyfile the current environment would produce.

## Status

Built: milestone 1 (core API, release layout, snippets, external mode, tests 1–12) and milestone 4 (previews and the
TTL sweep). Milestone 2 artefacts (per-site TLS config, compose file, this README) are written; per-site mode has
not been exercised against real Let's Encrypt yet. Not built: milestone 3's proof against a real Godot repo and
browsers (test 14), and milestone 5 (wildcard mode).
