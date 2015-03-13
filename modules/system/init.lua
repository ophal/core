local _M = {}
ophal.modules.system = _M

function _M.cron()
  session_destroy_expired()
end

return _M
