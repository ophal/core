local DBI, dbh = require 'DBI'

function db_connect(db_id)
  if db_id == nil then db_id = 'default' end

  local connection = settings.db[db_id]

  if connection == nil then return end

  if not connection.autocommit then connection.autocommit = true end

  dbh = assert(DBI.Connect(
    connection.driver,
    connection.database,
    connection.username,
    connection.password,
    connection.host,
    connection.port
  ))

  -- commit the transaction
  dbh:autocommit(connection.autocommit)

  -- check status of the connection
  return dbh:ping()
end

function db_query(query, ...)
  if dbh == nil then return end

  -- prepare a query
  local sth = assert(dbh:prepare(query))

  -- execute select with a bind variable
  sth:execute(...)

  return sth
end

