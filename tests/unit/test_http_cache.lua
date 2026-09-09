-- Unit tests for the response's cache semantics.

do
  local root = io.popen('pwd'):read('*l')
  local vendor_root = root .. '/tests/smoke/vendor'
  local vendor_share = vendor_root .. '/unpack/usr/share/lua/5.1'

  package.path = table.concat({
    root .. '/?.lua',
    root .. '/?/init.lua',
    vendor_root .. '/?.lua',
    vendor_root .. '/?/init.lua',
    vendor_share .. '/?.lua',
    vendor_share .. '/?/init.lua',
    package.path,
  }, ';')
end

local pass_count, fail_count = 0, 0

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function assert_truthy(label, value)
  if value then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected truthy, got %s\n'):format(label, tostring(value)))
  end
end

_G.settings = {performance = {}}

local http_cache = require 'includes.http_cache'

--[[ A stand-in for the runtime, recording what the response was given.

  `status()` and `header_get()` are what `includes/server/openresty.lua` gained
  for this: the cache layer has to know what is already on the response before
  it can say whether the response may be kept.
]]
local function mock_adapter(options)
  options = options or {}

  local sent = {}

  return {
    sent = sent,
    status = function()
      return options.status or 200
    end,
    header_get = function(name)
      if sent[name] ~= nil then
        return sent[name]
      end

      return (options.headers or {})[name]
    end,
    header = function(name, value)
      sent[name] = value
    end,
  }, sent
end

local function fresh(options)
  http_cache.reset()

  for key, value in pairs((options or {}).versions or {}) do
    http_cache.depends(key, value)
  end

  return mock_adapter(options)
end

io.write '\n-- HTTP dates without a timezone --\n'

--[[ `os.time` reads its table as local time and an HTTP date is always GMT, so
  a site on any non-UTC machine would compare a validator against a timestamp
  hours away from the one it wrote. The parser is civil-days arithmetic instead,
  and this is the round trip against the formatter that produces the header.
]]
do
  local moment = 1757000000
  local formatted = os.date('!%a, %d %b %Y %X GMT', moment)

  assert_eq('http_date_round_trips', http_cache.parse_http_date(formatted), moment)
  assert_eq('http_date_epoch',
    http_cache.parse_http_date('Thu, 01 Jan 1970 00:00:00 GMT'), 0)
  -- A fixed value nobody can get right by accident, and one that a local-time
  -- implementation gets wrong by exactly the machine's offset.
  assert_eq('http_date_known_value',
    http_cache.parse_http_date('Sun, 06 Nov 1994 08:49:37 GMT'), 784111777)
  assert_eq('http_date_refuses_garbage',
    http_cache.parse_http_date('not a date'), nil)
  -- The obsolete two-digit-year forms are refused rather than guessed at.
  -- Refusing means "no match", which means the page is sent -- the safe way to
  -- be wrong about a validator.
  assert_eq('http_date_refuses_rfc850',
    http_cache.parse_http_date('Sunday, 06-Nov-94 08:49:37 GMT'), nil)
end

io.write '\n-- the validator describes the page --\n'

do
  http_cache.reset()
  http_cache.depends('content_public', 100)
  http_cache.depends('route_index', 200)
  local one = http_cache.fingerprint()

  -- Same pairs, opposite insertion order. `pairs` order is not stable across
  -- workers, so an ETag that depended on it would describe the worker.
  http_cache.reset()
  http_cache.depends('route_index', 200)
  http_cache.depends('content_public', 100)
  assert_eq('fingerprint_ignores_insertion_order', http_cache.fingerprint(), one)

  http_cache.reset()
  http_cache.depends('content_public', 101)
  http_cache.depends('route_index', 200)
  assert_truthy('fingerprint_moves_with_a_version',
    http_cache.fingerprint() ~= one)

  -- A key the page depended on and did not find is recorded as 0 rather than
  -- skipped, so the validator moves when the key appears.
  http_cache.reset()
  http_cache.depends('content_public', 100)
  http_cache.depends('route_index', 200)
  http_cache.depends('tag_listing_index', nil)
  assert_truthy('fingerprint_counts_a_miss', http_cache.fingerprint() ~= one)

  http_cache.reset()
  http_cache.depends(nil, 5)
  http_cache.depends('', 5)
  assert_eq('fingerprint_ignores_a_nameless_key',
    http_cache.fingerprint(), http_cache.fingerprint())
end

io.write '\n-- what may be cached --\n'

do
  local adapter = fresh{versions = {content_public = 100}}

  assert_eq('cacheable_is_not_a_304', http_cache.finalize(adapter, {method = 'GET', headers = {}}), false)
  assert_truthy('cacheable_sets_an_etag', adapter.sent.etag)
  assert_truthy('cacheable_etag_is_weak', tostring(adapter.sent.etag):match('^W/"[0-9a-f]+"$'))
  assert_eq('cacheable_cache_control', adapter.sent['cache-control'],
    'public, max-age=0, s-maxage=0, must-revalidate')
  assert_truthy('cacheable_last_modified', adapter.sent['last-modified'])
  assert_truthy('cacheable_varies_on_cookie',
    tostring(adapter.sent.vary):find('Cookie'))
end

--[[ Each term on its own. They are ways for a response to be about one visitor
  rather than about the site, and a response that fails any of them gets exactly
  the headers it had before this module existed.
]]
do
  local adapter = fresh{versions = {content_public = 100}}
  http_cache.finalize(adapter, {method = 'POST', headers = {}})
  assert_eq('post_is_not_cacheable', adapter.sent.etag, nil)

  adapter = fresh{versions = {content_public = 100}, status = 404}
  http_cache.finalize(adapter, {method = 'GET', headers = {}})
  assert_eq('a_404_is_not_cacheable', adapter.sent.etag, nil)

  adapter = fresh{versions = {content_public = 100},
    headers = {['Set-Cookie'] = 'session-id=x'}}
  http_cache.finalize(adapter, {method = 'GET', headers = {}})
  assert_eq('a_cookie_is_not_cacheable', adapter.sent.etag, nil)

  -- No projection version means no validator, and inventing one is the mistake
  -- `settings.micro_cache` made.
  adapter = fresh{}
  http_cache.finalize(adapter, {method = 'GET', headers = {}})
  assert_eq('no_validator_is_not_cacheable', adapter.sent.etag, nil)

  -- The handler's own veto, which is what `includes/session.lua` uses when it
  -- resumes a session: a signed-in response emits no `Set-Cookie` of its own,
  -- so the cookie test above cannot see it.
  adapter = fresh{versions = {content_public = 100}}
  http_cache.disable()
  http_cache.finalize(adapter, {method = 'GET', headers = {}})
  assert_eq('a_disabled_response_is_not_cacheable', adapter.sent.etag, nil)

  adapter = fresh{versions = {content_public = 100}}
  settings.performance.http_cache = false
  http_cache.finalize(adapter, {method = 'GET', headers = {}})
  assert_eq('the_setting_turns_it_off', adapter.sent.etag, nil)
  settings.performance.http_cache = nil
end

io.write '\n-- revalidation --\n'

do
  local adapter = fresh{versions = {content_public = 100}}
  local etag

  http_cache.finalize(adapter, {method = 'GET', headers = {}})
  etag = adapter.sent.etag

  adapter = fresh{versions = {content_public = 100}}
  assert_eq('a_matching_etag_is_a_304',
    http_cache.finalize(adapter, {method = 'GET', headers = {['if-none-match'] = etag}}), true)
  assert_eq('a_304_sets_the_status', adapter.sent.status, 304)
  assert_eq('the_body_is_suppressed', http_cache.suppressed(), true)

  -- The strong form of the same tag, and a list, both match.
  adapter = fresh{versions = {content_public = 100}}
  assert_eq('a_strong_etag_matches',
    http_cache.finalize(adapter, {method = 'GET',
      headers = {['if-none-match'] = (etag:gsub('^W/', ''))}}), true)

  adapter = fresh{versions = {content_public = 100}}
  assert_eq('a_list_of_etags_matches',
    http_cache.finalize(adapter, {method = 'GET',
      headers = {['if-none-match'] = 'W/"nope", ' .. etag}}), true)

  adapter = fresh{versions = {content_public = 100}}
  assert_eq('a_star_matches',
    http_cache.finalize(adapter, {method = 'GET', headers = {['if-none-match'] = '*'}}), true)

  -- A validator that does not match gets the page. Without this assertion the
  -- ones above pass equally well against a module that answers 304 to anything
  -- carrying an `If-None-Match` at all.
  adapter = fresh{versions = {content_public = 100}}
  assert_eq('a_stale_etag_is_not_a_304',
    http_cache.finalize(adapter, {method = 'GET',
      headers = {['if-none-match'] = 'W/"0000"'}}), false)
  assert_truthy('a_stale_etag_still_gets_a_validator', adapter.sent.etag)

  --[[ `If-Modified-Since` alone, and never beside an entity tag.

    RFC 9110 makes the entity tag the stronger validator and it wins outright
    when both are present. Consulting the date as well would let a client with
    a stale tag and a recent clock be told nothing had changed.
  ]]
  adapter = fresh{versions = {content_public = 100}}
  assert_eq('a_recent_date_alone_is_a_304',
    http_cache.finalize(adapter, {method = 'GET',
      headers = {['if-modified-since'] = os.date('!%a, %d %b %Y %X GMT', 200)}}), true)

  adapter = fresh{versions = {content_public = 100}}
  assert_eq('an_old_date_is_not_a_304',
    http_cache.finalize(adapter, {method = 'GET',
      headers = {['if-modified-since'] = os.date('!%a, %d %b %Y %X GMT', 50)}}), false)

  adapter = fresh{versions = {content_public = 100}}
  assert_eq('a_stale_tag_beats_a_recent_date',
    http_cache.finalize(adapter, {method = 'GET', headers = {
      ['if-none-match'] = 'W/"0000"',
      ['if-modified-since'] = os.date('!%a, %d %b %Y %X GMT', 200),
    }}), false)
end

io.write '\n-- the shared max age --\n'

do
  local adapter

  settings.performance.http_cache_shared_max_age = 120
  adapter = fresh{versions = {content_public = 100}}
  http_cache.finalize(adapter, {method = 'GET', headers = {}})
  assert_eq('shared_max_age_is_configurable', adapter.sent['cache-control'],
    'public, max-age=0, s-maxage=120, must-revalidate')

  -- A nonsense value is the default rather than an error or a negative age.
  settings.performance.http_cache_shared_max_age = -5
  adapter = fresh{versions = {content_public = 100}}
  http_cache.finalize(adapter, {method = 'GET', headers = {}})
  assert_eq('a_negative_shared_max_age_is_zero', adapter.sent['cache-control'],
    'public, max-age=0, s-maxage=0, must-revalidate')

  settings.performance.http_cache_shared_max_age = nil
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
