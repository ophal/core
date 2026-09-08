local luadbi = require 'includes.database.driver.luadbi'

return luadbi.build('luadbi_sqlite3', 'sqlite3', 'SQLite3', [["]])
