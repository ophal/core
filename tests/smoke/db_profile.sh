# The database profile's scenarios, sourced once per backend by
# `tests/smoke/openresty_smoke.sh`.
#
# This is a fragment, not a script: it inherits `set -euo pipefail`, every
# assertion helper, and the per-profile variables `db_profile_begin` filled in
# -- `$DB_URL`, `$SMOKE_DB_FILES`, `$SMOKE_DB_WORK` and the seeded fixture
# names. It is a separate file for one reason: sourcing it once per backend is
# what makes "the same scenarios pass on PostgreSQL" a property of a single
# list rather than of two lists somebody kept in step by hand.
#
# So it carries no backend name and no `case` on one. A scenario that needs to
# know which backend it is running against is a difference in Ophal's behaviour
# there, which is the thing these profiles exist to find rather than to work
# around; the exceptions are the query budgets, which are per backend by
# nature and are named as such where they are asserted.

# Cold pass. This is the request that builds every projection from the seeded
# normalized tables, which is why it is not measured: it is the rebuild, not
# the delivery.
run_request db_frontpage_cold "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
report_ok db_frontpage_cold

run_request db_content_cold "$DB_URL/content/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_content_cold

run_request db_tag_cold "$DB_URL/tag/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_tag_cold

run_request db_alias_cold "$DB_URL/$SEED_ALIAS"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_alias_cold

# The cold pass no longer builds anything. Each of those four requests found a
# projection that had never been built, served the page from the normalized
# source, and queued one rebuild -- deduplicated, so four requests over three
# projections leave three jobs, not twelve. This is what the phase is for: the
# unbounded work is off the request, and the requests above still rendered the
# right pages, which the assertions on their content already proved.
#
# So the drain has to happen here, and every budget below now depends on it.
# That is not an artifact of the test: it is the deployment contract. A site
# that never runs cron serves correct pages forever from the fallback and never
# gets the projections, until the pending marker's TTL lapses and one unlucky
# request rebuilds inline.
run_request db_cron_builds_projections "$DB_URL/cron?token=smoke-cron-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_cron_builds_projections

run_request db_jobs_after_build "$DB_URL/__smoke__?scenario=jobs_status"
assert_status_zero
assert_contains 'SMOKE_JOBS_PENDING=0'
report_ok db_jobs_after_build

# The drain stamped every projection version with the second it ran in, and a
# load running in that same second is deliberately not reusable: a version is a
# unix second, so one written during a load cannot be told apart from one the
# load already saw. Stepping past that second is what makes the numbers below
# the steady state rather than the boundary. The boundary itself is pinned in
# `test_projection_runtime.lua`, where the clock can be frozen.
sleep 1

# One unmeasured pass over the freshly built projections. It is the first read
# of each of them, so it is what fills the per-worker payload caches -- the cold
# pass above could not, because it never touched a projection. It also loads the
# route table into the worker, which is what the requests below then reuse.
# Measuring here would measure the fill; the pass after it is the delivery.
for prime_path in "/" "/content/1" "/tag/1" "/$SEED_ALIAS"; do
  run_request db_prime "$DB_URL$prime_path"
  assert_status_zero
  assert_regex '^HTTP/1\.[01] 200'
done
report_ok db_projections_primed

# Warm pass. Every assertion below is on a whole request, so a page that
# renders nothing would also report zero queries -- the content assertions are
# what stop the budget from being satisfied by an empty response.
#
# These numbers do not depend on how long the warm pass takes to reach. They
# once did: a source key with no `projection_version` row was re-read every time
# the negative cache lapsed, so a gap longer than
# `projection_version_miss_ttl` between the cold and warm passes bought an extra
# query. The rebuilds now record the source version they read, so there is no
# absent key left to re-read. Setting that TTL to 0 in the profile settings
# above is the way to check that claim again after changing a projection.
measure_request db_frontpage_warm "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_SECOND_TITLE"
# Both are `PRAGMA busy_timeout` and the `PRAGMA journal_mode` read, which every
# connection runs -- and bootstrap opens one per request. No table is read at
# all: the route alias index was the third query here until the worker started
# keeping the table it built, and nothing else on an anonymous render reaches
# SQL. Two connections' worth of setup is the whole cost of the page.
assert_query_budget 0 0
report_ok "db_frontpage_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

#[[ What the response says about itself to caches in front of it.
#
# Every response used to carry `cache-control: store, no-cache, must-revalidate`
# and a `last-modified` of *now*, so a page that costs zero queries and zero
# filesystem operations to produce was re-transferred in full to every visitor
# and every intermediary, every time. The validator is the set of projection
# versions the response was built from -- a version is the second its source
# last changed, so if none of them moved, this is the same page.
run_request db_frontpage_cacheable "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '[Ee][Tt]ag: *W/"[0-9a-f]+"'
assert_regex '[Cc]ache-[Cc]ontrol: *public, max-age=0, s-maxage=0, must-revalidate'
assert_regex '[Ll]ast-[Mm]odified:'
assert_regex '[Vv]ary:.*Cookie'
# The two that would each on their own make the response unshareable.
assert_not_contains 'no-cache'
assert_not_contains 'session-id='
frontpage_etag=$(printf '%s\n' "$LAST_OUTPUT" |
  sed -n 's/.*[Ee][Tt]ag: *\(.*\)/\1/p' | tr -d '\r' | tail -1)
[[ -n "$frontpage_etag" ]] || fail 'the front page issued no ETag'
report_ok "db_frontpage_cacheable ($frontpage_etag)"

# The same request with the validator the last one handed out. A 304 carries no
# body, which is the whole point, so the page's own text must be absent.
run_request db_frontpage_revalidates -H "If-None-Match: $frontpage_etag" "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 304'
assert_not_contains "$SEED_CONTENT_TITLE"
report_ok db_frontpage_revalidates

# A validator that does not match gets the page, not a 304. Without this the
# scenario above passes just as well against a handler that answers 304 to
# anything carrying an `If-None-Match` at all.
run_request db_frontpage_stale_etag -H 'If-None-Match: W/"0000000000"' "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
report_ok db_frontpage_stale_etag

#[[ What an anonymous request costs the filesystem.
#
# It costs zero queries and has never been asked this. `session_init()` mints an
# id for any visitor arriving without a valid cookie and `session_start()` opens
# a session file, which takes a lock file with it; `session_write_close()` then
# writes and unlocks at the end of the request. So a visitor who sends no cookie
# and reads nothing still leaves a `.ophal` file behind, and a crawler leaves one
# per request until cron's sweep reaches them.
#
# The session bucket counts the operations `includes/session.lua` performs, and
# each is worth far more underneath: `tests/unit/test_session.lua` measures six
# real `open()` calls for one `safe_open`, and about ten across the request. The
# media bucket is asserted at zero here for the same reason it exists -- this
# page touches no file of its own.
sessions_before=$(find "$SMOKE_DB_SESSIONS" -maxdepth 1 -name '*.ophal' 2>/dev/null | wc -l)
measure_fs_request db_anonymous_session_cost "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
sessions_after=$(find "$SMOKE_DB_SESSIONS" -maxdepth 1 -name '*.ophal' 2>/dev/null | wc -l)
sessions_created=$((sessions_after - sessions_before))
assert_fs_budget 0 0 0 0 0 0
# Was 1/1/1/1 and 112 bytes, then 27 once the CSRF token stopped being minted in
# `init_js()`, and is zero since sessions became lazy: a visitor who presents no
# cookie is given no id, no cookie and no file until something writes into
# `_SESSION`, and nothing on this page does.
assert_session_fs_budget 0 0 0 0 0
[[ "$sessions_created" -eq 0 ]] ||
  fail "expected the anonymous request to leave no session file; left $sessions_created"
# The half that Phase 9 depends on. A response carrying a per-visitor cookie can
# never be shared by a downstream cache, whatever Cache-Control says.
assert_not_contains 'session-id='
report_ok "db_anonymous_session_cost (open=$FS_S_OPEN read=$FS_S_READ write=$FS_S_WRITE remove=$FS_S_REMOVE bytes=$FS_S_BYTES files=+$sessions_created)"

#[[ And the other half: a session that is *needed* is still created.
#
# "Lazy" has to mean deferred rather than absent, and a budget of zero on the
# front page cannot tell the two apart on its own. This asks for a CSRF token as
# an anonymous visitor with no cookie -- `csrf_token()` writes into `_SESSION`,
# which is exactly the event that buys the id, the cookie and the file -- and
# asserts all three arrive.
sessions_before=$(find "$SMOKE_DB_SESSIONS" -maxdepth 1 -name '*.ophal' 2>/dev/null | wc -l)
measure_fs_request db_anonymous_session_on_demand "$DB_URL/__smoke__?scenario=csrf_token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
anon_csrf=$(extract_marker 'SMOKE_CSRF_TOKEN')
[[ -n "$anon_csrf" ]] || fail 'an anonymous visitor was issued no CSRF token'
assert_regex '[Ss]et-[Cc]ookie: *session-id='
sessions_after=$(find "$SMOKE_DB_SESSIONS" -maxdepth 1 -name '*.ophal' 2>/dev/null | wc -l)
sessions_created=$((sessions_after - sessions_before))
[[ "$sessions_created" -eq 1 ]] ||
  fail "expected the token request to create 1 session file; created $sessions_created"
# One open to take the lock and create the file, one write of the token, one
# remove to drop the lock. No read: there was no session to resume.
assert_session_fs_budget 1 0 1 1 95
report_ok "db_anonymous_session_on_demand (open=$FS_S_OPEN write=$FS_S_WRITE remove=$FS_S_REMOVE bytes=$FS_S_BYTES files=+$sessions_created)"

#[[ A well-formed id the server holds no file for buys nothing.
#
# `session_init()` only knows the cookie parses as a uuid, and `safe_open()`
# creates the file it fails to find -- so before `session_start()` learned to
# check, this request minted a session file, a lock file and an inode, and did
# it again for every id an attacker cared to invent. Cron's daily sweep was the
# only thing collecting them.
#
# The ETag is the sharp assertion rather than the counters. A visitor holding a
# stale cookie is anonymous, and the demotion happens before
# `http_cache.disable()` precisely so the response says so: it is `public` with
# a validator, and `Vary: Cookie` is what keeps a shared cache from handing it
# to somebody whose session does exist. A demotion placed one line later would
# leave every budget here at zero and still lose the caching.
stale_session_id='3f2504e0-4f89-41d3-9a0c-0305e82c3301'
sessions_before=$(find "$SMOKE_DB_SESSIONS" -maxdepth 1 -name '*.ophal' 2>/dev/null | wc -l)
measure_fs_request db_stale_session_cookie_costs_nothing -b "session-id=$stale_session_id" "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_session_fs_budget 0 0 0 0 0
sessions_after=$(find "$SMOKE_DB_SESSIONS" -maxdepth 1 -name '*.ophal' 2>/dev/null | wc -l)
sessions_created=$((sessions_after - sessions_before))
[[ "$sessions_created" -eq 0 ]] ||
  fail "expected an unknown session id to create no file; created $sessions_created"
[[ -e "$SMOKE_DB_SESSIONS/$stale_session_id.ophal" ]] &&
  fail "an unknown session id was adopted: $stale_session_id.ophal exists"
# Nothing was written, so nothing minted an id and nothing re-issued the cookie.
assert_not_regex '[Ss]et-[Cc]ookie:'
# Treated as the anonymous request it is.
assert_regex '[Ee][Tt]ag:'
assert_regex 'cache-control:.*public'
report_ok "db_stale_session_cookie_costs_nothing (open=$FS_S_OPEN write=$FS_S_WRITE bytes=$FS_S_BYTES files=+$sessions_created)"

measure_request db_content_warm "$DB_URL/content/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_CONTENT_BODY"
# A content page reads no normalized table. The last one was the tag module's
# `entity_load` join, now served from the payload cache under the
# `tag_listing_source` version.
assert_query_budget 0 0
report_ok "db_content_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

measure_request db_tag_warm "$DB_URL/tag/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_TAG_NAME"
assert_query_budget 0 0
report_ok "db_tag_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

measure_request db_alias_warm "$DB_URL/$SEED_ALIAS"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
# Same page as db_content_warm, reached through the route alias. The alias
# itself costs nothing extra, which is what this budget matching the direct
# route's is saying.
assert_query_budget 0 0
report_ok "db_alias_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# The pager, under `lua_code_cache on`. This is the argument the suite never
# made: the instance that exercised paging ran with the code cache off, which
# reloads every module per request and so hides a module that read `?page=`
# from a table captured when it loaded. Eleven promoted articles are seeded so
# that a second page exists to ask for.
run_request db_frontpage_page_two "$DB_URL/?page=2"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_PAGER_TAIL_TITLE"
assert_not_contains "$SEED_CONTENT_TITLE"
report_ok db_frontpage_page_two

# And back, so the argument is shown to be read per request rather than
# remembered. A worker that answered the previous request from page two and
# this one from page two as well is failing in the other direction.
run_request db_frontpage_page_one_again "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_not_contains "$SEED_PAGER_TAIL_TITLE"
report_ok db_frontpage_page_one_again

# ================================================================
# Authoring profile (same instance, signed in)
# Every budget above is a read. These measure a write, and then measure the
# read that follows it, because a projection design can always make writes look
# cheap by leaving the work for the next visitor to pay. Both halves have to be
# on the record for Phase 5 to have a baseline to move work off.
# ================================================================

# Authored, not seeded: these strings are created through the save service, so
# they are spelled here rather than in seed_database.lua. A page that shows one
# of them proves the write reached the projection the reader is served from.
AUTHORED_TITLE='Smoke Authored Article'
AUTHORED_BODY='SMOKE_AUTHORED_BODY_MARKER'
AUTHORED_UPDATED_TITLE='Smoke Authored Article Revised'
AUTHORED_UPDATED_BODY='SMOKE_AUTHORED_REVISED_MARKER'
COMMENT_BODY='SMOKE_COMMENT_BODY_MARKER'

author_cookie="$SMOKE_DB_WORK/author-cookie.txt"

#[[ The id a fixation attempt plants, obtained from the site itself.
#
# An invented id no longer works, and that is the point of the change this
# scenario was rewritten for: `session_start()` checks whether it actually holds
# a file for a presented id, so a value an attacker made up is discarded rather
# than adopted. Planting an invented id would therefore pass this scenario with
# `session_regenerate()` deleted -- the ids would differ because the planted one
# was never used, not because anything rotated -- and the project would lose its
# only end-to-end proof of the fixation fix.
#
# So the attacker does what an attacker actually does: asks the site for a real
# session, and plants that. Ophal cannot tell it from a returning visitor, which
# is precisely why the rotation at sign-in is still required.
run_request db_author_session_acquire "$DB_URL/__smoke__?scenario=csrf_token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
pre_login_session=$(printf '%s\n' "$LAST_OUTPUT" |
  sed -n 's/.*[Ss]et-[Cc]ookie: *session-id=\([^;]*\).*/\1/p' | tr -d '\r' | tail -1)
[[ -n "$pre_login_session" ]] ||
  fail 'the site issued no session id to plant'
rm -f "$author_cookie"

# Sent as a header rather than written into the jar. The jar is then filled only
# by what the server issues, so a request made with it later cannot send the
# planted id back alongside the real one.
run_request db_author_pre_login_session -b "session-id=$pre_login_session" \
  "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
# The planted id is a session the server really holds, so it is resumed rather
# than replaced -- which is the behaviour the rotation below has to undo. A
# resumed session is not re-issued, so there is no `Set-Cookie` here.
assert_not_contains 'set-cookie'
assert_not_contains 'Set-Cookie'
report_ok db_author_pre_login_session

# Signing in is deliberately not measured. It is the cold pass for this
# account's role, permission and user caches, and it also rewrites the seeded
# legacy password hash in the current format, so what it costs describes a
# first login rather than authoring.
run_request db_author_login -c "$author_cookie" -b "session-id=$pre_login_session" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"user\":\"$SEED_AUTHOR_NAME\",\"pass\":\"$SEED_AUTHOR_PASS\"}" \
  "$DB_URL/user/auth"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '"authenticated" *: *true'
report_ok db_author_login

#[[ The session id must not survive the privilege change.
#
# `session_init()` accepts any well-formed id the cookie presents and the id
# planted above names a session the server really holds, so it is resumed --
# which means that without a rotation the visitor signs in *into the attacker's
# session*. Textbook fixation. `session_regenerate()` in the auth service is
# what rotates it, and this is the end-to-end proof.
#
# Removing that call turns this red at the first check rather than the second,
# and that is not a weaker signal: a resumed session emits no cookie of its own,
# so a sign-in response carrying no `Set-Cookie` at all is precisely the
# statement that the id did not change. Both messages name fixation so a future
# reader is not left to work that out from an empty variable.
#
# Read from the sign-in response's own `Set-Cookie` rather than from the jar.
# The jar is a merge of what was planted and what was received, and the two can
# be stored as separate entries when their domain attributes differ -- which is
# a fact about curl's cookie file, not about whether the server rotated. The
# header is the server saying so.
post_login_session=$(printf '%s\n' "$LAST_OUTPUT" |
  sed -n 's/.*[Ss]et-[Cc]ookie: *session-id=\([^;]*\).*/\1/p' | tr -d '\r' | tail -1)
if [[ -z "$post_login_session" ]]; then
  fail "sign-in issued no session id, so the planted one was kept (fixation): $pre_login_session"
fi
if [[ "$post_login_session" == "$pre_login_session" ]]; then
  fail "session id survived sign-in (fixation): $post_login_session"
fi
report_ok db_author_session_rotated_on_login

# The save service validates a CSRF token, and the token belongs to the session
# the cookie jar now carries. Reading it through the runner rather than parsing
# it out of a form keeps this independent of how the form renders.
run_request db_author_csrf -c "$author_cookie" -b "$author_cookie" "$DB_URL/__smoke__?scenario=csrf_token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
author_csrf=$(extract_marker 'SMOKE_CSRF_TOKEN')
[[ -n "$author_csrf" ]] || fail 'signed-in session reported no CSRF token'
report_ok db_author_csrf

# Two clients, one persistent worker. This is the assertion that says a session
# belongs to the request that carries it, and it exists because nothing else in
# the suite would notice if it did not: a leaked sign-in makes every other
# scenario more permissive, never less.
#
# Both lines of the whoami probe matter. `SMOKE_MODULE_USER_ID` is what
# `modules/user` believes, and `SMOKE_SESSION_USER_ID` is what this request's
# own `_SESSION` holds. A module that captured `_SESSION` as a load-time local
# answers the first from the worker's first request forever, so the two
# disagree and the anonymous client is served as somebody else.
run_request db_author_whoami -c "$author_cookie" -b "$author_cookie" \
  "$DB_URL/__smoke__?scenario=whoami"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_LOGGED_IN=true'
assert_contains 'SMOKE_MODULE_USER_ID=2'
assert_contains 'SMOKE_SESSION_USER_ID=2'
report_ok db_author_whoami

# No cookie jar at all: a visitor who has never been here. Served by the same
# worker that just answered the signed-in request above.
run_request db_anonymous_whoami "$DB_URL/__smoke__?scenario=whoami"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_LOGGED_IN=false'
# Anonymous is user id 0 to `modules/user` -- `load_by_field()` answers id 0
# with a synthetic account -- and the session itself now holds **nothing**.
# `init()` used to seed `_SESSION.user_id = 0` on every request, which since
# Phase 7 would have created a session, a cookie and a file for every visitor;
# `session_user_id()` resolves the same 0 without writing it. The two lines say
# different things on purpose: the first is what the module believes, and a
# leaked `user_id` of 2 shows up there, while the second says this request
# carries no session at all.
assert_contains 'SMOKE_MODULE_USER_ID=0'
assert_contains 'SMOKE_SESSION_USER_ID='
assert_not_contains 'SMOKE_SESSION_USER_ID=2'
report_ok db_anonymous_whoami

# Warms this account's caches. An authenticated request pays four permission
# queries the first time a worker sees the user id; that cost belongs to the
# session, not to the page, so it is spent here rather than inside a budget.
run_request db_author_frontpage_cold -c "$author_cookie" -b "$author_cookie" "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_author_frontpage_cold

measure_request db_author_frontpage_warm -c "$author_cookie" -b "$author_cookie" "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
# The same budget as the anonymous front page. Signing in adds nothing to a
# warm read: the account, its roles and its permissions are all per-worker
# cached by then, which is the end-to-end version of what
# test_user_permissions.lua pins at the handler level.
assert_query_budget 0 0
#[[ And it is not cacheable, even though it costs the same to produce.
#
# The page is the same bytes as the anonymous one here, which is exactly why
# this has to be asserted rather than reasoned about: a validator built from
# projection versions describes the *content*, and content is not what makes a
# signed-in response personal. The response carries the session cookie, which
# `includes/http_cache.lua` treats as disqualifying on its own.
assert_not_regex '[Ee][Tt]ag:'
assert_regex '[Cc]ache-[Cc]ontrol:.*no-cache'
report_ok "db_author_frontpage_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# The create. Tags are included because `entity_after_save()` is where the tag
# module does its writing, and a create without them would measure only half of
# what saving a real article costs.
measure_request db_content_create -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  -H "X-CSRF-Token: $author_csrf" \
  --data-binary "{\"title\":\"$AUTHORED_TITLE\",\"teaser\":\"$AUTHORED_BODY\",\"body\":\"$AUTHORED_BODY\",\"status\":true,\"promote\":true,\"tags\":[1]}" \
  "$DB_URL/content/save"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '"success" *: *true'
authored_id=$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/.*"id" *: *\([0-9][0-9]*\).*/\1/p' | tail -n 1)
[[ -n "$authored_id" ]] || fail 'content save reported no id'
# A characterization budget, not a target. It is here so that a change to the
# write path has to state what it did to the cost, and the breakdown is what
# makes the number readable:
#
#   projection_version   4   four touch() calls, one upsert each
#   content_public       3   the projection DELETE and INSERT, and the tag
#                            rebuild's source read, which joins it
#   content              2   the INSERT, then load_legacy() in entity_after_save
#   field_tag            3   the existing-tags read, the INSERT, the rebuild's
#                            source read
#   tag_listing_index    3   one DELETE plus a row per tagged entity
#   route_index          1   the route lookup every request pays
#   tag                  1
#   plus the connection's two pragmas
#
# Seventeen table hits over sixteen queries, because the tag rebuild's source
# read names `content_public` and `field_tag` both.
#
# This was 26 and 6 when the path was first measured. Three changes took the
# eight off, none of them structural: `save_service()` stopped calling
# `load(id)` before it knew the action, which had been looking up id 0 in
# `content_public` and then in `content` for two certain misses;
# `entity_after_save()` stopped touching `tag_listing_source` a second time from
# inside `tag_projection_rebuild()`; and `projection.touch()` became a single
# upsert instead of a DELETE plus an INSERT.
assert_query_budget 15 5
report_ok "db_content_create (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# What the write left for the next visitor. This is anonymous on purpose: the
# author's own caches were warmed by the write, so measuring the author here
# would hide whatever the write invalidated for everybody else.
measure_request db_frontpage_after_create "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$AUTHORED_TITLE"
# Two more queries than a warm read, both against `content_public`: the front
# page's cached count and row list, reloaded because the write moved the version
# they were stamped with. `cached_value()` invalidates by comparing versions
# rather than by the bucket `projection_touch()` also drops. Still no normalized
# read. This is the number Phase 5 would be moving, so it is pinned apart from
# the write's own cost.
assert_query_budget 2 0
report_ok "db_frontpage_after_create (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

#[[ The validator moved, because the projection version behind it did.
#
# This is the assertion that says the ETag describes the page rather than the
# request: the same URL, the same anonymous visitor, a different answer. A
# validator that did not move here would serve the pre-create front page to
# every cache and every browser holding the old one, which is worse than not
# caching at all -- and it is the failure `modules/boost` shipped with.
run_request db_frontpage_etag_moves "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$AUTHORED_TITLE"
frontpage_etag_after=$(printf '%s\n' "$LAST_OUTPUT" |
  sed -n 's/.*[Ee][Tt]ag: *\(.*\)/\1/p' | tr -d '\r' | tail -1)
[[ -n "$frontpage_etag_after" ]] || fail 'the front page issued no ETag after the create'
[[ "$frontpage_etag_after" != "$frontpage_etag" ]] ||
  fail "the ETag did not move across a content write: $frontpage_etag_after"
# And the stale validator is refused rather than answered 304.
run_request db_frontpage_etag_moves_revalidate -H "If-None-Match: $frontpage_etag" "$DB_URL/"
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$AUTHORED_TITLE"
report_ok "db_frontpage_etag_moves ($frontpage_etag -> $frontpage_etag_after)"

measure_request db_content_update -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  -H "X-CSRF-Token: $author_csrf" \
  --data-binary "{\"title\":\"$AUTHORED_UPDATED_TITLE\",\"teaser\":\"$AUTHORED_UPDATED_BODY\",\"body\":\"$AUTHORED_UPDATED_BODY\",\"status\":true,\"promote\":true,\"tags\":[1]}" \
  "$DB_URL/content/save/$authored_id"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '"success" *: *true'
# An update now costs exactly what a create does. It reads one more row from
# `content_public` -- `load(id)`, which an update genuinely needs and a create
# no longer performs -- and does one less insert-side write. It was 24 before
# the same pass; six of those were `projection_version` pairs.
assert_query_budget 15 5
report_ok "db_content_update (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# Saving over an id that does not exist is a 404, not a 500. The access check
# for an update compares `entity.user_id` against the account, so it has to run
# after the entity is known to exist; when it ran first it indexed a nil. This
# needs the authored session rather than an anonymous one to mean anything:
# `smokeauthor` holds `edit own content` and not `administer content`, which is
# the exact permission shape that reached the dereference. An admin returns
# true above it and an anonymous caller is refused before it.
run_request db_content_save_missing -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  -H "X-CSRF-Token: $author_csrf" \
  --data-binary '{"title":"nothing to update","body":"nothing to update"}' \
  "$DB_URL/content/save/9999"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
assert_regex '"success" *: *false'
assert_contains 'No such content.'
report_ok db_content_save_missing

# Creating a tag, which is the one authoring path with a table of its own that
# nothing else touches: `db_content_create` attaches tag 1 by id, so the
# module's own INSERT never ran under test. It named a `description` column
# that no schema declared -- not INSTALL.md's, not the seed's -- so this
# request failed on every install until 2026-09-08.
run_request db_tag_create -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"action\":\"create\",\"name\":\"SmokeCreatedTag\",\"description\":\"Created by the smoke suite\",\"status\":true,\"csrf_token\":\"$author_csrf\"}" \
  "$DB_URL/tag/service"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '"success" *: *true'
report_ok db_tag_create

# The tag module's own missing-entity answer. It seeded an entity table before
# loading, so `empty(entity)` was never true and the 404 below the access check
# was dead code: an update of an id that does not exist answered 401, from a
# comparison of `nil` against the account id, and a caller could not tell "not
# yours" from "not there".
run_request db_tag_save_missing -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"action\":\"update\",\"name\":\"Nope\",\"csrf_token\":\"$author_csrf\"}" \
  "$DB_URL/tag/service/9999"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
assert_regex '"success" *: *false'
assert_contains 'No such tag.'
report_ok db_tag_save_missing

# ================================================================
# Comments
#
# The comment module had no test profile until 2026-09-09, and these are the
# assertions that gap was hiding. `comment/save` and `comment/fetch` both run
# against a real database here for the first time.
# ================================================================

# A create, through the same CSRF token the authoring path uses. `entity_id`
# points at the seeded article, which is what the fetch below reads back.
run_request db_comment_create -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"entity_id\":1,\"body\":\"$COMMENT_BODY\",\"csrf_token\":\"$author_csrf\"}" \
  "$DB_URL/comment/save"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '"success" *: *true'
comment_id=$(printf '%s' "$LAST_OUTPUT" | sed -n 's/.*"id" *: *\([0-9]*\).*/\1/p' | head -1)
[[ -n "$comment_id" ]] || fail 'comment create returned no id'
report_ok db_comment_create

# The fetch service is anonymous, which is the whole reason it is a projection
# candidate: it reads normalized `comment` and then an account per row. This is
# the first measurement of it, so the budget is recorded rather than argued.
measure_request db_comment_fetch "$DB_URL/comment/fetch/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$COMMENT_BODY"
report_ok "db_comment_fetch (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# 404 rather than 401, and this is the assertion the module was missing. It
# checked access before existence, so `comment_access(nil, 'update')` compared
# `nil.user_id` against the account and answered "not yours" for a comment that
# is not there -- the same defect `modules/tag` had fixed in stage 8.5, left
# standing because nothing ran this module.
run_request db_comment_save_missing -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"entity_id\":1,\"body\":\"nope\",\"csrf_token\":\"$author_csrf\"}" \
  "$DB_URL/comment/save/999999"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
assert_contains 'No such comment.'
report_ok db_comment_save_missing

# An anonymous caller has `access comments` and not `post comments`, so a create
# without the cookie jar is refused. Without this the 404 above could be reached
# by removing the access check altogether.
run_request db_comment_create_anonymous \
  -H 'Content-Type: application/json' \
  --data-binary "{\"entity_id\":1,\"body\":\"nope\"}" \
  "$DB_URL/comment/save"
assert_status_zero
assert_regex '^HTTP/1\.[01] 401'
report_ok db_comment_create_anonymous

#[[ A bodyless request to a JSON service, which used to be a cacheable 200.

# `request_get_body()` answers nil for a method with no body, and
# `dkjson.decode(nil, ...)` raises on it. `route_execute_callback`'s pcall turned
# that raise into a string -- and a Lua error string starts with the file and
# line it was raised at -- which `theme.json` rendered into the response. The
# status stayed 200, so the cache layer marked it `public` with a validator and
# a shared cache could hold it and re-serve it to anyone.
#
# `comment/save` is where this was reachable without an account: `content/save`
# answers 401 before it reads a body and `tag/save` 404s. The path leak itself
# is caught everywhere by `assert_no_source_path` in `report_ok`; what is
# asserted here is the rest of the answer -- a client error, and nothing a cache
# may keep.
run_request db_comment_save_bodyless "$DB_URL/comment/save"
assert_status_zero
assert_regex '^HTTP/1\.[01] 400'
assert_not_regex 'cache-control:.*public'
assert_not_regex '[Ee][Tt]ag:'
report_ok db_comment_save_bodyless

# And the same for a body that is present but will not parse, which is the case
# that reaches the decoder rather than the guard in front of it.
run_request db_comment_save_malformed \
  -H 'Content-Type: application/json' \
  --data-binary '{not json' \
  "$DB_URL/comment/save"
assert_status_zero
assert_regex '^HTTP/1\.[01] 400'
assert_not_regex 'cache-control:.*public'
report_ok db_comment_save_malformed

measure_request db_content_page_after_update "$DB_URL/content/$authored_id"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$AUTHORED_UPDATED_TITLE"
assert_contains "$AUTHORED_UPDATED_BODY"
# The one normalized read is the tag `entity_load` join, and it is here by
# design rather than by oversight. That cache is keyed on `tag_listing_source`
# -- the only version every `field_tag` write is guaranteed to move -- so any
# tag write anywhere invalidates every entity's cached tag set, not just the
# entity that changed. The safe key is the coarse one; a finer key would need a
# per-entity source version. Until then this is what the first reader after a
# tag write pays.
assert_query_budget 2 1
report_ok "db_content_page_after_update (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# The tag listing has to show the authored article too, or the tag rows the
# save wrote never reached the listing projection. This is the only assertion
# that covers the tag half of `entity_after_save()` end to end.
measure_request db_tag_after_update "$DB_URL/tag/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_TAG_NAME"
assert_contains "$AUTHORED_UPDATED_TITLE"
# The listing's own tag entity is keyed on `tag_listing_index`, which the write
# moved, so it comes back from the normalized `tag` table once. The listing
# rows themselves are still projection reads.
assert_query_budget 3 1
report_ok "db_tag_after_update (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# ---------------------------------------------------------------------------
# The cron endpoint's token gate
#
# This is the only profile that configures `settings.cron.token`, which is why
# both halves are covered: `cron_smoke` on the other instance has no token and
# must still be served, because refusing there would break every deployment
# that upgrades without editing its vault. Here a token exists, so a caller
# without it must be refused.
#
# The `allow 127.0.0.1; deny all;` in this profile's /cron location is shipped
# in nginx.ophal.conf too. curl reaches it from 127.0.0.1, so these assertions
# turn on the Lua gate rather than on the nginx one -- which is the point, since
# the token is what protects a site whose cron runs from another host.

# The queue, end to end, against a real SQLite file: enqueue, refuse, drain,
# observe. It is interleaved with the token assertions on purpose -- a refused
# request has to leave the queue alone, which is the part of the gate that
# actually matters. A 403 that had already drained the queue would still pass an
# assertion on the status line.

run_request db_jobs_enqueue "$DB_URL/__smoke__?scenario=jobs_enqueue"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_JOBS_ENQUEUED=true'
assert_contains 'SMOKE_JOBS_PENDING=1'
report_ok db_jobs_enqueue

run_request db_cron_requires_token "$DB_URL/cron"
assert_status_zero
assert_regex '^HTTP/1\.[01] 403'
report_ok db_cron_requires_token

run_request db_cron_rejects_wrong_token "$DB_URL/cron?token=not-the-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 403'
report_ok db_cron_rejects_wrong_token

run_request db_jobs_survive_refused_cron "$DB_URL/__smoke__?scenario=jobs_status"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_JOBS_PENDING=1'
assert_contains 'SMOKE_JOBS_STATUS=pending'
report_ok db_jobs_survive_refused_cron

run_request db_cron_authorized "$DB_URL/cron?token=smoke-cron-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_cron_authorized

# The claim, the handler dispatch, the payload round trip through JSON and the
# completion, all against a real database. This is the only place the SQLite
# claim statement is executed rather than pattern-matched.
run_request db_jobs_drained "$DB_URL/__smoke__?scenario=jobs_status"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_JOBS_PENDING=0'
assert_contains 'SMOKE_JOBS_STATUS=done'
assert_contains 'SMOKE_JOBS_HANDLER=smoke handler ran'
report_ok db_jobs_drained

run_request db_cron_header_token "$DB_URL/cron" \
  -H 'X-Ophal-Cron-Token: smoke-cron-token'
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_cron_header_token

# ---------------------------------------------------------------------------
# A projection that falls behind after it was built
#
# The cold pass above covered the never-built case. This is the other one, and
# the one the phase is named for: a projection exists, its source moves ahead of
# it, and the request that notices must not be the one that rebuilds it. On a
# real site that happens after a restore, a CLI write, or a rebuild that failed
# partway.

run_request db_make_content_stale "$DB_URL/__smoke__?scenario=stale_projection&key=content_public"
assert_status_zero
assert_contains 'SMOKE_STALE_VERSION=1'
report_ok db_make_content_stale

# Correct page, bounded cost, and two writes to the queue rather than a rebuild.
# Six: the two connection pragmas, the fallback's count and page of rows
# straight from `content`, the enqueue, and the age of the row it landed on.
# Bounded is the word that matters -- the two normalized reads are one page of
# content, not the whole table, which is what the rebuild this replaced would
# have read.
#
# The second queue query is what stops a site whose cron never runs from
# deferring forever. `enqueue()` cannot tell the caller whether it wrote a row
# or found one already there, so the age of the live row is what says whether
# anything is draining the queue. It is paid once per stale window and not once
# per request: the next reader is short-circuited by the pending marker, which
# is `db_frontpage_stale_again` below, still at zero infrastructure.
#
# Both are counted apart from the other buckets. A normalized read means the
# request reconstructed source data, and these two did; queue traffic is not
# that, and hiding it in either number would make one of them stop meaning what
# every other budget in this file uses it to mean.
measure_request db_frontpage_stale "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_SECOND_TITLE"
assert_query_budget 4 2 2
report_ok "db_frontpage_stale (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED infrastructure=$MEASURED_INFRASTRUCTURE)"

# The second reader in the same window queues nothing: the unique index on
# `active_key` is what keeps a stale window costing one job instead of one per
# request. Same page, same fallback, no infrastructure query at all.
measure_request db_frontpage_stale_again "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_query_budget 2 2 0
report_ok "db_frontpage_stale_again (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

run_request db_cron_rebuilds_stale "$DB_URL/cron?token=smoke-cron-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_cron_rebuilds_stale

run_request db_reprime "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_reprime

# And the budget comes back. This is the assertion that says the whole loop
# closed: stale, deferred, served from source, queued once, drained, current.
measure_request db_frontpage_after_rebuild "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_SECOND_TITLE"
assert_query_budget 0 0
report_ok "db_frontpage_after_rebuild (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# The alias table is worker state now, so the last thing to prove is that a
# worker which has stopped reading it still sees a write. It has to: a route
# write moves both versions, and the guard reads them before it reuses
# anything.
SEED_LATE_ALIAS='late-smoke-alias'
SEED_REDIRECT_SOURCE='smoke-redirect-source'
SEED_REDIRECT_MOVED='smoke-redirect-moved'

run_request db_alias_created \
  "$DB_URL/__smoke__?scenario=create_alias&source=content/1&alias=$SEED_LATE_ALIAS"
assert_status_zero
assert_contains "SMOKE_ALIAS_CREATED=$SEED_LATE_ALIAS"
report_ok db_alias_created

# The write and the load that notices it have to fall in different seconds, or
# the load is correct but not reusable and the measurement below is of the load
# after it instead. One second is the whole granularity of a version.
sleep 1

# The 404 question, and the answer has to be a page. This request is not
# measured: it is the first content page rendered since `db_cron_rebuilds_stale`
# moved `content_public` and `tag_listing_index`, so its budget is those payload
# caches refilling rather than anything about routes. The reload the write
# forces is pinned per-term in `test_projection_runtime.lua`.
run_request db_late_alias_resolves "$DB_URL/$SEED_LATE_ALIAS"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
report_ok db_late_alias_resolves

# Back to two, on a URL that did not exist when this worker last read
# `route_index`. That is the whole claim: the write was noticed, and the table
# it produced is being reused.
measure_request db_late_alias_reused "$DB_URL/$SEED_LATE_ALIAS"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_query_budget 0 0
report_ok "db_late_alias_reused (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

#[[ Redirects, which had never run at all.
#
# `route_redirect` was created by no schema -- not INSTALL.md, not the
# migrations, not this seeder -- while `examples/settings.lua` and the installer
# both wrote `settings.route_redirects_storage` out as an ordinary toggle. So
# turning it on called `route_redirects_load()` from bootstrap phase 12, which
# has no missing-table tolerance, and 500'd every request on the site. The
# schema landed on 2026-09-10 and the profile has the setting on, so these three
# scenarios are the first execution of `route.redirect_create`,
# `route.redirects_all` and the redirect projection.
run_request db_redirect_created \
  "$DB_URL/__smoke__?scenario=create_redirect&source=$SEED_REDIRECT_SOURCE&target=tag/1"
assert_status_zero
assert_contains "SMOKE_REDIRECT_CREATED=$SEED_REDIRECT_SOURCE"
report_ok db_redirect_created

# Same reason as the alias above: a version is a unix second, so the write and
# the load that notices it have to land in different seconds.
sleep 1

# The default status. `route_create_redirect()` used to default `type` to the
# string 'route_redirect', which is handed to `go_to()` as an HTTP status code
# and reaches `ngx.status` -- unnoticeable while nothing could call it.
run_request db_redirect_resolves "$DB_URL/$SEED_REDIRECT_SOURCE"
assert_status_zero
assert_regex '^HTTP/1\.[01] 302'
assert_regex '[Ll]ocation:.*/tag/1'
report_ok db_redirect_resolves

# And an explicit one, because a redirect that cannot be permanent is not much
# of a redirect. This also pins that the column survives the projection: the
# status is read back through `route_index`, not from the row that was written.
run_request db_redirect_permanent \
  "$DB_URL/__smoke__?scenario=create_redirect&source=$SEED_REDIRECT_MOVED&target=tag/1&status=301"
assert_status_zero
assert_contains "SMOKE_REDIRECT_CREATED=$SEED_REDIRECT_MOVED"
sleep 1
run_request db_redirect_permanent_resolves "$DB_URL/$SEED_REDIRECT_MOVED"
assert_status_zero
assert_regex '^HTTP/1\.[01] 301'
assert_regex '[Ll]ocation:.*/tag/1'
report_ok db_redirect_permanent

# A queue nobody is draining, end to end. This is the one failure the version
# algebra cannot see: pages stay correct the entire time, served from the
# normalized fallback, so nothing short of counting queries notices that the
# projection is never coming back.

run_request db_stall_make_stale "$DB_URL/__smoke__?scenario=stale_projection&key=content_public"
assert_status_zero
assert_contains 'SMOKE_STALE_VERSION=1'
report_ok db_stall_make_stale

# The ordinary deferral: the rebuild goes on the queue and the marker suppresses
# every other reader until it lapses.
run_request db_stall_defers "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
report_ok db_stall_defers

# Now age the queued row and drop the marker, which is where a site with no
# working cron arrives after `projection_rebuild_pending_ttl` seconds.
run_request db_stall_lapses "$DB_URL/__smoke__?scenario=stall_queue&key=content_public"
assert_status_zero
assert_contains 'SMOKE_STALL_PENDING=nil'
report_ok db_stall_lapses

# The request that finds the marker gone rebuilds inline instead of deferring
# again. Unmeasured: this is the request paying for the rebuild, and what it
# costs is the whole projection, which is exactly the cost deferral exists to
# move off a request that can afford to wait for cron.
run_request db_stall_rebuilds "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_SECOND_TITLE"
report_ok db_stall_rebuilds

# And the projection is back, which is the assertion that fails if the recovery
# is removed: without it this request is still on the normalized fallback and
# still counting a queue write, forever.
measure_request db_stall_recovered "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_query_budget 0 0
report_ok "db_stall_recovered (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# --- the media path, measured ---
#
# A two-chunk upload against `bytes_per_chunk = 8`, so the reassembly is real
# rather than a single-chunk special case: 8 bytes then 3, and the merged file
# has to be the concatenation in the right order.

media_upload_id='media-smoke-upload'
media_name='media-smoke.txt'

run_request db_media_csrf "$DB_URL/__smoke__?scenario=csrf_token" -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt"
assert_status_zero
media_csrf=$(extract_marker 'SMOKE_CSRF_TOKEN')
[[ -n "$media_csrf" ]] || fail 'no CSRF token for the media smoke'
report_ok db_media_csrf

measure_fs_request db_media_chunk_one \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  --data-binary 'AAAAAAAA' \
  "$DB_URL/__smoke__?scenario=file_upload_chunk&name=$media_name&id=$media_upload_id&index=0"
assert_status_zero
assert_contains 'SMOKE_UPLOAD_SUCCESS=true'
# Two opens because this chunk is the one that finds no file yet: `r+` misses,
# `w+` creates. Every later chunk costs one. The write goes straight to the
# chunk's own offset in the assembled file, so nothing will read it back.
assert_fs_budget 2 0 1 0 0 8
report_ok "db_media_chunk_one (open=$FS_OPEN write=$FS_WRITE bytes=$FS_BYTES)"

measure_fs_request db_media_chunk_two \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  --data-binary 'BBB' \
  "$DB_URL/__smoke__?scenario=file_upload_chunk&name=$media_name&id=$media_upload_id&index=1"
assert_status_zero
assert_contains 'SMOKE_UPLOAD_SUCCESS=true'
# One open, because the file the first chunk created is still there. `r+` is
# what keeps a retried chunk from truncating everything already assembled.
assert_fs_budget 1 0 1 0 0 3
report_ok "db_media_chunk_two (open=$FS_OPEN write=$FS_WRITE bytes=$FS_BYTES)"

measure_fs_request db_media_merge \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  "$DB_URL/__smoke__?scenario=file_merge_chunks&name=$media_name&id=$media_upload_id&size=11&index=2"
assert_status_zero
assert_contains 'SMOKE_MERGE_SUCCESS=true'
# The bytes have to come back in order, or the reassembly is not reassembly.
assert_contains 'SMOKE_MERGED_FILE=AAAAAAAABBB'
# Nothing but a rename. This was `open=3 read=2 write=2 remove=3 bytes=22`
# before the chunks were written to their offsets -- reassembling an 11-byte
# file read all 11 bytes back and wrote them again, and `read '*a'` held a whole
# chunk as a Lua string while doing it. Counting the 11 bytes the chunk requests
# themselves wrote, an upload moved three times the file's size through Lua; it
# now moves exactly the file's size, once, and the finalize moves none of it.
#
# Zero is the assertion that matters here. Any reintroduction of a read-back
# pass shows up in `read` and `bytes` immediately, whatever shape it takes.
assert_fs_budget 0 0 0 1 0 0
media_file_id=$(extract_marker 'SMOKE_MERGE_ID')
[[ -n "$media_file_id" ]] || fail 'finalize registered no file row'
report_ok "db_media_merge (open=$FS_OPEN read=$FS_READ write=$FS_WRITE bytes=$FS_BYTES)"

# The row is written by finalize; identifying the file is not. Reading the file
# to work out its type is the unbounded half, and it is the half that moves --
# the same trade the projection rebuilds make.
run_request db_media_mime_deferred "$DB_URL/__smoke__?scenario=file_row&id=$media_file_id"
assert_status_zero
assert_contains "SMOKE_FILE_NAME=$media_name"
assert_contains 'SMOKE_FILE_SIZE=11'
report_ok db_media_mime_deferred

# The work is on the queue and has not run.
run_request db_media_job_queued "$DB_URL/__smoke__?scenario=jobs_status&kind=file_post_process"
assert_status_zero
assert_contains 'SMOKE_JOBS_STATUS=pending'
report_ok db_media_job_queued

run_request db_media_cron "$DB_URL/cron?token=smoke-cron-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_media_cron

# And the drain takes it. This fails if the job is never enqueued, if the
# handler was never registered -- `module_invoke_all` would leave the kind
# unknown and the job would sit there -- or if the handler raises.
#
# What it deliberately does not assert is the type itself. libmagic is an
# optional binding and is not present in this workspace, so `filemime` stays
# null here and the identification is covered by a unit test with a stubbed
# `finfo` instead. Same treatment as the PostgreSQL claim clause: the part that
# cannot execute here is named rather than pretended over.
run_request db_media_job_drained "$DB_URL/__smoke__?scenario=jobs_status&kind=file_post_process"
assert_status_zero
assert_contains 'SMOKE_JOBS_STATUS=done'
report_ok db_media_job_drained

# A partial upload must not be sitting in the directory files are served from.
# `nginx.ophal.conf` serves several extensions straight off the document root
# and `files_path` is under it on a real site, so an upload that assembled in
# place would be publicly readable while it was still growing. It assembles
# under a dotted staging directory instead and only arrives under its own name
# at the rename.

partial_id='media-smoke-partial'
partial_name='media-smoke-partial.txt'

run_request db_media_partial_chunk \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  --data-binary 'AAAAAAAA' \
  "$DB_URL/__smoke__?scenario=file_upload_chunk&name=$partial_name&id=$partial_id&index=0"
assert_status_zero
assert_contains 'SMOKE_UPLOAD_SUCCESS=true'
if [[ -e "$SMOKE_DB_FILES/$partial_name" ]]; then
  fail "a partial upload is visible under its own name: $partial_name"
fi
# Nor under its upload id: staging anywhere directly inside `files_path` is the
# same exposure by another name, since what makes a file reachable is the
# directory it is in, not what it is called.
if [[ -e "$SMOKE_DB_FILES/$partial_id" ]]; then
  fail "a partial upload is staged in the served directory: $partial_id"
fi
if [[ ! -s "$SMOKE_DB_FILES/.incoming/$partial_id" ]]; then
  fail "a partial upload is not staged where it should be: $partial_id"
fi
report_ok db_media_partial_chunk

# Finalizing that upload as if it were complete has to fail rather than produce
# a plausible file. Seeking past the end leaves a hole that reads back as NULs,
# so an upload missing a chunk would otherwise finalize into something the right
# size and the wrong contents -- silently, which is the worst version.
run_request db_media_rejects_short_upload \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  "$DB_URL/__smoke__?scenario=file_merge_chunks&name=$partial_name&id=$partial_id&size=11&index=2"
assert_status_zero
assert_contains 'SMOKE_MERGE_SUCCESS=false'
assert_contains 'SMOKE_MERGE_ERROR=upload is 8 bytes, expected 11'
if [[ -e "$SMOKE_DB_FILES/$partial_name" ]]; then
  fail "a short upload was published anyway: $partial_name"
fi
report_ok db_media_rejects_short_upload

# A body nginx buffered to disk. `client_body_buffer_size` above is 1k and this
# is 4k, so nginx has already written the bytes; the upload renames that file
# into place rather than reading it into a Lua string and writing it again.
#
# This is the shape a single-request upload has, which is why it is worth a
# path of its own: for a file that fits in one chunk, the rename is the entire
# transfer and Lua never touches the contents.

spill_id='media-smoke-spill'
spill_name='media-smoke-spill.bin'
spill_body="$SMOKE_DB_WORK/spill-body.bin"
head -c 4096 /dev/zero | tr '\0' 'S' > "$spill_body"

measure_fs_request db_media_spilled_body \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  --data-binary "@$spill_body" \
  "$DB_URL/__smoke__?scenario=file_upload_chunk&name=$spill_name&id=$spill_id&index=0"
assert_status_zero
assert_contains 'SMOKE_UPLOAD_SUCCESS=true'
# Zero bytes through Lua for a 4k body, against `open=2 write=1 bytes=4096` on
# the path a small body still takes. One rename is the whole cost.
assert_fs_budget 0 0 0 1 0 0
report_ok "db_media_spilled_body (rename=$FS_RENAME bytes=$FS_BYTES)"

run_request db_media_spilled_finalize \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  "$DB_URL/__smoke__?scenario=file_merge_chunks&name=$spill_name&id=$spill_id&size=4096&index=1"
assert_status_zero
assert_contains 'SMOKE_MERGE_SUCCESS=true'
report_ok db_media_spilled_finalize

# The bytes have to have survived the rename intact, or "zero bytes through
# Lua" would be true and useless.
if [[ "$(wc -c < "$SMOKE_DB_FILES/$spill_name")" != '4096' ]]; then
  fail "renamed upload is not 4096 bytes"
fi
if [[ -n "$(tr -d 'S' < "$SMOKE_DB_FILES/$spill_name")" ]]; then
  fail 'renamed upload does not hold the bytes that were sent'
fi
report_ok db_media_spilled_contents

# The rename is only safe when there is nothing staged yet. A chunk arriving
# out of order proves the guard: index 1 lands first and creates the staging
# file, so the spilled index 0 that follows must write into it rather than
# rename over it -- a rename there would throw away every chunk already
# assembled and report success while doing it.
ordered_id='media-smoke-ordered'
# Its own name: `filedb_storage` refuses a filename already registered, and the
# spilled upload above finalized under `$spill_name`.
ordered_name='media-smoke-ordered.bin'

run_request db_media_ordered_second \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  --data-binary "@$spill_body" \
  "$DB_URL/__smoke__?scenario=file_upload_chunk&name=$ordered_name&id=$ordered_id&index=1"
assert_status_zero
assert_contains 'SMOKE_UPLOAD_SUCCESS=true'
report_ok db_media_ordered_second

measure_fs_request db_media_ordered_first \
  -c "$SMOKE_DB_WORK/media-cookie.txt" -b "$SMOKE_DB_WORK/media-cookie.txt" \
  -X POST -H "X-CSRF-Token: $media_csrf" \
  --data-binary "@$spill_body" \
  "$DB_URL/__smoke__?scenario=file_upload_chunk&name=$ordered_name&id=$ordered_id&index=0"
assert_status_zero
assert_contains 'SMOKE_UPLOAD_SUCCESS=true'
# The copy, not the rename, even though the body was spilled and the index is 0.
assert_fs_budget 1 0 1 0 0 4096
report_ok "db_media_ordered_first (open=$FS_OPEN write=$FS_WRITE rename=$FS_RENAME bytes=$FS_BYTES)"

# Chunk 1 sat at offset 8, so the assembled file runs past chunk 0's 4096 bytes.
# If the rename had won, the file would be exactly 4096 and chunk 1 would be
# gone.
if [[ "$(wc -c < "$SMOKE_DB_FILES/.incoming/$ordered_id")" != '4104' ]]; then
  fail "out-of-order upload lost a chunk: $(wc -c < "$SMOKE_DB_FILES/.incoming/$ordered_id") bytes"
fi
report_ok db_media_ordered_kept_both

# The injection probe, against this profile's backend.
#
# Last in the profile, so nothing it creates can move a budget measured above
# it. It is here rather than in a script somebody runs by hand because that is
# the difference between a surface that is closed and a surface that was
# checked once: `tests/bench/injection_probe.lua` pushes ten value payloads and
# nine identifier payloads through the bound path, the escaped path, `{ident}`,
# `{ident:bare}`, a composed statement, ad-hoc `db:execute()` and a
# second-order case that stores a payload and reads it back as an identifier.
db_injection_probe
report_ok "db_injection_probe ($(printf '%s' "$LAST_OUTPUT" | sed -n 's/^\([0-9]* passed.*\)$/\1/p' | tail -1))"
