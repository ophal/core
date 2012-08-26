local temp_dir = seawolf.behaviour.temp_dir
local safe_open, safe_write = seawolf.fs.safe_open, seawolf.fs.safe_write
local safe_close, table_dump = seawolf.fs.safe_close, seawolf.contrib.table_dump
local time, base_path, rawset, tconcat = os.time, base_path, rawset, table.concat
local format = string.format
local session

-- Session handler
if settings.sessionapi then
  -- Look for session cookie
  local session_id = cgic.cookieString([[session-id]], 36)
  -- if session ID is not valid then set a new ID
  if not uuid.isvalid(session_id) then
    session_id = uuid.new()
    -- Print session cookie header (directly, not handled by ophal.header)
    cgic.headerCookieSetString([[session-id]], session_id,
      3*60*60, base_path, _SERVER [[SERVER_NAME]] or [[]])
  end
  -- init session table
  ophal.session = {
    id = session_id,
    file = {},
  }
  session = ophal.session
end

-- Start new or resume existing session
function session_start()
  local fh, sign, err, data, data_function, parsed

  if not session.open then
    -- Compute session filename
    session.file.name = string.format([[%s/%s.ophal]] , temp_dir(), session.id)

    -- Try to create/read session data
    fh, sign, err = safe_open(session.file.name)

    if fh then
      session.file.sign = sign
      -- Load session data
      session.open = true
      local data = fh:read([[*a]]) or [[]]
      fh:close()
      if data:byte(1) == 27 then
        error [[session: binary bytecode in session data!]]
      end

      -- Parse session data
      data_function, err = loadstring(data)
      if data_function then
        setfenv(data_function, {}) -- empty environment
        parsed, data, err = pcall(data_function)
      end
      if err then
        error(format([[session: %s]], err))
      end
      _SESSION = type(data) == [[table]] and data or {}
      session.data = _SESSION
    else
      error [[session: Can't load session data.]]
    end
  end
end

-- Reset runtime session data
local function session_close()
  safe_close(session.file.name, session.file.sign)
  session.open = false
  _SESSION = {}
end

-- Write session data and end session
function session_write_close()
  local serialized, rawdata, saved, err

  if session.open then
    rawdata = {[[return ]]}
    serialized, err = pcall(table_dump, session.data, function (s) rawset(rawdata, #rawdata + 1, s) end)
    rawdata = tconcat(rawdata)
    if serialized then
      saved, err = safe_write(session.file.name, session.file.sign, rawdata)
      if not saved then
        error [[session: Can't save session data!]]
      end
    else
      error(format([[session: %s]], err))
    end
    session_close()
  end
end

-- Destroys all data registered to a session
function session_destroy()
  session_close()
  os.remove(session.file.name)
  session.data = _SESSION -- global _SESSION is blank ATM
  session.id = nil
end
