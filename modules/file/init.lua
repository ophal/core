local conf, theme, header, _GET = settings.file or {}, theme, header, _GET
local tinsert, tconcat, lfs = table.insert, table.concat, lfs
local is_dir, is_file = seawolf.fs.is_dir, seawolf.fs.is_file
local temp_dir, empty = seawolf.behaviour.temp_dir, seawolf.variable.empty
local request_get_body, io_open, tonumber = request_get_body, io.open, tonumber
local json, files_path = require 'dkjson', settings.site.files_path
local os_remove = os.remove

module 'ophal.modules.file'

function menu()
  items = {}
  items.upload = {
    page_callback = 'upload',
  }
  items.merge = {
    page_callback = 'merge',
  }
  return items
end

function upload()
  local output, target, fileid, filename, filesize, index, upload_dir, err
  local status, output_fh, data

  header('content-type', 'text/plain')

  fileid = _GET.id
  filename = _GET.name
  filesize = _GET.size
  index = _GET.index

  output = {
    success = false,
  }

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
    upload_dir = ('%s/%s'):format(upload_dir, fileid)
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
  output = json.encode(output)

  theme.html = function () return output or '' end
end

function merge()
  local output, source_fh, target_fh, index, filename, fileid, data, err, status
  local source_path

  header('content-type', 'application/json; charset=utf-8')

  filename = _GET.name
  fileid = _GET.id
  index = tonumber(_GET.index)

  output = {
    success = false,
  }

  target_fh, err = io_open(('%s/%s'):format(files_path, _GET.name), 'w+')
  if err then
    output.error = err
  elseif index > 0 then
    for i = 1, index do
      source_path = ('%s/ophal_uploads/%s/%s.part'):format(temp_dir(), fileid, i - 1)
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
    os_remove(('%s/ophal_uploads/%s'):format(temp_dir(), fileid))
    target_fh:close()
    output.success = true
  end
  output = json.encode(output)

  theme.html = function () return output or '' end
end