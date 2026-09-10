# Benchmarks

Two harnesses live here. `run_bench.sh` and `run_layer_bench.sh` measure the
database path; `run_json_bench.sh` measures the JSON backend. All three answer
the same kind of question, which is what gates a dependency change in this
project: a number, before anything moves.

## Query-layer benchmark

Measures what each candidate database driver costs, so the query layer and the
per-backend drivers behind it are chosen on numbers rather than on argument.

```sh
bash tests/bench/setup_backends.sh all    # download, unpack, initdb, start
bash tests/bench/run_bench.sh
bash tests/bench/setup_backends.sh stop
```

Nothing here needs root. PostgreSQL and MariaDB are unpacked into
`tests/smoke/vendor/backends/` and run out of that tree with their data
directories under `tests/smoke/vendor/backends/run/`, which is ignored by git
the way the rest of `tests/smoke/vendor/` is. `lsqlite3` has no Ubuntu package
and there is no LuaRocks here, so it is compiled from source; the step is
skipped with a message if `gcc` is absent.

## What it reports, and why there are two numbers

**Serial ops/sec** is per-call overhead: one client, one connection, no
concurrency. A blocking C binding usually wins it, because it has no coroutine
to yield through and no protocol to encode in Lua.

**Concurrent ops/sec** is what one worker can deliver with `OPHAL_BENCH_CONCURRENCY`
requests in flight, each on its own connection. This is the number that
describes a web runtime. A blocking driver holds the worker for the whole round
trip, so its concurrent rate lands on top of its serial one however many
clients arrive -- and often slightly below it, for the coroutine overhead it
now pays without any overlap to gain.

A benchmark reporting only the first would recommend a blocking driver, which
is the mistake this file exists to avoid.

Only operations that actually returned are counted, and failures are reported
in their own column. An earlier version counted a thread's whole quota whether
its queries succeeded or not, which made SQLite look like it scaled with
concurrency at the exact moment it was answering "database is locked".

Each candidate re-creates and re-seeds `bench_rows` before the serial group and
again before the concurrent group, and thread `n` takes the slice of iterations
`(n-1) * per_thread` upward -- so the two groups perform the same work on the
same table. Handing every thread the same iteration numbers instead made each
write identical values to identical rows, which MySQL skips as a no-op and
SQLite serves from one hot page.

`null:` is reported per candidate before the timings, because how a driver
returns a SQL NULL breaks call sites more often than how fast it is:
`empty()` is called on column values throughout this codebase, and neither
`ngx.null` nor an empty string is empty.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPHAL_BENCH_ITERATIONS` | 2000 | operations per workload |
| `OPHAL_BENCH_CONCURRENCY` | 25 | light threads, and connections, in the concurrent group |
| `OPHAL_BENCH_ROWS` | 500 | rows seeded before each group |
| `OPHAL_BENCH_PAGE` | 100 | rows in the multi-row select |
| `OPHAL_BENCH_ONLY` | — | substring of a candidate id, to run one family |
| `OPHAL_BENCH_PG_PORT` | 15432 | |
| `OPHAL_BENCH_MY_PORT` | 13306 | |

## Adding a candidate

`tests/bench/drivers.lua` holds one adapter per driver, each answering the same
four questions -- `point`, `page`, `insert`, `update` -- in whatever dialect and
parameter style that driver is best at. That is deliberate: forcing one dialect
on all of them would measure the dialect. Add an entry to `M.candidates` with a
`build` function and it joins the table.

## JSON benchmark

```sh
bash tests/smoke/setup_vendor_runtime.sh   # once, for dkjson and seawolf
bash tests/bench/run_json_bench.sh
```

Runs under `resty`, which is the only runtime Ophal supports.

This is the measurement that retired `dkjson`: it is no longer a dependency, and
`includes/json.lua` is cjson with four of its behaviours pinned down. The bench
is kept rather than deleted because the argument for that choice is only
checkable with both libraries in front of you, and `setup_vendor_runtime.sh`
still vendors `dkjson` for exactly this.

It reports two things and **exits non-zero on the second**.

The timings cover the two workloads that matter: a session payload, where JSON
replaces `table_dump` plus `loadstring` rather than another JSON library, and a
service response at the shape `comment/fetch` returns. The service phase runs at
three row counts, so a ratio that holds across them says the difference is per
byte rather than a fixed cost being amortised.

The assertions cover where two backends **disagree**, which is the part a
timing harness would miss: the empty table encodes as `[]` on one and `{}` on
the other, `null` decodes to a truthy sentinel on one and to an absent key on
the other, `decode` answers three values on one and two on the other, and a nil
input raises on one and is declined by the other. Each of those is a silent
output change under a naive swap -- nothing raises, nothing is slower, and the
bytes are not the same bytes -- so they are pinned here and this harness fails
when a backend upgrade moves one.

Two facts about cjson's configuration are asserted for the same reason:
`encode_empty_table_as_object` is **not** shared between `cjson` and
`cjson.safe`, so configure the exact module you encode with, and
`encode_escape_forward_slash` **is** shared, so it is VM-global state that
reaches every other cjson user in the worker and the shim must leave it alone.

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPHAL_BENCH_ITERATIONS` | 100000 | operations per candidate; the service phase runs a twentieth of it |

## Digest benchmark

```sh
bash tests/bench/run_digest_bench.sh
```

Runs under `resty`. Needs nothing vendored: `tests/bench/sha256_pure.lua` is the
retired pure-Lua implementation, kept here so the comparison stays checkable.

This is the measurement that retired the pure-Lua SHA-256 from the password
path. Ophal iterates a digest 10,000 times by default and resolved that digest
through a chain of optional rocks before falling through to a bundled pure-Lua
implementation, so the shipped configuration ran ten thousand rounds of
interpreted SHA-256 inside a request. `README.md` presented that as a feature —
"no cryptography library is needed" — and it was true only because nothing ever
asked OpenResty, which has shipped `resty.sha256` all along.

It reports timings at 1, 100 and 10,000 iterations and **exits non-zero** on any
assertion, of which there are two kinds and they prove different things.

**Agreement** is what gates the swap. `password_verify()` re-derives the whole
stored string and `secure_equals` it, so a digest differing by one nibble locks
out every existing account. Agreement is asserted over the iteration chain
rather than over a single call, because each round feeds the previous round's
hex back in — an implementation that diverged only on an empty input would pass
a single-shot comparison. The block boundaries either side of 64 bytes are
checked for the same reason: that is where a padding bug lives.

**Vectors** say each algorithm name is wired to the right implementation, which
agreement cannot. The digests of `"abc"` are cross-checked against `openssl
dgst` rather than against the bindings under test — a vector taken from the
thing being tested proves only that it agrees with itself. Pointing `sha384` at
`resty.sha512` turns exactly one assertion red, and nothing in Ophal would
otherwise notice, since no site configures those algorithms.

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPHAL_BENCH_ITERATIONS` | 10000 | the largest iteration count timed; the shipped default for `settings.user.password_hash.iterations` |
