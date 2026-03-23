# Runtime Adapter Manual Parity Checklist

Use this checklist after the CGI smoke harness is green.

## Goal

Confirm that the runtime-adapter slice behaves the same under `nginx`/OpenResty
for the core request and response paths that were automated for CGI.

## Setup

1. Create a disposable document root outside the main workspace.
2. Copy or symlink these paths into that document root:
   - `includes/`
   - `modules/`
   - `themes/`
   - `libraries/`
   - `index.cgi`
   - `cron.cgi`
3. Add a disposable `settings.lua` and `vault.lua` matching the CGI smoke
   harness defaults:
   - frontpage `lorem_ipsum`
   - theme `basic`
   - module `lorem_ipsum = true`
   - no database
   - sessions enabled
   - output buffering off unless explicitly testing buffering
4. Point `nginx.ophal.conf` at that disposable document root.
5. Start `nginx`/OpenResty with `content_by_lua_file` enabled for `*.cgi`.

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

8. GET `/cron.cgi`
- Expect the entrypoint to boot successfully and return a valid response.

## Pass Condition

The `nginx`/OpenResty run is acceptable when all checks above match the CGI
smoke behavior closely enough that the remaining differences are transport-
specific formatting details, not missing headers, broken redirects, or lost
request/body data.
