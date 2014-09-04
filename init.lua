nm = {}
nm.playerdb = {}
nm.inspect_mode = {}
nm.inspect_query = {}
nm.write_cache = {}
nm.write_cache_thresh = 20
nm.write_cache_timeout = 30 -- seconds

local function try_load(libname)
	local success, lib
	success, lib = pcall(require, libname)
	if success then
		return lib
	else
		return nil
	end
end

local bit32, bit
bit32 = try_load("bit32")
bit = try_load("bit")

-- Test whether libraries are usable for our purpose

local bit32_big = true
if bit32 then
	local t = 67
	if bit32.lshift(t + 32768, 32) ~= 141025251164160 then
		bit32_big = false -- broken
	end
end

local bit_big = true
if bit then
	local t = 67
	if bit.lshift(t + 32768, 32) ~= 141025251164160 then
		bit_big = false -- broken
	end
end

local function write_u16(f, n)
	local s
	if bit32 then
		s = string.char(bit32.band(n, 255), bit32.rshift(n, 8))
	elseif bit then
		s = string.char(bit.band(n, 255), bit.rshift(n, 8))
	else
		s = string.char(n % 256, math.floor(n / (2 ^ 8)))
	end
	f:write(s)
end

local function read_u16(f)
	local s = f:read(2)
	if not s then
		return nil
	end
	local a, b = string.byte(s, 1, 2)
	if bit32 then
		return a + bit32.lshift(b, 8)
	elseif bit then
		return a + bit.lshift(b, 8)
	else
		return a + b * (2 ^ 8)
	end
end

local function write_s16(f, n)
	write_u16(f, n + 32768)
end

local function read_s16(f)
	local v = read_u16(f)
	if v then
		return v - 32768
	else
		return nil
	end
end

local function hash_node_pos(x, y, z)
	if bit32 and bit32_big then
		return (x + 32768) + bit32.lshift(y + 32768, 16) + bit32.lshift(z + 32768, 32)
	elseif bit and bit_big then
		return (x + 32768) + bit.lshift(y + 32768, 16) + bit.lshift(z + 32768, 32)
	else
		return (x + 32768) + ((y + 32768) * (2 ^ 16)) + ((z + 32768) * (2 ^ 32))
	end
	
end

local function player_db_load()
	local f = io.open(minetest.get_worldpath().."/nm_players.db", "r")
	if not f then
		nm.player_nid = 0
		return
	end
	local id = 0
	for ent in f:lines() do
		nm.playerdb[ent] = id
		id = id + 1
	end
	nm.player_nid = id
	f:close()
end

local function player_db_add(name)
	local f = io.open(minetest.get_worldpath().."/nm_players.db", "a")
	if not f then
		minetest.log("error", "[NM] Failed to open player database")
		error()
	end
	f:write(name .. "\n")
	f:close()
end

local function player_db_lookup(name, no_new_entry)
	local id = nm.playerdb[name]
	if not id and not no_new_entry then
		id = nm.player_nid
		nm.playerdb[name] = id
		nm.player_nid = nm.player_nid + 1
		player_db_add(name)
	end
	return id
end

local function player_db_lookup_pid(spid)
	local sname
	for name, pid in pairs(nm.playerdb) do
		if pid == spid then
			sname = name
			break
		end
	end
	return sname
end

local function nm_db_index()
	nm.overwrite_cache = {}
	local f = io.open(minetest.get_worldpath().."/nm.db", "rb")
	if not f then
		f = io.open(minetest.get_worldpath().."/nm.db", "wb")
		f:write("NMDB") -- char[4] magic value
		f:write(string.char(1)) -- u8 version
		f:close()
		nm.info = "Fresh database was created"
		return
	end
	local m = f:read(4)
	if m ~= "NMDB" then
		error("Wrong magic value '" .. m .. "', expected 'NMDB'")
	end
	local v = string.byte(f:read(1))
	if v == 1 then
		-- ok
	else
		error("Unsupported version " .. v)
	end
	local seen = {}
	local i = 0
	local x, y, z, ph
	local stime = os.time()
	local sclock = os.clock()
	while true do
		x = read_s16(f) -- s16 x
		if not x then
			break
		end
		z = read_s16(f) -- s16 z
		y = read_s16(f) -- s16 y
		f:read(2)       -- u16 pid
		ph = hash_node_pos(x, y, z)
		if seen[ph] ~= nil then
			table.insert(nm.overwrite_cache, seen[ph])
		end
		seen[ph] = i
		i = i + 1
	end
	f:close()
	seen = nil
	local eclock = os.clock()
	local etime = os.time()
	nm.info = string.format("%ds(%.2fs CPU time), %d(%.2f%% outdated entries), %d total entries",
		os.difftime(etime, stime), eclock - sclock, #nm.overwrite_cache, (#nm.overwrite_cache / i) * 100, i)
	minetest.log("action", "[NM] Read NM database in " .. nm.info)
end

local function nm_db_lookup(sx, sy, sz)
	local f = io.open(minetest.get_worldpath().."/nm.db", "rb")
	if not f then
		minetest.log("error", "[NM] Failed to open database")
		error()
	end
	local m = f:read(4)
	if m ~= "NMDB" then
		error("Wrong magic value '" .. m .. "', expected 'NMDB'")
	end
	local v = string.byte(f:read(1))
	if v == 1 then
		-- ok
	else
		error("Unsupported version " .. v)
	end
	local x, y, z
	while true do
		x = read_s16(f) -- x
		if x == nil then
			break
		end
		if x ~= sx then
			f:read(6) -- z, y, pid
		else
			z = read_s16(f) -- z
			if z ~= sz then
				f:read(4) -- y, pid
			else
				y = read_s16(f) -- y
				if y ~= sy then
					f:read(2) -- pid
				else
					local pid = read_u16(f)
					f:close()
					return pid
				end
			end
		end
	end
	f:close()
	return nil
end

local function nm_db_lookup_multiple(poslist)
	local res = {}
	for i = 1, #poslist do
		res[i] = -1
	end
	local f = io.open(minetest.get_worldpath().."/nm.db", "rb")
	if not f then
		minetest.log("error", "[NM] Failed to open database")
		error()
	end
	local m = f:read(4)
	if m ~= "NMDB" then
		error("Wrong magic value '" .. m .. "', expected 'NMDB'")
	end
	local v = string.byte(f:read(1))
	if v == 1 then
		-- ok
	else
		error("Unsupported version " .. v)
	end
	local x, y, z, found
	while true do
		x = read_s16(f) -- x
		if x == nil then
			break
		end
		found = false
		for _, spos in ipairs(poslist) do
			if x == spos.x then
				found = true
			end
		end
		if not found then
			f:read(6) -- z, y, pid
		else
			z = read_s16(f) -- z
			found = false
			for _, spos in ipairs(poslist) do
				if x == spos.x and z == spos.z then
					found = true
				end
			end
			if not found then
				f:read(4) -- y, pid
			else
				y = read_s16(f) -- y
				found = 0
				for i, spos in ipairs(poslist) do
					if x == spos.x and z == spos.z and y == spos.y then
						found = i
					end
				end
				if found == 0 then
					f:read(2)
				else
					res[found] = read_u16(f)
				end
			end
		end
	end
	f:close()
	return res
end

local function nm_db_add(x, y, z, pid, fidx)
	local f
	if fidx then
		f = io.open(minetest.get_worldpath().."/nm.db", "r+b")
	else
		f = io.open(minetest.get_worldpath().."/nm.db", "ab")
	end
	if not f then
		minetest.log("error", "[NM] Failed to open database")
		error()
	end
	if fidx then
		f:seek("set", 4 + 1 + (8 * fidx))
	end
	write_s16(f, x)
	write_s16(f, z)
	write_s16(f, y)
	write_u16(f, pid)
	f:close()
end

local function fire_node_modify_raw(name, pos)
	local pid = player_db_lookup(name)
	if #nm.overwrite_cache > 0 then
		local fidx = table.remove(nm.overwrite_cache)
		nm_db_add(pos.x, pos.y, pos.z, pid, fidx)
	else
		nm_db_add(pos.x, pos.y, pos.z, pid)
	end
end

local function clean_write_cache()
	if #nm.write_cache <= 0 then return end
	for _, e in ipairs(nm.write_cache) do
		fire_node_modify_raw(e.name, e.pos)
	end
	nm.write_cache = {}
end

local write_cache_timer = 0
minetest.register_globalstep(function(dtime)
	write_cache_timer = write_cache_timer + dtime
	if write_cache_timer > nm.write_cache_timeout then
		clean_write_cache()
		write_cache_timer = 0
	end
end)

local function fire_node_modify(name, pos)
	if nm.write_cache_thresh > 0 then
		table.insert(nm.write_cache, {name=name, pos=pos})
		if #nm.write_cache > nm.write_cache_thresh then
			clean_write_cache()
		end
	else
		fire_node_modify_raw(name, pos)
	end
end

local function get_node_modify(pos)
	clean_write_cache()
	local pid = nm_db_lookup(pos.x, pos.y, pos.z)
	if pid == nil then
		return ""
	end
	local pname = player_db_lookup_pid(pid)
	if pname == nil then
		return -1
	end
	return pname
end

local function get_node_modify_multiple(poslist)
	clean_write_cache()
	local pids = nm_db_lookup_multiple(poslist)
	local res = {}
	for _, pid in ipairs(pids) do
		if pid == -1 then
			table.insert(res, "")
		else
			local pname = player_db_lookup_pid(pid)
			if pname == nil then
				table.insert(res, -1)
			else
				table.insert(res, pname)
			end
		end
	end
	return res
end

local function get_node_ret2human(v, pos)
	if v == "" then
		return "No information available for " .. pos .. "."
	elseif v == -1 then
		return "Found an entry for " .. pos .. " but no matching player name mapping, the database might be corrupted."
	else
		return pos .. " was last touched by " .. v .. "."
	end
end

minetest.register_on_placenode(function(pos, newnode, placer, oldnode, itemstack, pointed_thing)
	if not placer or not placer:is_player() then
		return
	end
	fire_node_modify(placer:get_player_name(), pos)
end)

minetest.register_on_dignode(function(pos, oldnode, digger)
	if not digger or not digger:is_player() then
		return
	end
	fire_node_modify(digger:get_player_name(), pos)
end)

minetest.register_chatcommand("nm", {
	params = "<x> <y> <z>",
	description = "Check who modified a node last",
	privs = {basic_privs=true},
	func = function(name, param)
		local x, y, z = param:match('(.-) (.-) (.*)')
		x = tonumber(x)
		y = tonumber(y)
		z = tonumber(z)
		if x == nil or y == nil or z == nil then
			minetest.chat_send_player(name, "Invalid coordinates.")
			return
		end
		local pname = get_node_modify({x=x, y=y, z=z})
		local ps = minetest.pos_to_string({x=x, y=y, z=z})
		minetest.chat_send_player(name, get_node_ret2human(pname, ps))
	end,
})

minetest.register_chatcommand("nm_inspect", {
	params = "",
	description = "Check who modified a node last (inspection mode)",
	privs = {basic_privs=true},
	func = function(name, param)
		if nm.inspect_mode[name] then
			nm.inspect_mode[name] = false
			if #nm.inspect_query[name] == 0 then
				minetest.chat_send_player(name, "Inspection mode disabled.")
				return
			end
			minetest.chat_send_player(name, "Inspection mode disabled, executing search.")
			local res = get_node_modify_multiple(nm.inspect_query[name])
			for i, pos in ipairs(nm.inspect_query[name]) do
				local pname = res[i]
				local ps = minetest.pos_to_string(pos)
				minetest.chat_send_player(name, get_node_ret2human(pname, ps))
			end
			nm.inspect_query[name] = {}
		else
			nm.inspect_mode[name] = true
			nm.inspect_query[name] = {}
			minetest.chat_send_player(name, "Inspection mode enabled.")
		end
	end,
})

minetest.register_on_punchnode(function(pos, node, puncher, pointed_thing)
	if not puncher:is_player() then return end
	local name = puncher:get_player_name()
	if nm.inspect_mode[name] then
		table.insert(nm.inspect_query[name], pointed_thing.under)
	end
end)

minetest.register_chatcommand("nm_info", {
	params = "",
	description = "Get information about NM database & configuration",
	privs = {basic_privs=true},
	func = function(name, param)
		minetest.chat_send_player(name, string.format("Info: Database was read in %s, "
			.. "%d outdated entries queued for overwriting, %d unsaved changes", nm.info, #nm.overwrite_cache, #nm.write_cache))
		local cfg = string.format("Write cache size: %d, Write cache timeout: %ds, Libraries -> bit: ",
			nm.write_cache_thresh, nm.write_cache_timeout)
		if bit then
			cfg = cfg .. "available (big numbers: "
			if bit_big then
				cfg = cfg .. "working"
			else
				cfg = cfg .. "broken"
			end
			cfg = cfg .. "), "
		else
			cfg = cfg .. "unavailable, "
		end
		cfg = cfg .. "bit32: "
		if bit32 then
			cfg = cfg .. "available (big numbers: "
			if bit32_big then
				cfg = cfg .. "working"
			else
				cfg = cfg .. "broken"
			end
			cfg = cfg .. ")"
		else
			cfg = cfg .. "unavailable"
		end
		minetest.chat_send_player(name, "Config Info: " .. cfg)
	end,
})

minetest.register_chatcommand("nm_reindex", {
	params = "",
	description = "Reindex the NM database",
	privs = {basic_privs=true},
	func = function(name, param)
		clean_write_cache()
		nm_db_index()
		minetest.chat_send_player(name, "Read database in " .. nm.info)
	end,
})

player_db_load()
nm_db_index()
