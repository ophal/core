
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
  Input theme function.
]]
function theme.textfield(variables)
  if variables == nil then variables = {} end

  return ('<input %s %s/>'):format(
    render_attributes(variables.attributes),
    variables.value and ('value="%s" '):format(variables.value) or ''
  )
end

--[[
  Input theme function.
]]
function theme.label(variables)
  if variables == nil then variables = {} end

  return ('<label %s />%s:</label>'):format(
    render_attributes(variables.attributes),
    variables.title
  )
end

--[[
  Input theme function.
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
