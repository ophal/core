local _M = {}

function _M.last_insert_id(tbl_name)
  local sth, err, row

  sth, err = db_query('SELECT last_insert_rowid()')
  if err then
    return nil, err
  else
    row = sth:fetch()
    return row[1]
  end
end

function _M.limit()
  return ' LIMIT ?, ?'
end

return _M
