# OpenResty Runtime Manual Checklist

## Goal

Confirm that the OpenResty runtime behaves correctly for the core request and
response paths that matter in production.

## Setup

1. Create a disposable document root outside the main workspace.
2. Copy or symlink these paths into that document root:
   - `includes/`
   - `modules/`
   - `themes/`
   - `libraries/`
   - `index.lua`
   - `cron.lua`
3. Add a disposable `settings.lua` and `vault.lua` matching the OpenResty smoke
   harness defaults:
   - frontpage `lorem_ipsum`
   - theme `basic`
   - module `lorem_ipsum = true`
   - no database
   - sessions enabled
   - output buffering off unless explicitly testing buffering
4. Point `nginx.ophal.conf` at that disposable document root.
5. Start `nginx`/OpenResty with `content_by_lua_file` enabled for the internal
   `index.lua` and `cron.lua` entrypoints.

## Checks

1. GET `/`
- Expect HTML response with `Lorem Ipsum` content.
- Expect `X-Frame-Options: SAMEORIGIN`.

2. GET `/loremipsum`
- Expect the alias route to resolve and return the same page.

3. GET a missing path such as `/does-not-exist`
- Expect HTTP 404 and the page-not-found body.

4. POST a known body to a temporary smoke callback route or equivalent wrapper
- Expect `request_get_body()` to return the exact body.
- Verify GET for the same callback reports no body.

5. Trigger a redirect through `goto('lorem_ipsum')`
- Expect a redirect status and `Location` header for `/loremipsum`.

6. Emit two cookies in one response
- Expect both `Set-Cookie` headers to be present.

7. Enable output buffering and emit a custom header plus body text
- Expect both the header and body in the final response.

8. GET `/cron`
- Expect the entrypoint to boot successfully and return a valid response.

9. GET `/index.lua`, `/cron.lua`, `/settings.lua`, and `/includes/bootstrap.lua`
- Expect HTTP 404 for all of them.

## Pass Condition

The OpenResty run is acceptable when all checks above succeed and internal Lua
source or secret files are not directly retrievable over HTTP.
