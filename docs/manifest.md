# `gamehost.toml` reference

The manifest lives at the root of a game repository and fully describes how that game is served. It is sent,
unmodified, with every deploy; the server is the validator of record and rejects anything it does not recognise.

```toml
# Required
name = "mygame"            # → mygame.{BASE_DOMAIN}
dir  = "build/web"         # exported files, relative to the repo root (used by CI when zipping)

# Optional (defaults shown)
entry = "index.html"       # must exist at the root of the bundle

[headers]
cross_origin_isolation = false   # true adds COOP/COEP for threaded Godot exports

[headers.custom]                 # extra response headers on every file
# "Permissions-Policy" = "gamepad=(self)"

[cache]
max_age = 0                # seconds; 0 = always revalidate

[releases]
keep = 5                   # releases retained for rollback, 1–50
```

## Keys

| Key | Type | Default | Rules |
|---|---|---|---|
| `schema` | integer | `1` | Optional. Only `1` exists. Any other value is an error. |
| `name` | string | — | Required. `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`, no `--` (reserved for previews), not `deploy`, `api`, `www`, `admin`, or the first label of `GAMEHOST_API_HOST`. |
| `dir` | string | — | Required. Relative path, no `..`, no leading `/`. Not used by the server; validated so CI and server share one schema. |
| `entry` | string | `index.html` | Relative path of `A-Z a-z 0-9 . _ - /`, no `..`. Must exist in the bundle. If not `index.html`, `/` is rewritten to it. |
| `headers.cross_origin_isolation` | boolean | `false` | `true` sends `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`. |
| `headers.custom` | table of strings | `{}` | See below. |
| `cache.max_age` | integer | `0` | `0`–`31536000`. `0` sends `Cache-Control: no-cache`; otherwise `public, max-age=N`. |
| `releases.keep` | integer | `5` | `1`–`50`. Previews always keep 1. |

Unknown keys anywhere are an error, so typos fail the deploy instead of being silently ignored.

### Custom headers

- Names match `^[A-Za-z0-9-]+$`, start with a letter or digit, and are unique (case-insensitively).
- Not allowed: `Content-Type`, `Content-Encoding`, `Content-Length`, `ETag`, and the hop-by-hop headers
  `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Upgrade`, `Trailer`, `TE`.
- Values are 1–2048 bytes of printable ASCII with no CR/LF, and may not contain `{`, `}`, `\` or `` ` ``.
  Double quotes are fine. The brace rule exists because Caddy expands `{placeholders}` in header values,
  which could otherwise leak server data (for example `{env.GAMEHOST_ADMIN_TOKEN}`).
- Custom headers are applied after the built-in ones, so they can override `Cache-Control` or the COOP/COEP pair
  (for example `"Cross-Origin-Embedder-Policy" = "credentialless"`).

## Caching

Godot does not content-hash export filenames (`index.wasm` and `index.pck` keep their names every release), so
long-lived caching would pin players to old builds. The default `no-cache` makes browsers keep files but revalidate
with the ETag on each load. gamehost hard-links files that did not change since the previous release, which keeps
their modification time and therefore their ETag: an unchanged engine `.wasm` costs a `304` per visit while a changed
`.pck` is fetched fresh. Only set `cache.max_age` if stale files for that long are acceptable.

## Errors

A rejected manifest returns `422` with code `manifest_invalid` and one entry in `details` per problem:

```json
{"error": {"code": "manifest_invalid", "message": "gamehost.toml failed validation.",
           "details": ["unknown key \"entyr\"", "releases.keep must be between 1 and 50"]}}
```
