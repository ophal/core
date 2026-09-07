local function run_all(ctx, statements)
  for _, statement in ipairs(statements or {}) do
    local ok, err = ctx.db_query(statement)
    if not ok then
      return nil, err
    end
  end

  return true
end

local function route_index_sql(driver)
  if driver == 'postgresql' then
    return {
      [[CREATE TABLE IF NOT EXISTS route_index(
  kind character varying(32) NOT NULL,
  source character varying(255) NOT NULL,
  target character varying(255),
  language character varying(32),
  http_code integer,
  updated_at bigint,
  PRIMARY KEY(kind, source)
)]],
      [[CREATE INDEX IF NOT EXISTS idx_route_index_kind_target
ON route_index(kind, target)]],
    }
  end

  return {
    [[CREATE TABLE IF NOT EXISTS route_index(
  kind VARCHAR(32) NOT NULL,
  source VARCHAR(255) NOT NULL,
  target VARCHAR(255),
  language VARCHAR(32),
  http_code INTEGER,
  updated_at UNSIGNED BIG INT,
  PRIMARY KEY(kind, source)
)]],
      [[CREATE INDEX IF NOT EXISTS idx_route_index_kind_target
ON route_index(kind, target)]],
    }
end

local function content_public_sql(driver)
  if driver == 'postgresql' then
    return {
      [[CREATE TABLE IF NOT EXISTS content_public(
  id bigint PRIMARY KEY,
  user_id bigint,
  language character varying(12),
  title character varying(255),
  teaser text,
  body text,
  created bigint,
  changed bigint,
  status smallint,
  promote smallint,
  route character varying(255),
  updated_at bigint
)]],
      [[CREATE INDEX IF NOT EXISTS idx_content_public_route
ON content_public(route)]],
      [[CREATE INDEX IF NOT EXISTS idx_content_public_frontpage
ON content_public(promote, status, created DESC)]],
      [[CREATE INDEX IF NOT EXISTS idx_content_public_user
ON content_public(user_id)]],
    }
  end

  return {
    [[CREATE TABLE IF NOT EXISTS content_public(
  id INTEGER PRIMARY KEY,
  user_id UNSIGNED BIG INT,
  language VARCHAR(12),
  title VARCHAR(255),
  teaser TEXT,
  body TEXT,
  created UNSIGNED BIG INT,
  changed UNSIGNED BIG INT,
  status BOOLEAN,
  promote BOOLEAN,
  route VARCHAR(255),
  updated_at UNSIGNED BIG INT
)]],
      [[CREATE INDEX IF NOT EXISTS idx_content_public_route
ON content_public(route)]],
      [[CREATE INDEX IF NOT EXISTS idx_content_public_frontpage
ON content_public(promote, status, created DESC)]],
      [[CREATE INDEX IF NOT EXISTS idx_content_public_user
ON content_public(user_id)]],
    }
end

local function projection_version_sql(driver)
  if driver == 'postgresql' then
    return {
      [[CREATE TABLE IF NOT EXISTS projection_version(
  projection_key character varying(255) PRIMARY KEY,
  version bigint,
  updated_at bigint
)]],
    }
  end

  return {
    [[CREATE TABLE IF NOT EXISTS projection_version(
  projection_key VARCHAR(255) PRIMARY KEY,
  version UNSIGNED BIG INT,
  updated_at UNSIGNED BIG INT
)]],
  }
end

local function tag_listing_index_sql(driver)
  if driver == 'postgresql' then
    return {
      [[CREATE TABLE IF NOT EXISTS tag_listing_index(
  tag_id bigint NOT NULL,
  tag_name character varying(255),
  entity_type character varying(255) NOT NULL,
  entity_id bigint NOT NULL,
  user_id bigint,
  language character varying(12),
  title character varying(255),
  teaser text,
  body text,
  created bigint,
  changed bigint,
  status smallint,
  promote smallint,
  route character varying(255),
  updated_at bigint,
  PRIMARY KEY(tag_id, entity_type, entity_id)
)]],
      [[CREATE INDEX IF NOT EXISTS idx_tag_listing_index_tag_created
ON tag_listing_index(tag_id, created DESC)]],
      [[CREATE INDEX IF NOT EXISTS idx_tag_listing_index_route
ON tag_listing_index(route)]],
    }
  end

  return {
    [[CREATE TABLE IF NOT EXISTS tag_listing_index(
  tag_id UNSIGNED BIG INT NOT NULL,
  tag_name VARCHAR(255),
  entity_type VARCHAR(255) NOT NULL,
  entity_id UNSIGNED BIG INT NOT NULL,
  user_id UNSIGNED BIG INT,
  language VARCHAR(12),
  title VARCHAR(255),
  teaser TEXT,
  body TEXT,
  created UNSIGNED BIG INT,
  changed UNSIGNED BIG INT,
  status BOOLEAN,
  promote BOOLEAN,
  route VARCHAR(255),
  updated_at UNSIGNED BIG INT,
  PRIMARY KEY(tag_id, entity_type, entity_id)
)]],
      [[CREATE INDEX IF NOT EXISTS idx_tag_listing_index_tag_created
ON tag_listing_index(tag_id, created DESC)]],
      [[CREATE INDEX IF NOT EXISTS idx_tag_listing_index_route
ON tag_listing_index(route)]],
    }
end

-- The deferred-work queue. `projection.ensure()` enqueues a rebuild here
-- instead of running it inline, so a stale projection stops being a latency
-- event on the request path.
--
-- `active_key` is what makes dedup a database guarantee rather than a hopeful
-- read-then-write. It holds the job's identity while the job is pending or
-- running and is set to NULL once it reaches a terminal state; NULLs are
-- distinct in a unique index on both drivers, so a single-column UNIQUE gives
-- exactly "at most one live job per identity" with no partial-index syntax and
-- no per-driver conflict target. Enqueue is then one portable
-- `INSERT ... ON CONFLICT(active_key) DO NOTHING`, and `projection.touch()`
-- already established that SQLite floor.
--
-- `priority` is dependency depth, ascending: a projection that depends on
-- another rebuilds after it, so `tag_listing_index` (which depends_on
-- `content_public`) sorts behind it in one drain.
local function jobs_sql(driver)
  if driver == 'postgresql' then
    return {
      [[CREATE TABLE IF NOT EXISTS ophal_jobs(
  id bigserial PRIMARY KEY,
  kind character varying(64) NOT NULL,
  dedup_key character varying(255),
  active_key character varying(255),
  payload text,
  status character varying(16) NOT NULL,
  priority integer,
  attempts integer,
  available_at bigint,
  claimed_at bigint,
  claimed_by character varying(64),
  created_at bigint,
  updated_at bigint,
  last_error text
)]],
      [[CREATE UNIQUE INDEX IF NOT EXISTS unq_idx_ophal_jobs_active_key
ON ophal_jobs(active_key)]],
      [[CREATE INDEX IF NOT EXISTS idx_ophal_jobs_claim
ON ophal_jobs(status, priority, id)]],
    }
  end

  return {
    [[CREATE TABLE IF NOT EXISTS ophal_jobs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind VARCHAR(64) NOT NULL,
  dedup_key VARCHAR(255),
  active_key VARCHAR(255),
  payload TEXT,
  status VARCHAR(16) NOT NULL,
  priority INTEGER,
  attempts INTEGER,
  available_at UNSIGNED BIG INT,
  claimed_at UNSIGNED BIG INT,
  claimed_by VARCHAR(64),
  created_at UNSIGNED BIG INT,
  updated_at UNSIGNED BIG INT,
  last_error TEXT
)]],
    [[CREATE UNIQUE INDEX IF NOT EXISTS unq_idx_ophal_jobs_active_key
ON ophal_jobs(active_key)]],
    [[CREATE INDEX IF NOT EXISTS idx_ophal_jobs_claim
ON ophal_jobs(status, priority, id)]],
  }
end

return {
  {
    id = '001_route_index',
    name = 'Create route projection index',
    up = function(ctx)
      return run_all(ctx, route_index_sql(ctx.driver))
    end,
  },
  {
    id = '002_content_public',
    name = 'Create public content projection',
    up = function(ctx)
      return run_all(ctx, content_public_sql(ctx.driver))
    end,
  },
  {
    id = '003_projection_version',
    name = 'Create projection version tracking',
    up = function(ctx)
      return run_all(ctx, projection_version_sql(ctx.driver))
    end,
  },
  {
    id = '004_tag_listing_index',
    name = 'Create tag listing projection',
    up = function(ctx)
      return run_all(ctx, tag_listing_index_sql(ctx.driver))
    end,
  },
  {
    id = '005_jobs',
    name = 'Create the deferred work queue',
    up = function(ctx)
      return run_all(ctx, jobs_sql(ctx.driver))
    end,
  },
}
