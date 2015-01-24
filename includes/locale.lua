local data = settings.locale or {}

--[[ Attempt ot translate given text.
]]
function t(text)
  return data[text] or text
end
