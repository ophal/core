local _M = {}

function _M.last_insert_id(tbl_name, field)
  local sth, err, row

  sth, err = db_query('SELECT CURRVAL(?)', tbl_name .. '_' .. field .. '_seq')
  if err then
    return nil, err
  else
    row = sth:fetch()
    return row[1]
  end
end

function _M.limit()
  return ' OFFSET ? LIMIT ?'
end

return _M
