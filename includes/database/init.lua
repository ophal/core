dbh = {} -- Database handlers

local DBI, db_id, drivers = require 'DBI', 'default', {}

function db_set_db_id(id)
  db_id = id
end

function db_connect()
  local err, driver
  local connection = settings.db[db_id]

  if connection == nil then return end

  if not connection.autocommit then connection.autocommit = true end

  dbh[db_id], err = DBI.Connect(
    connection.driver,
    connection.database,
    connection.username,
    connection.password,
    connection.host,
    connection.port
  )

  if err then
    error(err)
  end

  drivers[db_id] = require('includes.database.' .. connection.driver:lower())

  -- commit the transaction
  dbh[db_id]:autocommit(connection.autocommit)

  -- check status of the connection
  return dbh[db_id]:ping()
end

function db_query(query, ...)
  local err, sth

  if dbh[db_id] == nil then
    error 'No database connection'
  end

  -- prepare a query
  sth = assert(dbh[db_id]:prepare(query))

  -- execute select with a bind variable
  _, err = sth:execute(...)

  if err then
    error(err)
  end

  return sth
end

function db_last_insert_id(...)
  return drivers[db_id].last_insert_id(...)
end

function db_limit()
  return drivers[db_id].limit()
end
