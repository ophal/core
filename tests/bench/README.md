# Query-layer benchmark

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
