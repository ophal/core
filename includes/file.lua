local empty, tconcat = seawolf.variable.empty, table.concat

function theme.file(variables)
  if variables == nil then variables = {} end
  if variables.attributes == nil then variables.attributes = {} end

  local id, attributes

  id = variables.id
  if empty(id) then
    id = 'upload'
  end

  return tconcat{
    ('<div class="form-upload-field" id="%s_file">'):format(id),
    ('<input %s type="file" class="form-upload-file">'):format(id, id, render_attributes(variables.attributes)),
    theme{'button', value = 'upload', attributes = {id = id .. '_btn', class = 'form-upload-button'}}, '<br />',
    '<progress class="form-upload-progress" value="0" max="100"></progress>',
    '<div class="form-upload-percent">Waiting...</div>',
    '</div>'
  }
end
