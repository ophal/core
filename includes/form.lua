local empty, tinsert, os_date = seawolf.variable.empty, table.insert, os.date
local tsort, tconcat, os_time = table.sort, table.concat, os.time

--[[
  Form theme function.
]]
function theme.form(variables)
  if variables == nil then variables = {} end

  local default_options = {
    ['accept-charset'] = 'UTF-8',
    method = 'get',
    action = variables.action,
  }

  module_invoke_all('form_alter', variables)

  return ('<form %s>%s</form>'):format(
    render_attributes(variables.attributes, default_options),
    theme{'elements', elements = variables.elements}
  )
end

--[[
  Form elements theme function.
]]
function theme.elements(variables)
  if variables == nil then variables = {} end

  local elements
  local output = {'<table>'}
  local row = '<tr><td class="field-name" valign="top">%s:</td><td>%s</td></tr>'
  local row_nl = '<tr><td colspan="2" align="right">%s</td></tr>'

  elements = variables.elements or {}
  variables.elements = nil

  tsort(elements, function(a, b) return (b.weight or 10) > (a.weight or 10) end)

  for _, v in pairs(elements) do
    if v[1] == 'hidden' then
      tinsert(output, theme(v))
    elseif v.title then
      tinsert(output, row:format(v.title or '', theme(v)))
    else
      tinsert(output, row_nl:format(theme(v)))
    end
  end

  tinsert(output, '</table>')

  return tconcat(output)
end

--[[
  Textfield theme function.
]]
function theme.textfield(variables)
  if variables == nil then variables = {} end

  if variables.attributes == nil then
    variables.attributes = {}
  end
  if variables.attributes.type == nil then
    variables.attributes.type = 'text'
  end

  return ('<input %s %s/>'):format(
    render_attributes(variables.attributes),
    variables.value and ('value="%s" '):format(variables.value) or ''
  )
end

--[[
  Label theme function.
]]
function theme.label(variables)
  if variables == nil then variables = {} end

  return ('<label %s />%s:</label>'):format(
    render_attributes(variables.attributes),
    variables.title
  )
end

--[[
  Button theme function.
]]
function theme.button(variables)
  if variables == nil then variables = {} end

  return ('<input %s type="button" value="%s" />'):format(
    render_attributes(variables.attributes),
    variables.value
  )
end

--[[
  Submit button theme function.
]]
function theme.submit(variables)
  if variables == nil then variables = {} end

  return ('<input %s type="submit" value="%s" />'):format(
    render_attributes(variables.attributes),
    variables.value
  )
end

--[[
  Text area theme function.
]]
function theme.textarea(variables)
  if variables == nil then variables = {} end

  return ('<textarea %s>%s</textarea>%s'):format(
    render_attributes(variables.attributes),
    variables.value and variables.value or '',
    variables.description and ('<div class="form-element-description">%s</div>'):format(variables.description or '') or ''
  )
end

--[[
  Hidden value theme function.
]]
function theme.hidden(variables)
  if variables == nil then variables = {} end

  return ('<input type="hidden" %s %s/>'):format(
    render_attributes(variables.attributes),
    variables.value and ('value="%s" '):format(variables.value) or ''
  )
end

--[[
  Returns HTML for a select element.
]]
function theme.select(variables)
  if variables == nil then variables = {} end
  if variables.class == nil then variables.class = {} end

  local options, order, choices, attributes

  options = variables.options
  variables.options = nil

  choices = variables.choices
  variables.choices = nil

  order = variables.order
  variables.order = nil

  variables.class['form-select'] = true
  variables.class = render_classes(variables.class)

  return ('<select %s>%s</select>'):format(
    render_attributes(variables.attributes),
    theme{'select_options', options = options, order = order, choices = choices}
  )
end

function theme.select_option(variables)
  local selected = variables.selected and ' selected="selected"' or ''
  return ('<option value="%s"%s>%s</option>'):format(variables.key, selected, variables.value)
end

--[[
  Converts a select element's options array into HTML.
]]
function theme.select_options(variables)
  if variables == nil then variables = {options = {}, choices = {}} end
  if variables.options == nil then variables.options = {} end
  if variables.choices == nil then variables.choices = {} end

  local options, order, choices, output = variables.options, variables.order, variables.choices, {}

  if not empty(order) then
    for k, key in pairs(order) do
      local selected = not empty(choices[key])
      tinsert(output, theme{'select_option', key = key, value = options[key], selected = selected})
    end
  else
    for k, v in pairs(options) do
      local selected = not empty(choices[k])
      tinsert(output, theme{'select_option', key = k, value = v, selected = selected})
    end
  end

  return tconcat(output)
end

function theme.checkbox(variables)
  if variables == nil then variables = {} end
  if variables.attributes == nil then variables.attributes = {} end

  variables.attributes.type = 'checkbox'
  variables.attributes.value = 1

  -- Unchecked checkbox has #value of integer 0.
  if not empty(variables.value)  then
    variables.attributes.checked = 'checked'
  end

  return ('<input %s />'):format(render_attributes(variables.attributes))
end

function theme.markup(variables)
  if variables == nil then variables = {} end

  return variables.value
end

function theme.progress(variables)
  if variables == nil then variables = {} end

  local value = variables.value or 0

  return ('<div class="progress" %s><span class="meter" style="width: %s%%"></span></div>'):format(
    render_attributes(variables.attributes),
    value
  )
end

function form_date_to_unixtime(date_string)
  local year, month, day, hour, min, sec = date_string:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")

  return os.time{
    year = year,
    month = month,
    day = day,
    hour = hour,
    min = min,
    sec = sec
  }
end

function theme.date(variables)
  if variables == nil then variables = {} end

  local offset = os_time() - os_time(os_date [[!*t]])
  local text_value = os_date([[%Y-%m-%d %H:%M:%S]], variables.value)
  local offset_string = offset > -1 and os_date([[!+%H:%M]], offset) or os_date([[!-%H:%M]], offset*-1)

  return ([[%s
  <br />
  <small>Timezone: UTC %s</small>]]):format(
    theme{'textfield', value = text_value, attributes = variables.attributes},
    offset_string
  )
end
