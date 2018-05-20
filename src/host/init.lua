--- Cloud catcher connection script. This acts both as a way of connecting
-- to a new session and interfacing with the session once connected.

-- Cache some globals
local tonumber = tonumber
local argparse = require "argparse"

local function is_help(cmd)
  return cmd == "help" or cmd == "--help" or cmd == "-h" or cmd == "-?"
end

local cloud = _G.cloud_catcher
if cloud then
  -- If the cloud_catcher API is available, then we provide an interface for it
  -- instead of trying to nest things. That would be silly.
  local id, file, forceWrite = nil, nil, false
  local usage = ([[
cloud: <subcommand> [args]
Communicate with
Subcommands:
  edit <file> Open a file on the remote server.
  token       Display the token for this
              connection.
]]):gsub("^%s+", ""):gsub("%s+$", "")

    local subcommand = ...
    if subcommand == "edit" or subcommand == "e" then
      local arguments = argparse("cloud edit: Edit a file in the remote viewer")
      arguments:add({ "file" }, { doc = "The file to upload" })
      local result = arguments:parse(select(2, ...))

      local file = result.file
      if is_help(file) then print(usage) return
      elseif file == nil then printError(usage) error()
      end

      local resolved = shell.resolve(file)

      -- Create .lua files by default
      if not fs.exists(resolved) and not resolved:find("%.") then
        local extension = settings.get("edit.default_extension", "")
        if extension ~= "" and type(extension) == "string" then
            resolved = resolved .. "." .. extension
        end
      end

      -- Error checking: we can't edit directories or readonly files which don't exist
      if fs.isDir(resolved) then error(("%q is a directory"):format(file), 0) end
      if fs.isReadOnly(resolved) then
        if fs.exists(resolved) then
          print(("%q is read only, will not be able to modify"):format(file))
        else
          error(("%q does not exist"):format(file), 0)
        end
      end

      -- Let's actually edit the thing!
      local ok, err = cloud.edit(resolved)
      if not ok then error(err, 0) end
      return
    elseif subcommand == "token" or subcommand == "-t" then print(cloud.token()) return
    elseif is_help(subcommand) then print(usage) return
    elseif subcommand == nil then printError(usage) error()
    else error(("%q is not a cloud catcher subcommand, run with --h for more info"):format(subcommand), 0)
    end

    error("unreachable")
    return
end

-- The actual cloud catcher client. Let's do some argument parsing!
local current_path = shell.getRunningProgram()
local current_name = fs.getName(current_path)

--- Here is a collection of libraries which we'll need.
local framebuffer, encode = require("framebuffer"), require("encode")

local arguments = argparse(current_name .. ": Interact with this computer remotely")
arguments:add({ "token" }, { doc = "The token to use when connecting" })
arguments:add({ "--term", "-t" }, { value = true, doc = "Terminal dimensions or none to hide" })
arguments:add({ "--http", "-H" }, { value = false, doc = "Use HTTP instead of HTTPs" })
local result = arguments:parse(...)

local token = result.token
if #token ~= 32 or token:find("[^%a%d]") then
  error("Invalid token (must be 32 alpha-numeric characters)", 0)
end

local term_opts = result.term
local previous_term = term.current()
local parent_term = previous_term
if term_opts then
  if term_opts == "none" then
    parent_term = framebuffer.empty(true, term.getSize())
  elseif term_opts:find("^(%d+)x(%d+)$") then
    local w, h = term_opts:match("^(%d+)x(%d+)$")
    -- Enforce some bounds. Note the latter could be much larger, but I'd rather
    -- you didn't lift it.
    if w == 0 or h == 0 then error("Terminal cannot have 0 size", 0) end
    if w * h > 2000 then error("Terminal is too large to handle", 0) end

    parent_term = framebuffer.empty(true, tonumber(w), tonumber(h))
  else
    error("Unknown format for term: expected \"none\" or \"wxh\"", 0)
  end
end

-- Let's try to connect to the remote server
local protocol = result.http and "ws" or "wss"
local url = protocol .. "://localhost:8080/host?id=" .. token
local remote, err = http.websocket(url)
if not remote then error("Cannot connect to cloud catcher server: " .. err, 0) end

-- We're all ready to go, so let's inject our API and shell hooks
do
  local max_packet_size = 16384
  _G.cloud_catcher = {
    token = function() return token end,
    edit = function(file, force)
      -- We default to editing an empty string if the file doesn't exist
      local contents
      local handle = fs.open(file, "rb")
      if handle then
        contents = handle.readAll()
        handle.close()
      else
        contents = ""
      end

      -- We currently don't compress because I'm a wuss.
      local encoded = contents
      if #file + #encoded + 5 > max_packet_size then
        return false, "This file is too large to be edited remotely"
      end

      local check = encode.fletcher_32(contents)

      local flag = 0x02
      if fs.isReadOnly(file) then flag = flag + 0x08 end

      -- Send the File contents packet with an edit flag
      remote.send(("30%02x%08x%s\0%s"):format(flag, check, file, contents))
      return true
    end
  }

  shell.setAlias("cloud", "/" .. current_path)

  local function complete_multi(text, options)
    local results = {}
    for i = 1, #options do
        local option, add_spaces = options[i][1], options[i][2]
        if #option + (add_spaces and 1 or 0) > #text and option:sub(1, #text) == text then
            local result = option:sub(#text + 1)
            if add_spaces then table.insert( results, result .. " " )
            else table.insert( results, result )
            end
        end
    end
    return results
  end

  local subcommands = { { "edit", true }, { "token", false } }
  shell.setCompletionFunction(current_path, function(shell, index, text, previous_text)
    -- Should never happen, but let's be safe
    if _G.cloud_catcher == nil then return end

    if index == 1 then
      return complete_multi(text, subcommands)
    elseif index == 2 and previous_text[2] == "edit" then
        return fs.complete(text, shell.dir(), true, false)
    end
  end)
end

-- Instantiate our sub-program
local co = coroutine.create(shell.run)

-- Create our term buffer and start using it
local buffer = framebuffer.buffer(parent_term)
term.redirect(buffer)
term.clear()
term.setCursorPos(1, 1)

-- Oh here we are and here we are and here we go
local ok, res = coroutine.resume(co, "shell")

local last_change, last_timer = os.clock(), nil
while ok and coroutine.status(co) ~= "dead" do
  if last_timer == nil and buffer.is_dirty() then
    -- If the buffer is dirty and we've no redraw queued
    local now = os.clock()

    if now - last_change < 0.04 then
      -- If we last changed within the last tick then schedule a redraw to prevent
      -- multiple ticks
      last_timer = os.startTimer(0)
    else
      -- Otherwise send the redraw immediately
      buffer.clear_dirty()
      last_change = os.clock()
      remote.send("10" .. buffer.serialise())
    end
  end

  local event = table.pack(coroutine.yield())

  if event[1] == "timer" and event[2] == last_timer then
    -- If we've got a redraw queued reset the timer and send our draw
    last_timer = nil

    buffer.clear_dirty()
    last_change = os.clock()
    remote.send("10" .. buffer.serialise())
  elseif event[1] == "websocket_closed" and event[2] == url then
    ok, res = false, "Connection lost"
    remote = nil
  elseif event[1] == "websocket_message" and event[2] == url then
    local message = event[3]
    local code = tonumber(message:sub(1, 2), 16)

    if code == 0x00 or code == 0x01 then
      -- We shouldn't ever receive these packets, but let's handle them anyway
      ok, res = false, "Connection lost"
    elseif code == 0x02 then
      -- Reply to ping events
      remote.send("02")
    elseif code == 0x20 then
      -- Just forward paste events
      os.queueEvent("paste", message:sub(3))
    elseif code == 0x21 then
      -- Key events: a kind of 0 or 1 signifies a key press, 2 is a release
      local kind, code, char = message:match("^..(%x)(%x%x)(.*)$")
      if kind then
        kind, code = tonumber(kind, 16), tonumber(code, 16)
        if kind == 0 or kind == 1 then
          os.queueEvent("key", code, kind == 1)
          if char ~= "" then os.queueEvent("char", char) end
        elseif kind == 2 then os.queueEvent("key_up", code)
        end
      end
    elseif code == 0x22 then
      -- Mouse events
      local kind, code, x, y = message:match("^..(%x)(%x)(%x%x)(%x%x)$")
      if kind then
        kind, code, x, y = tonumber(kind, 16), tonumber(code, 16), tonumber(x, 16), tonumber(y, 16)
        if kind == 0 then os.queueEvent("mouse_click", code, x, y)
        elseif kind == 1 then os.queueEvent("mouse_up", code, x, y)
        elseif kind == 2 then os.queueEvent("mouse_drag", code, x, y)
        elseif kind == 3 then os.queueEvent("mouse_scroll", code - 1, x, y)
        end
      end
    elseif code == 0x30 then
      -- File edit events
      local flags, checksum, name, contents = message:match("^..(%x%x)(%x%x%x%x%x%x%x%x)([^\0]+)\0(.*)$")
      if flags then
        flags, checksum = tonumber(flags, 16), tonumber(checksum, 16)

        -- If the force flag is true, then we can always edit
        local ok = bit32.band(flags, 0x1) == 1

        -- Try to open the file. If it exists, determine the expected checksum
        local expected_checksum = 0
        local handle = fs.open(name, "rb")
        if handle then
          local contents = handle.readAll()
          handle.close()
          expected_checksum = encode.fletcher_32(contents)
        end

        -- We can edit the file if it doesn't already exist, or if the checksums match.
        if not ok then
          ok = expected_checksum == 0 or checksum == expected_checksum
        end

        -- Try to write our changes if we're all OK, otherwise abort.
        local handle = ok and fs.open(name, "wb")
        if handle then
          handle.write(contents)
          handle.close()
          remote.send(("31%08x%s"):format(encode.fletcher_32(contents), name))
        else
          remote.send(("32%08x%s"):format(expected_checksum, name))
        end
      end
    end
  elseif res == nil or event[1] == res or event[1] == "terminate" then
    ok, res = coroutine.resume(co, table.unpack(event, 1, event.n))
  end
end

term.redirect(previous_term)
if previous_term == parent_term then
  -- If we were writing to the current terminal then reset it.
  term.clear()
  term.setCursorPos(1, 1)
  if previous_term.endPrivateMode then previous_term.endPrivateMode() end
end

-- Clear our ugly completion hacks
_G.cloud_catcher = nil
shell.clearAlias("cloud")
shell.getCompletionInfo()[current_path] = nil

if remote ~= nil then remote.close() end

if not ok then error(res, 0) end
