local seawolf = require 'seawolf'.__build('fs', 'behaviour', 'variable')
local config, theme, header, _GET = settings.file or {}, theme, header, _GET
local tinsert, tconcat, lfs, env = table.insert, table.concat, lfs, env
local is_dir, is_file, add_js = seawolf.fs.is_dir, seawolf.fs.is_file, add_js
local temp_dir, empty = seawolf.behaviour.temp_dir, seawolf.variable.empty
local request_get_body, io_open, tonumber = request_get_body, io.open, tonumber
local json, files_path = require 'dkjson', settings.site.files_path
local os_remove, modules, time = os.remove, ophal.modules, os.time
local module_invoke_all, finfo = module_invoke_all, seawolf.fs.finfo
local render_attributes, format_size = render_attributes, format_size
local format_date = format_date

local debug = debug

module 'ophal.modules.file'

local user_mod, db_query, db_last_insert_id

--[[ Implements hook init().
]]
function init()
  db_query = env.db_query
  db_last_insert_id = env.db_last_insert_id
  user_mod = modules.user
end

--[[ Implements hook route().
]]
function route()
  items = {}
  items.upload = {
    page_callback = 'upload_service',
    access_callback = {module = 'user', 'access', 'upload files'},
    format = 'json',
  }
  items.merge = {
    page_callback = 'merge_service',
    access_callback = {module = 'user', 'access', 'upload files'},
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

  rs, err = db_query('SELECT * FROM file WHERE ' .. field .. ' = ?', value)
  if err then
    error(err)
  end

  entity = rs:fetch(true)

  if entity then
    entity.type = 'file'
    module_invoke_all('entity_load', entity)
  end

  return entity
end

function load(id)
  return load_by_field('id', id)
end

--[[ Implements endpoint callback: upload.
]]
function upload_service()
  local output, target, upload_id, index, upload_dir, err
  local status, output_fh, data, file

  upload_id = _GET.id
  index = _GET.index
  file = {
    filename = _GET.name,
  }

  output = {
    success = false,
  }

  if config.filedb_storage then
    if not empty(load_by_field('filename', file.filename)) then
      output.error = 'File uploaded already!'
      return output
    end
  end

  -- Make sure to have a general uploads directory
  upload_dir = ('%s/ophal_uploads'):format(temp_dir())
  if not is_dir(upload_dir) and not is_file(upload_dir) then
    status, err = lfs.mkdir(upload_dir)
    if err then
      output.error = err
    end
  end

  -- Make sure to have a dedicated folder for uploaded file parts
  if empty(err) then
    upload_dir = ('%s/%s'):format(upload_dir, upload_id)
    if not is_dir(upload_dir) and not is_file(upload_dir) then
      status, err = lfs.mkdir(upload_dir)
      if err then
        output.error = err
      end
    end
  end

  -- Write content
  if empty(err) then
    target = ('%s/%s.part'):format(upload_dir, index)
    data = request_get_body()
    output_fh, err = io_open(target, 'w+')
    if err then
      output.error = err
    else
      output_fh:write(data)
      output_fh:close()
      output.success = true
    end
  end

  return output
end

--[[ Implements endpoint callback: merge.
]]
function merge_service()
  local output, source_fh, target_fh, index, upload_id, data, err, status
  local source_path, file

  upload_id = _GET.id
  index = tonumber(_GET.index)
  file = {
    filename = _GET.name,
    filepath = ('%s/%s'):format(files_path, _GET.name),
    filesize = tonumber(_GET.size or 0),
  }

  output = {
    success = false,
  }

  target_fh, err = io_open(file.filepath, 'w+')
  if err then
    output.error = err
  elseif index > 0 then
    for i = 1, index do
      source_path = ('%s/ophal_uploads/%s/%s.part'):format(temp_dir(), upload_id, i - 1)
      source_fh = io_open(source_path, 'r')
      data, err = source_fh:read '*a'
      if err then
        output.error = err
      else
        status, err = target_fh:write(data)
        if err then
          output.error = err
          target_fh:close()
        end
        source_fh:close()
        os_remove(source_path)
      end
    end
    os_remove(('%s/ophal_uploads/%s'):format(temp_dir(), upload_id))
    target_fh:close()

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
        data, err = create(file)
        if empty(err) then
          output.id = data
        else
          output.error = err
        end
      end
    end

    output.success = true
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
      entity.id = db_last_insert_id()
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

function theme.file(variables)
  if variables == nil then variables = {} end
  if variables.attributes == nil then variables.attributes = {} end

  local id, attributes

  add_js 'libraries/uuid.js'
  add_js {type = 'settings', {
    BYTES_PER_CHUNK = config.bytes_per_chunk or (1024 * 1024),-- 1MB chunk sizes
  }}
  add_js 'modules/file/file.js'

  id = variables.id
  if empty(id) then
    id = 'upload'
  end

  return tconcat{
    ('<div class="form-upload-field" id="%s_field">'):format(id),
    theme{'hidden', attributes = {class = 'form-upload-entity-id'}},
    ('<input %s type="file" class="form-upload-file">'):format(id, id, render_attributes(variables.attributes)),
    theme{'button', value = 'upload', attributes = {class = 'form-upload-button'}}, '<br />',
    '<progress class="form-upload-progress" value="0" max="100"></progress>',
    '<div class="form-upload-status">Ready to upload</div>',
    '</div>'
  }
end

function theme.file_info(variables)
  local entity = variables.file

  return tconcat{
    '<div class="file-info">',
    '<span class="file-size">', entity.filename, '</span>',
    ' - ',
    '<span class="file-size">', format_size(entity.filesize), '</span>',
    ' - ',
    '<span class="file-date">', format_date(entity.timestamp), '</span>',
    '</div>',
  }
end
