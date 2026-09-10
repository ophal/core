local seawolf = require 'seawolf'.__build('fs', 'behaviour', 'variable')

-- The same guard `modules/entity` carries: bootstrap loads `includes/escape.lua`
-- before modules, but a unit test that loads this file on its own does not.
if type(html_escape) ~= 'function' then
  pcall(require, 'includes.escape')
end
local config, theme, header = settings.file or {}, theme, header
local tinsert, tconcat, lfs, env = table.insert, table.concat, lfs, env
local fs_path = require 'includes.fs.path'
local is_dir, is_file, add_js = fs_path.is_dir, fs_path.is_file, add_js
local empty = require('includes.util').empty
local request_get_body, io_open, tonumber, type = request_get_body, io.open, tonumber, type
local request_get_body_file = request_get_body_file
local files_path = settings.site.files_path
require 'modules.file.statements'

local os_remove, os_rename, modules, time = os.remove, os.rename, ophal.modules, os.time
local module_invoke_all = module_invoke_all
--[[ libmagic's binding, or nil.

  `seawolf.fs` exposed this as `finfo` when `magic` was installable and left it
  absent otherwise, so it is optional and always has been -- the
  `type(finfo) ~= 'table'` guard at the one call site is what makes it so, and
  an upload on a host without libmagic finishes with a null `filemime` rather
  than failing. Required directly now, because there is no reason for a
  filesystem library to be the thing that decides whether this is installed.
]]
local finfo

do
  local found, magic = pcall(require, 'magic')

  finfo = found and magic or nil
end
local render_attributes, format_size = render_attributes, format_size
local format_date = format_date
local csrf_validate_request, csrf_denied = csrf_validate_request, csrf_denied
-- Captured at load time like the line above, and for the same reason: the
-- `module()` call below replaces this file's environment, so a global looked up
-- afterwards resolves to nil.
local safe_path_segment, unsafe_path_denied = safe_path_segment, unsafe_path_denied
--[[ Captured for the same reason, and it was missing.

  `theme.file` and `theme.file_info` rendered `entity.filename` straight into
  HTML. A filename is attacker-chosen -- it arrives as `?name=` on `file/merge`
  -- and the only guard on it is `safe_path_segment`, which is a *path* check:
  it rejects separators, NUL and control bytes, and has no opinion about `<`.
  So `<img src=x onerror=...>` is a valid filename by that rule, and every
  viewer of the file field ran it. Stored XSS, and the only unescaped output in
  the codebase -- `l()`, `page_set_title()` and the form and menu themes all
  escape already.
]]
local html_escape, html_attr_escape = html_escape, html_attr_escape

local debug = debug
-- Required rather than captured from a global: this is a module of its own, and
-- `module()` below would put the local out of reach of nothing -- the require
-- result is an upvalue, which survives the environment swap.
local fs_stats = require 'includes.fs.stats'
local jobs = require 'includes.jobs'

module 'ophal.modules.file'

local user_mod, db_connection

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
  -- Captured per request, not at load: a connection object belongs to the
  -- request that asked for it and raises at its next use once released.
  db_connection = env.db_connection
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

  local entity

  if field == 'id' then
    value = tonumber(value or 0)
  end

  entity = db_connection()
    :with('file.load_by_field', field)
    :run(value)
    :fetch(true)

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

  -- The fast path, and the one that carries the common case: a chunk large
  -- enough that nginx already buffered it to disk, arriving when there is
  -- nothing staged yet. The bytes are on the filesystem and their destination
  -- is the filesystem, so the file is renamed into place and never enters Lua.
  -- A single-request upload is exactly this case, which is what makes it worth
  -- having -- it is the whole file.
  --
  -- Only when nothing is staged: a rename over a partly assembled upload would
  -- discard every chunk already written. Everything else falls through to the
  -- seek-and-write below, including a small body, which nginx keeps in memory
  -- and which therefore has no file to rename.
  local body_file = index == 0 and request_get_body_file() or nil

  if body_file and lfs.attributes(target, 'size') == nil then
    status, err = os_rename(body_file, target)
    fs_stats.record('rename', nil, target, 'media')

    if status then
      output.success = true
      return output
    end

    -- A rename across filesystems fails, which is what happens when nginx's
    -- `client_body_temp_path` is on a different device from `files_path`. That
    -- is a configuration a site can have and must not break on, so the copy
    -- below is still the answer; it is only slower.
  end

  data = request_get_body()

  output_fh = io_open(target, 'r+')
  fs_stats.record('open', nil, target, 'media')

  if not output_fh then
    output_fh, err = io_open(target, 'w+')
    fs_stats.record('open', nil, target, 'media')
  end

  if not output_fh then
    output.error = err or ('cannot open upload: %s'):format(target)
    return output
  end

  output_fh:seek('set', index * bytes_per_chunk())
  output_fh:write(data)
  fs_stats.record('write', #data, target, 'media')
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
    fs_stats.record('remove', nil, staged, 'media')
    output.error = ('upload is %s bytes, expected %s'):format(staged_size, file.filesize)
    return output
  end

  status, err = os_rename(staged, file.filepath)
  fs_stats.record('rename', nil, file.filepath, 'media')

  if not status then
    output.error = err or 'cannot finalize upload'
    return output
  end

  -- Register the file into the database.
  --
  -- The row is written here and the type inspection is not. The INSERT is one
  -- bounded statement and the client needs the id it returns -- `theme.file`
  -- renders it into a hidden field, so deferring it would break the upload
  -- form. Reading the file to identify it is the unbounded half: libmagic opens
  -- the finished file and reads it, on the request, after the bytes have
  -- already been written once. That is what moves to the queue.
  if config.filedb_storage then
    -- 1 rather than true: see the note in `modules/content`'s create(). The
    -- column is `smallint` on PostgreSQL, which refuses a bound boolean.
    file.status = 1
    file.timestamp = time()
    file.filesize = staged_size

    data, err = create(file)
    if empty(err) then
      output.id = data
      -- `filemime` is null until the queue is drained. Nothing enforces on it,
      -- and a null there is honest: the type is not known yet. A site with no
      -- cron gets a file it can serve and a column it never fills, which is the
      -- same trade every other deferred consequence makes.
      jobs.enqueue('file_post_process', ('file:%s'):format(data), {id = data})
    else
      output.error = err
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
  local rs

  if entity.type == nil then entity.type = 'file' end

  rs = (function(id, ...)
    local db = db_connection()

    if id then
      return db:run('file.create_with_id', id, ...)
    end

    local created = db:run('file.create', ...)

    entity.id = db:last_insert_id('file', 'id')

    return created
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

  module_invoke_all('entity_after_save', entity)

  return entity.id
end

function update(entity)
  local rs = db_connection():run('file.update',
      entity.user_id,
      entity.filename,
      entity.filepath,
      entity.filemime,
      entity.filesize,
      entity.status,
      entity.timestamp,
      entity.id
  )

  module_invoke_all('entity_after_save', entity)

  return rs
end

function delete(entity)
  local rs = db_connection():run('file.delete', entity.id)

  if entity.filepath then
    os_remove(entity.filepath)
    fs_stats.record('remove', nil, entity.filepath, 'media')
  end

  module_invoke_all('entity_after_delete', entity)

  return rs
end

--[[ Identify an uploaded file's type, off the request that uploaded it.

  Registered at load time, the way `modules/system` registers
  `projection_rebuild`, so the drain can find it from the kind alone.

  The two "nothing to do" cases return true, not false. `run_pending()` reads a
  false return as "handler declined the job" and sends it back to the queue with
  a backoff, so false is for work that should be tried again. A file that is no
  longer there and a host with no libmagic are both settled answers -- retrying
  either one four more times before giving up achieves nothing.
]]
jobs.register('file_post_process', function(payload)
  local id = (payload or {}).id
  local entity = id and load(id)

  -- Deleted between finalize and the drain. An ordinary race, and settled.
  if empty(entity) or empty(entity.filepath) then
    return true
  end

  -- libmagic is an optional binding, not a dependency. Where it is absent there
  -- is no type to record and nothing to retry, so this completes rather than
  -- failing: a queue that kept retrying an identification the host cannot
  -- perform would burn `max_attempts` on every upload and leave a failed row
  -- behind for each one.
  --
  -- Before this ran on the queue it ran inline, which meant a host without
  -- libmagic raised from inside `file/merge` and the upload failed outright
  -- even though the bytes were safely on disk. Deferring it is what turns a
  -- missing optional binding into a null column.
  if type(finfo) ~= 'table' then
    return true
  end

  local mime = finfo.open(finfo.MIME_TYPE, finfo.NO_CHECK_COMPRESS)

  if mime:load() ~= 0 then
    return nil, mime:error()
  end

  entity.filemime = mime:file(entity.filepath)
  fs_stats.record('read', nil, entity.filepath, 'media')

  local _, err = update(entity)

  if err then
    return nil, err
  end

  return true
end)

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
      '<strong>Current file:</strong> ', html_escape(entity.filename), '<br />',
      '<strong>Uploaded on: </strong> ', format_date(entity.timestamp),
    }
  end

  return tconcat{
    ('<div class="form-upload-field" id="%s_field">'):format(id),
    theme{'hidden', attributes = {class = 'form-upload-entity-id'}, value = entity.id},
    '<p>', file_info, '</p>',
    --[[ One `%s` and three arguments, so `format` filled the slot with `id` and
      discarded the other two: the field rendered `<input upload type="file">`,
      a bare bogus attribute, and the caller's attributes never appeared at all.
      `modules/file/file.js` selects on `.form-upload-file` rather than on the
      id, which is why nothing looked broken.
    ]]
    ('<input id="%s_file" type="file" class="form-upload-file" %s>'):format(
      html_attr_escape(id), render_attributes(variables.attributes)),
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
    '<span class="file-size">', html_escape(entity.filename or ''), '</span>',
    ' - ',
    '<span class="file-size">', format_size(entity.filesize), '</span>',
    ' - ',
    '<span class="file-date">', format_date(entity.timestamp), '</span>',
    '</div>',
  }
end
