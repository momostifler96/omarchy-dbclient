-- DB client (shell plugin momoledev.dbclient)
local dbclient = os.getenv("HOME") .. "/.local/bin/omarchy-dbclient"
o.bind("SUPER + ALT + D", "DB client", dbclient)
o.bind("SUPER + SHIFT + ALT + D", "DB client: new connection", dbclient .. " new")
