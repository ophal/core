--[[ What a response says about itself to caches in front of it.

  Every response used to carry
  `cache-control: store, no-cache, must-revalidate, post-check=0, pre-check=0`
  and a `last-modified` of *now*, on every request without exception. So six
  phases of work made the server fast and left the network untouched: a warm
  anonymous page costs zero queries and zero filesystem operations to produce,
  and was then re-transferred in full to every visitor and every intermediary,
  every time. This is the thing `modules/boost` was reaching for and got wrong.

  **Projection versions are the validator.** A version is the unix second a
  projection's source last changed, and `projection.version()` is the one funnel
  every read goes through -- so the set of `(key, version)` pairs a request
  observed *is* the description of what it was built from. If any of them moves,
  the page may have changed and the ETag changes with it. If none of them moves,
  the page is the same page. Nothing else in the codebase has that property:
  `os.time()` says every response is new, and a content hash would mean
  rendering the page to find out it was unchanged.

  **A request with no projection version is not cacheable.** That is deliberate
  rather than a gap: a page served entirely from normalized tables has no
  validator to hang a revalidation on, and inventing one would be the same
  mistake `micro_cache` made below.

  **The decision is taken at the first byte, not at the end.** Headers are gone
  once the body starts, and Ophal's page handlers load their data and then print
  -- `route_execute_active_handler()` runs the callback to completion, builds
  every region, and only then calls `print_t`. So by the time anything is
  written, every version this page depends on has been read. A handler that
  prints from inside its own callback finalizes earlier and simply comes out
  uncacheable, which is the safe answer rather than a wrong one.

  What replaced `settings.micro_cache`: a 304 for any client whose
  `If-Modified-Since` was within five seconds of *now*, with no validator and no
  reference to the page at all -- so a page that changed inside that window was
  served as unchanged, and one that had not changed in a year was served in full
  the moment the window lapsed. It was off by default and is now gone.
]]

local M = {}

local request_state = require 'includes.request_state'

local date, time, tonumber, tostring = os.date, os.time, tonumber, tostring
local floor, sort, concat = math.floor, table.sort, table.concat
local pairs, ipairs, type = pairs, ipairs, type

--[[ An HTTP date as a unix second, without going through `os.time`.

  `os.time` reads its table as *local* time, and an HTTP date is always GMT, so
  a site on any non-UTC machine would compare a validator against a timestamp
  hours away from the one it wrote. This is the civil-days algorithm instead:
  pure arithmetic, no timezone anywhere in it.

  Only the RFC 1123 form -- `Sun, 06 Nov 1994 08:49:37 GMT`, the one `date()`
  above emits -- is accepted. The obsolete two-digit-year forms return nil,
  which means "no match" and so a full response: refusing to parse errs towards
  sending the page, which is the safe direction for a validator.
]]
local MONTHS = {
  Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

local function days_from_civil(y, m, d)
  local era, yoe, doy, doe

  if m <= 2 then
    y = y - 1
  end

  era = floor(y / 400)
  yoe = y - era * 400
  doy = floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy

  return era * 146097 + doe - 719468
end

local function parse_http_date(value)
  local day, month, year, hour, minute, second =
    tostring(value or ''):match('(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)')

  if day == nil or MONTHS[month] == nil then
    return nil
  end

  return days_from_civil(tonumber(year), MONTHS[month], tonumber(day)) * 86400
    + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
end

--[[ `s-maxage` is 0 unless a deployment says otherwise.

  With `max-age=0, must-revalidate` and an ETag, every request still reaches the
  origin and almost all of them answer 304 with no body -- the transfer is saved
  and correctness is untouched. Raising `s-maxage` is what lets a shared cache
  answer without asking at all, and it is exactly the trade this project refuses
  to make on somebody's behalf: a write is invisible to anyone behind that cache
  for up to that many seconds. The lever is documented; the default is honest.
]]
local DEFAULT_SHARED_MAX_AGE = 0

local function performance()
  return (settings or {}).performance or {}
end

local function shared_max_age()
  local value = tonumber(performance().http_cache_shared_max_age)

  -- `value ~= value` is the NaN test.
  if value == nil or value ~= value or value < 0 then
    return DEFAULT_SHARED_MAX_AGE
  end

  return floor(value)
end

local function enabled()
  return performance().http_cache ~= false
end

--[[ Per request, in `ngx.ctx`, for the reason every other accumulator is.

  A worker runs one Lua VM and a cosocket query is a yield, so a file upvalue
  here would describe whichever request ran last. Same rule as
  `includes/common.lua`'s JS and CSS accumulators.
]]
local function state()
  local current = request_state.current()

  if current.http_cache == nil then
    current.http_cache = {
      versions = {},
      count = 0,
      newest = 0,
      allowed = true,
      finalized = false,
      not_modified = false,
    }
  end

  return current.http_cache
end

--[[ Record that this response was built from `key` at `version`.

  Called from `projection.version()`, which is the single point every version
  read passes through -- so no call site has to remember to declare anything and
  none can forget. A miss is recorded as 0 rather than skipped: a page that
  depends on a key which does not exist yet must change its validator when the
  key appears.
]]
function M.depends(key, version)
  local current, normalized

  if type(key) ~= 'string' or key == '' then
    return
  end

  current = state()
  normalized = tonumber(version) or 0

  if current.versions[key] == normalized then
    return
  end

  if current.versions[key] == nil then
    current.count = current.count + 1
  end

  current.versions[key] = normalized

  if normalized > current.newest then
    current.newest = normalized
  end
end

--[[ Take this response out of the cacheable set.

  For a handler that knows something the versions do not -- a page whose content
  depends on the visitor, the clock, or anything else a projection version does
  not describe. There is no matching `allow()`: cacheability is earned by the
  conditions below, never asserted.
]]
function M.disable()
  state().allowed = false
end

local function digest(value)
  -- `ngx.md5` is a C call and is what serves the web runtime. The bundled
  -- pure-Lua sha256 covers anything else; neither is a security boundary here,
  -- because an ETag is not a secret and forging one only misleads the forger's
  -- own cache.
  if ngx ~= nil and type(ngx.md5) == 'function' then
    return ngx.md5(value)
  end

  return require('includes.sha256').hash256(value):sub(1, 32)
end

local function fingerprint(current)
  local keys, parts = {}, {}

  for key in pairs(current.versions) do
    keys[#keys + 1] = key
  end

  -- Sorted, because `pairs` order is not stable across workers and an ETag that
  -- depends on hash iteration order describes the worker rather than the page.
  sort(keys)

  for _, key in ipairs(keys) do
    parts[#parts + 1] = ('%s=%d'):format(key, current.versions[key])
  end

  return digest(concat(parts, ','))
end

--[[ Is this response one a cache may keep?

  Every term is a way for a response to be about one visitor rather than about
  the site, and each is checked rather than assumed:

  * a method other than GET or HEAD is an action, not a document;
  * a status other than 200 has its own caching rules and none of them are
    these;
  * a `Set-Cookie` makes a response personal by definition -- this is what
    Phase 7 removed from the anonymous path, and it is checked here rather than
    inferred from the session, so a cookie set by anything else still counts;
  * no projection version means no validator;
  * and `M.disable()` is the handler's own veto.
]]
local function cacheable(current, adapter, method)
  if not enabled() or not current.allowed or current.count == 0 then
    return false
  end

  -- A runtime that cannot say what it has already put on the response cannot be
  -- reasoned about, so it gets the answer it had before this file existed. This
  -- is a capability question about the adapter interface, not a guard around a
  -- global that should have resolved.
  if type(adapter.status) ~= 'function' or type(adapter.header_get) ~= 'function' then
    return false
  end

  if method ~= 'GET' and method ~= 'HEAD' then
    return false
  end

  if adapter.status() ~= 200 then
    return false
  end

  return adapter.header_get('Set-Cookie') == nil
end

local function etag_matches(candidate, etag)
  if candidate == nil or candidate == '' then
    return false
  end

  -- A client may send several, and a weak validator compares equal to its
  -- strong twin for this purpose. `*` matches anything the origin holds.
  if candidate == '*' then
    return true
  end

  for token in tostring(candidate):gmatch('[^,]+') do
    local cleaned = token:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^W/', ''):gsub('"', '')

    if cleaned == etag then
      return true
    end
  end

  return false
end

--[[ Decide, emit, and say whether the body should be suppressed.

  Called from `write()` before the first byte reaches the adapter, and exactly
  once per request. Returns true when the response is a 304, in which case every
  write for the rest of the request is dropped -- which is how the body is
  suppressed without an early exit, and leaves the shutdown path unchanged.
]]
function M.finalize(adapter, request)
  local current = state()
  local headers, etag, matched

  if current.finalized then
    return current.not_modified
  end

  current.finalized = true

  if not cacheable(current, adapter, (request or {}).method) then
    return false
  end

  etag = fingerprint(current)
  headers = (request or {}).headers or {}

  adapter.header('etag', ('W/"%s"'):format(etag))
  adapter.header('last-modified', date('!%a, %d %b %Y %X GMT', current.newest))
  adapter.header('cache-control', ('public, max-age=0, s-maxage=%d, must-revalidate')
    :format(shared_max_age()))
  -- The dynamic-content `expires` set at load time is in the past, which
  -- contradicts everything above it.
  adapter.header('expires', nil)
  -- A shared cache must not serve one visitor's page to another purely because
  -- the URL matched, and `Vary` is how that is said.
  adapter.header('vary', 'Accept-Encoding, Cookie')

  matched = etag_matches(headers['if-none-match'] or headers['If-None-Match'], etag)

  --[[ `If-Modified-Since` is only consulted when there is no `If-None-Match`.

    RFC 9110: an entity tag is the stronger validator and wins outright when
    both are present. Comparing dates as well would let a client with a stale
    ETag and a recent date be told nothing changed.
  ]]
  if not matched and headers['if-none-match'] == nil and headers['If-None-Match'] == nil then
    local since = headers['if-modified-since'] or headers['If-Modified-Since']

    if since ~= nil then
      local parsed = parse_http_date(since)

      matched = parsed ~= nil and current.newest <= parsed
    end
  end

  if matched then
    adapter.header('status', 304)
    adapter.header('content-type', nil)
    current.not_modified = true
  end

  return current.not_modified
end

-- True once `finalize()` has chosen a 304, so `write()` can drop the body.
function M.suppressed()
  return state().not_modified
end

-- Exposed for `tests/unit/test_http_cache.lua`, which drives the date parser
-- and the fingerprint directly rather than through a request.
M.parse_http_date = parse_http_date

function M.fingerprint()
  return fingerprint(state())
end

function M.reset()
  request_state.current().http_cache = nil
end

return M
