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
}
