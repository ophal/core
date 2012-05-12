local DBI, dbh = require [[DBI]]

function db_connect()
  local connection = settings.db.default
  dbh = assert(DBI.Connect(
    connection.driver,
    connection.database,
    connection.username,
    connection.password,
    connection.host,
    connection.port
  ))

  -- check status of the connection
  return dbh:ping()
end

function db_query(query, ...)
  -- prepare a query
  local sth = assert(dbh:prepare(query))

  -- execute select with a bind variable
  sth:execute(...)

  return sth
end

