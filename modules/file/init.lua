local seawolf = require 'seawolf'.__build('fs', 'behaviour', 'variable')
local config, theme, header = settings.file or {}, theme, header
local tinsert, tconcat, lfs, env = table.insert, table.concat, lfs, env
local is_dir, is_file, add_js = seawolf.fs.is_dir, seawolf.fs.is_file, add_js
local temp_dir, empty = seawolf.behaviour.temp_dir, seawolf.variable.empty
local request_get_body, io_open, tonumber = request_get_body, io.open, tonumber
local json, files_path = require 'dkjson', settings.site.files_path
local os_remove, os_rename, modules, time = os.remove, os.rename, ophal.modules, os.time
local module_invoke_all, finfo = module_invoke_all, seawolf.fs.finfo
local render_attributes, format_size = render_attributes, format_size
local format_date = format_date
local csrf_validate_request, csrf_denied = csrf_validate_request, csrf_denied
-- Captured at load time like the line above, and for the same reason: the
-- `module()` call below replaces this file's environment, so a global looked up
-- afterwards resolves to nil.
local safe_path_segment, unsafe_path_denied = safe_path_segment, unsafe_path_denied

local debug = debug
-- Required rather than captured from a global: this is a module of its own, and
-- `module()` below would put the local out of reach of nothing -- the require
-- result is an upvalue, which survives the environment swap.
local fs_stats = require 'includes.fs.stats'

module 'ophal.modules.file'

local user_mod, db_query, db_field, db_last_insert_id

--[[ A chunk index, or nil when it is not one.

  It reaches `io.open` as a path segment, so "looks numeric" is not enough --
  `tonumber` accepts `0x10`, ` 3 ` and `1e2`, and a float would interpolate as
  `1.5`. Only a non-negative integer is a chunk.
]]
--[[ This request's query arguments.

  Read through `env` on every call rather than captured as a local at load time.
  `ophal_request_reset()` rebinds `_GET` to a *new* table for each request, so a
  load-time capture keeps pointing at whatever the worker's first request
  carried. That is invisible under `lua_code_cache off`, which reloads this file
  every request, and permanent under the `lua_code_cache on` that
  `nginx.ophal.conf` ships -- which is to say it is broken exactly in
  production. `env` is the jailed environment itself and `ophal_request_reset()`
  assigns into it, so indexing it here is what makes the read current.
]]
local function query_args()
  return env._GET or {}
end

local DEFAULT_BYTES_PER_CHUNK = 1024 * 1024

--[[ The chunk size, which is the server's to decide.

  `theme.file` publishes this same value to the browser through `add_js`, so the
  client slices to whatever is configured here. That is what lets the server
  compute a chunk's offset from the index the client sends, instead of trusting
  the client to say where its bytes belong.
]]
local function bytes_per_chunk()
  return tonumber(config.bytes_per_chunk) or DEFAULT_BYTES_PER_CHUNK
end

-- Where an upload is assembled before it has a name. Dotted, and separate from
-- the directory files are served out of, so a half-written upload is never
-- reachable over HTTP -- `nginx.ophal.conf` serves several extensions straight
-- off the document root, and `files_path` is under it.
local function staging_path(upload_id)
  return ('%s/.incoming/%s'):format(files_path, upload_id)
end

local function upload_index(value)
  local number = tonumber(value)

  if number == nil or number < 0 or number % 1 ~= 0 then
    return nil
  end

  return number
end

local function ensure_dir(path)
  local status, err

  if is_dir(path) then
    return true
  end

  if is_file(path) then
    return nil, ('path exists and is not a directory: %s'):format(path)
  end

  status, err = lfs.mkdir(path)
  if not status then
    return nil, err
  end

  return true
end

--[[ Implements hook init().
]]
function init()
  db_query = env.db_query
  db_field = env.db_field
  db_last_insert_id = env.db_last_insert_id
  user_mod = modules.user
end

--[[ Implements hook route().
]]
function route()
  items = {}
  items['file/upload'] = {
    page_callback = 'upload_service',
    access_callback = {module = 'user', 'access', 'upload files'},
    format = 'json',
  }
  items['file/merge'] = {
    page_callback = 'merge_service',
    access_callback = {module = 'user', 'access', 'upload files'},
    format = 'json',
  }
  items['file/delete'] = {
    page_callback = 'delete_service',
    access_callback = {module = 'user', 'access', 'delete own files'},
    format = 'json',
  }
  return items
end

function load_by_field(field, value)
  if field == nil then field = 'id' end

  local rs, err

  if field == 'id' then
    value = tonumber(value or 0)
  end

  local sql = ('SELECT * FROM file WHERE %s = ?'):format(db_field('file', field))
  rs, err = db_query(sql, value)
  if err then
    error(err)
  end

  entity = rs:fetch(true)

  if entity then
    entity.type = 'file'
    module_invoke_all('entity_load', entity)
  end

  return entity or {}
end

function load(id)
  return load_by_field('id', id)
end

--[[ Implements endpoint callback: upload.
]]
function upload_service()
  local output, target, upload_id, index, upload_dir, err
  local status, output_fh, data, file

  local args = query_args()

  upload_id = args.id
  index = upload_index(args.index)
  file = {
    filename = args.name,
  }

  output = {
    success = false,
  }

  if not csrf_validate_request() then
    csrf_denied(output)
    return output
  end

  -- Both of these are interpolated into a path below. Checked after CSRF so a
  -- forged request is refused for being forged, and before anything touches the
  -- filesystem.
  if not safe_path_segment(upload_id) then
    unsafe_path_denied(output, 'id')
    return output
  end

  if index == nil then
    unsafe_path_denied(output, 'index')
    return output
  end

  if config.filedb_storage then
    if not empty(load_by_field('filename', file.filename)) then
      output.error = 'File uploaded already!'
      return output
    end
  end

  status, err = ensure_dir(('%s/.incoming'):format(files_path))
  if not status then
    output.error = err
    return output
  end

  -- The chunk goes straight to its final offset in one file, rather than
  -- becoming `<index>.part` for a later pass to read back and concatenate. That
  -- pass was the phase's whole cost: it moved every byte through Lua a second
  -- time and held a chunk of them in a Lua string while it did.
  --
  -- `r+` before `w+` so a retried chunk rewrites its own bytes instead of
  -- truncating everything already assembled. `w+` is only for the chunk that
  -- finds no file yet, which is whichever one arrives first -- the offset is
  -- absolute, so chunks may arrive in any order.
  target = staging_path(upload_id)
  data = request_get_body()

  output_fh = io_open(target, 'r+')
  fs_stats.record('open', nil, target)

  if not output_fh then
    output_fh, err = io_open(target, 'w+')
    fs_stats.record('open', nil, target)
  end

  if not output_fh then
    output.error = err or ('cannot open upload: %s'):format(target)
    return output
  end

  output_fh:seek('set', index * bytes_per_chunk())
  output_fh:write(data)
  fs_stats.record('write', #data, target)
  output_fh:close()
  output.success = true

  return output
end

--[[ Implements endpoint callback: merge.
]]
function merge_service()
  local output, source_fh, target_fh, index, upload_id, data, err, status
  local source_path, file

  local args = query_args()

  upload_id = args.id
  index = upload_index(args.index)

  output = {
    success = false,
  }

  if not csrf_validate_request() then
    csrf_denied(output)
    return output
  end

  -- `filename` is the one that matters most: it is joined to `files_path`,
  -- which lives under the document root nginx serves static extensions from
  -- directly, so an unchecked `../` here is a write into the served tree for
  -- anyone holding `upload files`. The entity is built after the check rather
  -- than before it so that no path is constructed from a value that has not
  -- been accepted.
  if not safe_path_segment(args.name) then
    unsafe_path_denied(output, 'name')
    return output
  end

  if not safe_path_segment(upload_id) then
    unsafe_path_denied(output, 'id')
    return output
  end

  if index == nil then
    unsafe_path_denied(output, 'index')
    return output
  end

  file = {
    filename = args.name,
    filepath = ('%s/%s'):format(files_path, args.name),
    filesize = tonumber(args.size or 0),
  }

  -- Finalize. There is nothing to merge any more: the chunks were written to
  -- their offsets as they arrived, so the assembled file already exists and all
  -- that is left is to check it is the size the client said and give it its
  -- name. The rename is one syscall, moves no bytes through Lua, and is atomic
  -- within a filesystem -- which is also what makes the file appear under
  -- `files_path` complete or not at all, rather than growing in public while
  -- the upload runs.
  local staged = staging_path(upload_id)
  local staged_size = lfs.attributes(staged, 'size')

  if staged_size == nil then
    output.error = ('no upload to finalize: %s'):format(upload_id)
    return output
  end

  -- The declared size is checked against what actually landed, because a
  -- missing chunk is otherwise invisible: a seek past the end leaves a hole
  -- that reads back as NULs, so an upload short one chunk would finalize into
  -- a plausible-looking file rather than an error.
  if file.filesize > 0 and staged_size ~= file.filesize then
    os_remove(staged)
    fs_stats.record('remove', nil, staged)
    output.error = ('upload is %s bytes, expected %s'):format(staged_size, file.filesize)
    return output
  end

  status, err = os_rename(staged, file.filepath)
  fs_stats.record('rename', nil, file.filepath)

  if not status then
    output.error = err or 'cannot finalize upload'
    return output
  end

  -- Register the file into the database
  if config.filedb_storage then
    local mime = finfo.open(finfo.MIME_TYPE, finfo.NO_CHECK_COMPRESS)
    local rc = mime:load()
    if rc ~= 0 then
      output.error = mime:error()
    else
      file.filemime = mime:file(file.filepath)
      file.status = true
      file.timestamp = time()
      file.filesize = staged_size
      data, err = create(file)
      if empty(err) then
        output.id = data
      else
        output.error = err
      end
    end
  end

  output.success = true

  return output
end

function delete_service()
  local rs, err
  local file_id = query_args().id
  local output = {success = false}

  if not csrf_validate_request() then
    csrf_denied(output)
    return output
  end

  if not empty(file_id) then
    entity = load(file_id)
    rs, err = delete(entity)
    if empty(err) then
      output.success = true
    else
      output.error = err
    end
  end

  return output
end

function create(entity)
  local rs, err

  if entity.type == nil then entity.type = 'file' end

  rs, err = (function(id, ...)
    if id then
      return db_query([[
INSERT INTO file(id, user_id, filename, filepath, filemime, filesize, status, timestamp)
VALUES(?, ?, ?, ?, ?, ?, ?, ?)]], id, ...)
    else
      local rs1, rs2 = db_query([[
INSERT INTO file(user_id, filename, filepath, filemime, filesize, status, timestamp)
VALUES(?, ?, ?, ?, ?, ?, ?)]], ...)
      entity.id = db_last_insert_id('file', 'id')
      return rs1, rs2
    end
  end)(
    entity.id,
    entity.user_id or user_mod.current().id,
    entity.filename,
    entity.filepath,
    entity.filemime,
    entity.filesize,
    entity.status,
    entity.timestamp
  )

  if not err then
    module_invoke_all('entity_after_save', entity)
  end

  return entity.id, err
end

function update(entity)
  local rs, err
  rs, err = db_query('UPDATE file SET user_id = ?, filename = ?, filepath = ?, filemime = ?, filesize = ?, status = ?, timestamp = ? WHERE id = ?',
      entity.user_id,
      entity.filename,
      entity.filepath,
      entity.filemime,
      entity.filesize,
      entity.status,
      entity.timestamp,
      entity.id
  )
  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return rs, err
end

function delete(entity)
  local rs, err

  rs, err = db_query('DELETE FROM file WHERE id = ?', entity.id)

  if not err then
    if entity.filepath then
      os_remove(entity.filepath)
      fs_stats.record('remove', nil, entity.filepath)
    end
    module_invoke_all('entity_after_delete', entity)
  end

  return rs, err
end

function handle_upload(src, tgt)
  local src_id = src.entity[src.field]
  local tgt_id = tgt.entity[tgt.field]

  if empty(tgt_id) then
    -- Keep current value
    tgt.entity[tgt.field] = src_id
  elseif tgt_id == 'deleted' then
    tgt.entity[tgt.field] = nil
  end
end

function theme.file(variables)
  if variables == nil then variables = {} end
  if variables.attributes == nil then variables.attributes = {} end

  local id, attributes, entity
  local file_info, delete_button = '', ''

  add_js 'libraries/uuid.js'
  add_js {type = 'settings', {
    BYTES_PER_CHUNK = config.bytes_per_chunk or (1024 * 1024),-- 1MB chunk sizes
  }}
  add_js 'modules/file/file.js'

  id = variables.id
  if empty(id) then
    id = 'upload'
  end

  entity = variables.entity or {}
  if not empty(entity) then
    file_info = tconcat{
      '<strong>Current file:</strong> ', entity.filename, '<br />',
      '<strong>Uploaded on: </strong> ', format_date(entity.timestamp),
    }
  end

  return tconcat{
    ('<div class="form-upload-field" id="%s_field">'):format(id),
    theme{'hidden', attributes = {class = 'form-upload-entity-id'}, value = entity.id},
    '<p>', file_info, '</p>',
    ('<input %s type="file" class="form-upload-file">'):format(id, id, render_attributes(variables.attributes)),
    theme{'button', value = 'upload', attributes = {class = 'form-upload-button'}},
    theme{'button', value = 'delete', attributes = {class = 'form-delete-button'}},
    '<br />',
    '<progress class="form-upload-progress" value="0" max="100"></progress>',
    '<div class="form-upload-status">Ready to upload</div>',
    '</div>'
  }
end

function theme.file_info(variables)
  local entity = variables.file

  return tconcat{
    '<div class="file-info">',
    '<span class="file-size">', entity.filename or '', '</span>',
    ' - ',
    '<span class="file-size">', format_size(entity.filesize), '</span>',
    ' - ',
    '<span class="file-date">', format_date(entity.timestamp), '</span>',
    '</div>',
  }
end
