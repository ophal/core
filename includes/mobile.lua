local _SERVER, pairs, rawget = _SERVER, pairs, rawget
local strpos, empty = seawolf.text.strpos, seawolf.variable.empty
local substr = seawolf.text.substr
local tconcat, tinsert = table.concat, table.insert
local preg = require 'seawolf.text.preg'

--[[
  Ophal mobile detect library.

  Based on PHP's Mobile_Detect - (c) Serban Ghita 2009-2012
  Version 2.0.7 - vic.stanciu@gmail.com, 3rd May 2012
  Site:   https://code.google.com/p/php-mobile-detect/
]]
local detect = {}
mobile.detect = detect

local detectionRules = {}
local userAgent = ''
local accept = ''
-- Assume the visitor has a desktop environment
local isMobile_ = false
local isTablet_ = false
local phoneDeviceName = ''
local tabletDevicename = ''
local operatingSystemName = ''
local userAgentName = ''

-- List of mobile devices (phones)
local phoneDevices = {     
  iPhone = '(iPhone.*Mobile|iPod|iTunes)',
  BlackBerry = 'BlackBerry|rim[0-9]+',
  HTC = 'HTC|HTC.*(6800|8100|8900|A7272|S510e|C110e|Legend|Desire|T8282)|APX515CKT|Qtek9090',
  Nexus = 'Nexus One|Nexus S',
  DellStreak = 'Dell Streak',
  Motorola = '\bDroid\b.*Build|HRI39|MOT-|A1260|A1680|A555|A853|A855|A953|A955|A956|Motorola.*ELECTRIFY|Motorola.*i1|i867|i940|MB200|MB300|MB501|MB502|MB508|MB511|MB520|MB525|MB526|MB611|MB612|MB632|MB810|MB855|MB860|MB861|MB865|MB870|ME501|ME502|ME511|ME525|ME600|ME632|ME722|ME811|ME860|ME863|ME865|MT620|MT710|MT716|MT720|MT810|MT870|MT917|Motorola.*TITANIUM|WX435|WX445|XT300|XT301|XT311|XT316|XT317|XT319|XT320|XT390|XT502|XT530|XT531|XT532|XT535|XT603|XT610|XT611|XT615|XT681|XT701|XT702|XT711|XT720|XT800|XT806|XT860|XT862|XT875|XT882|XT883|XT894|XT909|XT910|XT912|XT928',
  Samsung = 'Samsung|GT-I9100|GT-I9000|GT-I9020|SCH-A310|SCH-A530|SCH-A570|SCH-A610|SCH-A630|SCH-A650|SCH-A790|SCH-A795|SCH-A850|SCH-A870|SCH-A890|SCH-A930|SCH-A950|SCH-A970|SCH-A990|SCH-I100|SCH-I110|SCH-I400|SCH-I405|SCH-I500|SCH-I510|SCH-I515|SCH-I600|SCH-I730|SCH-I760|SCH-I770|SCH-I830|SCH-I910|SCH-I920|SCH-LC11|SCH-N150|SCH-N300|SCH-R300|SCH-R400|SCH-R410|SCH-T300|SCH-U310|SCH-U320|SCH-U350|SCH-U360|SCH-U365|SCH-U370|SCH-U380|SCH-U410|SCH-U430|SCH-U450|SCH-U460|SCH-U470|SCH-U490|SCH-U540|SCH-U550|SCH-U620|SCH-U640|SCH-U650|SCH-U660|SCH-U700|SCH-U740|SCH-U750|SCH-U810|SCH-U820|SCH-U900|SCH-U940|SCH-U960|SCS-26UC|SGH-A107|SGH-A117|SGH-A127|SGH-A137|SGH-A157|SGH-A167|SGH-A177|SGH-A187|SGH-A197|SGH-A227|SGH-A237|SGH-A257|SGH-A437|SGH-A517|SGH-A597|SGH-A637|SGH-A657|SGH-A667|SGH-A687|SGH-A697|SGH-A697|SGH-A707|SGH-A717|SGH-A727|SGH-A737|SGH-A747|SGH-A767|SGH-A777|SGH-A797|SGH-A817|SGH-A827|SGH-A837|SGH-A847|SGH-A867|SGH-A877|SGH-A887|SGH-A897|SGH-A927|SGH-C207|SGH-C225|SGH-C417|SGH-D307|SGH-D347|SGH-D357|SGH-D407|SGH-D415|SGH-D807|SGH-E105|SGH-E315|SGH-E316|SGH-E317|SGH-E335|SGH-E635|SGH-E715|SGH-I577|SGH-I607|SGH-I617|SGH-I627|SGH-I637|SGH-I677|SGH-I717|SGH-I727|SGH-I777|SGH-I827|SGH-I847|SGH-I857|SGH-I896|SGH-I897|SGH-I907|SGH-I917|SGH-I927|SGH-I937|SGH-I997|SGH-N105|SGH-N625|SGH-P107|SGH-P207|SGH-P735|SGH-P777|SGH-Q105|SGH-R225|SGH-S105|SGH-S307|SGH-T109|SGH-T119|SGH-T139|SGH-T209|SGH-T219|SGH-T229|SGH-T239|SGH-T249|SGH-T259|SGH-T309|SGH-T319|SGH-T329|SGH-T339|SGH-T349|SGH-T359|SGH-T369|SGH-T379|SGH-T409|SGH-T429|SGH-T439|SGH-T459|SGH-T469|SGH-T479|SGH-T499|SGH-T509|SGH-T519|SGH-T539|SGH-T559|SGH-T589|SGH-T609|SGH-T619|SGH-T629|SGH-T639|SGH-T659|SGH-T669|SGH-T679|SGH-T709|SGH-T719|SGH-T729|SGH-T739|SGH-T749|SGH-T759|SGH-T769|SGH-T809|SGH-T819|SGH-T839|SGH-T919|SGH-T919|SGH-T929|SGH-T939|SGH-T939|SGH-T959|SGH-T989|SGH-V205|SGH-V206|SGH-X105|SGH-X426|SGH-X427|SGH-X475|SGH-X495|SGH-X497|SGH-X507|SGH-ZX10|SGH-ZX20|SPH-A120|SPH-A400|SPH-A420|SPH-A460|SPH-A500I|SPH-A560|SPH-A600|SPH-A620|SPH-A660|SPH-A700|SPH-A740|SPH-A760|SPH-A790|SPH-A800|SPH-A820|SPH-A840|SPH-A880|SPH-A900|SPH-A940|SPH-A960|SPH-D600|SPH-D700|SPH-D710|SPH-D720|SPH-I300|SPH-I325|SPH-I330|SPH-I350|SPH-I500|SPH-I600|SPH-I700|SPH-L700|SPH-M100|SPH-M220|SPH-M240|SPH-M300|SPH-M305|SPH-M320|SPH-M330|SPH-M350|SPH-M360|SPH-M370|SPH-M380|SPH-M510|SPH-M540|SPH-M550|SPH-M560|SPH-M570|SPH-M580|SPH-M610|SPH-M620|SPH-M630|SPH-M800|SPH-M810|SPH-M850|SPH-M900|SPH-M910|SPH-M920|SPH-M930|SPH-N200|SPH-N240|SPH-N300|SPH-N400|SPH-Z400|SWC-E100',
  Sony = 'E10i|SonyEricsson|SonyEricssonLT15iv',
  Asus = 'Asus.*Galaxy',
  Palm = 'PalmSource|Palm', -- avantgo|blazer|elaine|hiptop|plucker|xiino
  GenericPhone = '(mmp|pocket|psp|symbian|Smartphone|smartfon|treo|up.browser|up.link|vodafone|wap|nokia|Series40|Series60|S60|SonyEricsson|N900|PPC;|MAUI.*WAP.*Browser|LG-P500)',
}

-- List of tablet devices.
local tabletDevices = {
  BlackBerryTablet = 'PlayBook|RIM Tablet',
  iPad = 'iPad|iPad.*Mobile', -- @todo: check for mobile friendly emails topic.
  Kindle = 'Kindle|Silk.*Accelerated',
  SamsungTablet = 'SAMSUNG.*Tablet|Galaxy.*Tab|GT-P1000|GT-P1010|GT-P6210|GT-P6800|GT-P6810|GT-P7100|GT-P7300|GT-P7310|GT-P7500|GT-P7510|SCH-I800|SCH-I815|SCH-I905|SGH-I777|SGH-I957|SGH-I987|SGH-T849|SGH-T859|SGH-T869|SGH-T989|SPH-D710|SPH-P100',
  HTCtablet = 'HTC Flyer|HTC Jetstream|HTC-P715a|HTC EVO View 4G|PG41200',
  MotorolaTablet = 'xoom|sholest|MZ615|MZ605|MZ505|MZ601|MZ602|MZ603|MZ604|MZ606|MZ607|MZ608|MZ609|MZ615|MZ616|MZ617',
  AsusTablet = 'Transformer|TF101',
  NookTablet = 'NookColor|nook browser|BNTV250A|LogicPD Zoom2',
  AcerTablet = 'Android.*(A100|A101|A200|A500|A501|A510|W500|W500P|W501|W501P)',
  YarvikTablet = 'Android.*(TAB210|TAB211|TAB224|TAB250|TAB260|TAB264|TAB310|TAB360|TAB364|TAB410|TAB411|TAB420|TAB424|TAB450|TAB460|TAB461|TAB464|TAB465|TAB467|TAB468)',
  GenericTablet = 'Tablet(?!.*PC)|ViewPad7|LG-V909|MID7015|BNTV250A|LogicPD Zoom2|\bA7EB\b|CatNova8|A1_07|CT704|CT1002|\bM721\b',
}

  -- List of mobile Operating Systems
local operatingSystems = {
  AndroidOS = '(android.*mobile|android(?!.*mobile))',
  BlackBerryOS = '(blackberry|rim tablet os)',
  PalmOS = '(avantgo|blazer|elaine|hiptop|palm|plucker|xiino)',
  SymbianOS = 'Symbian|SymbOS|Series60|Series40|\bS60\b',
  WindowsMobileOS = 'IEMobile|Windows Phone|Windows CE.*(PPC|Smartphone)|MSIEMobile|Window Mobile|XBLWP7',
  iOS = '(iphone|ipod|ipad)',
  FlashLiteOS = '',
  JavaOS = '',
  NokiaOS = '',
  webOS = '',
  badaOS = '\bBada\b',
  BREWOS = '',
}

  -- List of mobile User Agents
local userAgents = {      
  Chrome = '\bCrMo\b|Chrome/[.0-9]* Mobile',
  Dolfin = '\bDolfin\b',
  Opera = 'Opera.*Mini|Opera.*Mobi',
  Skyfire = 'skyfire',
  IE = 'IEMobile',
  Firefox = 'fennec|firefox.*maemo|(Mobile|Tablet).*Firefox|Firefox.*Mobile',
  Bolt = 'bolt',
  TeaShark = 'teashark',
  Blazer = 'Blazer',
  Safari = 'Mobile.*Safari|Safari.*Mobile',
  Midori = 'midori',
  GenericBrowser = 'NokiaBrowser|OviBrowser|SEMC.*Browser',
}

function detect.getRules()
  return detectionRules
end

--[[
  Private method that does the detection of the 
  mobile devices.

  @param type $key
  @return boolean|null 
]]
local function detect_(key)
  if key == nil then key = '' end

  local _rules = {}

  if empty(key) then
    -- Begin general search
    for _, _regex in pairs(detectionRules) do
      if not empty(_regex) then
        if not empty(preg.match(_regex, userAgent, nil, nil, nil, 'is')) then
          isMobile_ = true
          return true
        end
      end
    end
    return false
  else
    -- Search for a certain key.
    -- Make the keys lowecase so we can match: isIphone(), isiPhone(), isiphone(), etc.
    key = key:lower()
    for k, v in pairs(detectionRules) do
      _rules[k:lower()] = v
    end

    if _rules[key] ~= nil then
      if empty(_rules[key]) then
        return nil
      end
      if not empty(preg.match(_rules[key], userAgent, nil, nil, nil, 'is')) then
        isMobile_ = true
        return true
      else
        return false
      end           
    else
      return ('Method %s is not defined'):format(key)
    end

    return false
  end
end

--[[
  Check if the device is mobile.
  Returns true if any type of mobile device detected, including special ones
  @return bool
]]
function detect.isMobile()
  return isMobile_
end
    
--[[
  Check if the device is a tablet.
  Return true if any type of tablet device is detected.
  @return boolean 
]]
function detect.isTablet()
  for _, _regex in pairs(tabletDevices) do
    if not empty(preg.match(_regex, userAgent, nil, nil, nil, 'is')) then
      isTablet_ = true
      return true
    end
  end

  return false
end

--[[ Construct ]]
-- Merge all rules together
for k, v in pairs(phoneDevices) do
  detectionRules[k] = v
end
for k, v in pairs(tabletDevices) do
  detectionRules[k] = v
end
for k, v in pairs(operatingSystems) do
  detectionRules[k] = v
end
for k, v in pairs(userAgents) do
  detectionRules[k] = v
end
userAgent = _SERVER 'HTTP_USER_AGENT'
accept = _SERVER 'HTTP_ACCEPT'

if
  _SERVER 'HTTP_X_WAP_PROFILE' ~= nil or
  _SERVER 'HTTP_X_WAP_CLIENTID' ~= nil or
  _SERVER 'HTTP_WAP_CONNECTION' ~= nil or
  _SERVER 'HTTP_PROFILE' ~= nil or
  _SERVER 'HTTP_X_OPERAMINI_PHONE_UA' ~= nil or -- Reported by Nokia devices (eg. C3)
  _SERVER 'HTTP_X_NOKIA_IPADDRESS' ~= nil or
  _SERVER 'HTTP_X_NOKIA_GATEWAY_ID' ~= nil or
  _SERVER 'HTTP_X_ORANGE_ID' ~= nil or
  _SERVER 'HTTP_X_VODAFONE_3GPDPCONTEXT' ~= nil or
  _SERVER 'HTTP_X_HUAWEI_USERID' ~= nil or
  _SERVER 'HTTP_UA_OS' ~= nil or -- Reported by Windows Smartphones
  (_SERVER 'HTTP_UA_CPU' ~= nil and _SERVER 'HTTP_UA_CPU' == 'ARM') -- Seen this on a HTC
then
  isMobile_ = true
elseif not empty(accept) and (strpos(accept, 'text/vnd.wap.wml') ~= false or strpos(accept, 'application/vnd.wap.xhtml+xml') ~= false) then
  isMobile_ = true
else
  detect_()
end

setmetatable(mobile.detect, {
  __index = function(t, name)
    local key, value

    value = rawget(t, name)
    if value ~= nil then
      return value
    end

    if name ~=  nil then
      key = substr(name, 3)
    else
      key = ''
    end
    return function () return detect_(key) end
  end,
})
