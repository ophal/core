
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
