local empty, tinsert, tconcat = seawolf.variable.empty, table.insert, table.concat

--[[
  Form theme function.
]]
function theme.form(variables)
  if variables == nil then variables = {} end

  local default_options = {
    ['accept-charset'] = 'UTF-8',
    method = 'get',
  }

  return ('<form %s action="%s">%s</form>'):format(
    render_attributes(variables.attributes, default_options),
    variables.action,
    variables.elements
  )
end

--[[
  Textfield theme function.
]]
function theme.textfield(variables)
  if variables == nil then variables = {} end

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

  return ('<textarea %s>%s</textarea>'):format(
    render_attributes(variables.attributes),
    variables.value and variables.value or ''
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

  local elements, choices, attributes

  elements = variables.elements
  variables.elements = nil

  choices = variables.choices
  variables.choices = nil

  variables.class['form-select'] = true
  variables.class = render_classes(variables.class)

  attributes = render_attributes(variables)
  if empty(attributes) then attributes = nil end
  return ('<select%s%s>%s</select>'):format(
    attributes ~= nil and ' ' or '',
    attributes or '',
    theme{'select_options', elements = elements, choices = choices}
  )
end

--[[
  Converts a select element's options array into HTML.
]]
function theme.select_options(variables)
  if variables == nil then variables = {elements = {}, choices = {}} end
  if variables.elements == nil then variables.elements = {} end
  if variables.choices == nil then variables.choices = {} end

  local elements, choices, output = variables.elements, variables.choices, {}
  local selected
  for k, v in pairs(elements) do
    selected = not empty(choices[k]) and ' selected="selected"' or ''
    tinsert(output, ('<option%s>%s</option>'):format(selected, v))
  end

  return tconcat(output)
end
