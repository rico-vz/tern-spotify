--!strict

local spotify = require("./spotify")
local ui = tern.ui

type Player = spotify.Player

local POLL_MS = 300
local SEEK_STEP_MS = 10000
local VOLUME_STEP = 5
local OPTIMISTIC_MS = 2500
local FLASH_MS = 4000
local RESEND_MS = 1500

type Block = {
   context: BlockCx,
   blob_key: string?,
   blob: string?,
   resend_at: number?,
   rendered: string,
}

-- Blocks have no close hook, so the loop drops panes that are gone
local blocks: { [number]: Block } = {}
local current_player: Player? = nil
local problem: string? = nil
local base = { seq = -1, pos = 0, at = 0 }
local art: { key: string?, bytes: string?, mime: string?, loading: string? } = {}
local optimistic: { [string]: { value: any, expires: number } } = {}
local sent: { [string]: number } = {}
local last_ack: string? = nil
local flash: { text: string, expires: number }? = nil
local loop: TimerHandle? = nil

local function value(field: string, actual: any): any
   local pending = optimistic[field]
   if pending == nil then
      return actual
   end
   if tern.now() > pending.expires or pending.value == actual then
      optimistic[field] = nil
      return actual
   end
   return pending.value
end

local function status(): string
   return value("status", if current_player then current_player.status else "")
end

local function position(): number
   local player = current_player
   if not player then
      return 0
   end
   local pos = base.pos
   if status() == "playing" then
      pos += tern.now() - base.at
   end
   if player.duration then
      pos = math.min(pos, player.duration)
   end
   return math.max(0, pos)
end

local function alive_panes(): { [number]: boolean }
   local live = {}
   for _, pane in tern.pane.list() do
      live[pane.pane] = true
   end
   return live
end

local function mime_of(bytes: string, header: string?): string
   if header and string.find(header, "^image/") then
      return (string.match(header, "^[^;%s]+") :: string)
   end
   if string.sub(bytes, 1, 2) == "\xFF\xD8" then
      return "image/jpeg"
   end
   return "image/png"
end

local function share_art()
   if not art.bytes or not art.key then
      return
   end
   local now = tern.now()
   for _, block in blocks do
      if block.blob_key ~= art.key or (block.resend_at and now >= block.resend_at) then
         block.resend_at = if block.blob_key ~= art.key then now + RESEND_MS else nil
         block.blob = block.context:blob(art.bytes :: string, art.mime or "image/png")
         block.blob_key = art.key
         block.rendered = ""
      end
   end
end

local function render_all()
   for _, block in blocks do
      block.context:render()
   end
end

local function load_art(player: Player)
   local key = player.art_key
   if key == nil then
      art = {}
      return
   end
   if key == art.key or key == art.loading then
      return
   end
   if player.art_file then
      local ok, bytes = pcall(tern.fs.read, player.art_file, 8 * 1024 * 1024)
      if ok then
         art = { key = key, bytes = bytes, mime = mime_of(bytes, nil) }
         share_art()
      end
   elseif player.art_url then
      art.loading = key
      tern.fetch(player.art_url, { timeout_ms = 15000 }, function(response: FetchResult, _)
         if art.loading ~= key then
            return
         end
         art.loading = nil
         if response.error or response.status ~= 200 then
            return
         end
         art = { key = key, bytes = response.body, mime = mime_of(response.body, response.headers["content-type"]) }
         share_art()
         render_all()
      end)
   end
end

local function report(player: Player)
   if player.ack == nil or player.ack == last_ack then
      return
   end
   last_ack = player.ack
   local pane = sent[player.ack]
   if pane == nil then
      return
   end
   sent[player.ack] = nil
   if player.error then
      optimistic = {}
      local block = blocks[pane]
      if block then
         block.context:toast("error", "Spotify", player.error)
      end
   end
end

local function send(block: Block?, name: string, arg: (string | number)?)
   local id = spotify.send(name, arg)
   if block then
      sent[id] = block.context.pane
   end
end

local function expect(field: string, expected: any)
   optimistic[field] = { value = expected, expires = tern.now() + OPTIMISTIC_MS }
end

local function say(text: string)
   flash = { text = text, expires = tern.now() + FLASH_MS }
end

local function toggle(block: Block)
   local player = current_player
   if not (player and player.running) then
      send(block, "open")
      return
   end
   send(block, "toggle")
   expect("status", if status() == "playing" then "paused" else "playing")
   base = { seq = base.seq, pos = position(), at = tern.now() }
end

local function seek(block: Block, ms: number)
   local player = current_player
   if not (player and player.can.seek) then
      return
   end
   ms = math.max(0, if player.duration then math.min(ms, player.duration) else ms)
   send(block, "seek", math.floor(ms))
   base = { seq = base.seq, pos = ms, at = tern.now() }
end

local function shuffle(block: Block)
   local player = current_player
   if not (player and player.can.shuffle) then
      return
   end
   local on = not value("shuffle", player.shuffle)
   send(block, "shuffle", if on then 1 else 0)
   expect("shuffle", on)
end

local NEXT_REPEAT = { off = "context", context = "track", track = "off" }

local function cycle_repeat(block: Block)
   local player = current_player
   if not (player and player.can["repeat"]) then
      return
   end
   local mode = NEXT_REPEAT[value("repeat", player["repeat"]) or "off"] or "off"
   send(block, "repeat", mode)
   expect("repeat", mode)
end

local function no_volume(player: Player?): string
   return if player and player.backend == "windows" then "Spotify's volume shows once it plays" else "Spotify doesn't report its volume"
end

local function set_volume(block: Block, level: number)
   local player = current_player
   if not (player and player.can.volume) then
      say(no_volume(player))
      return
   end
   level = math.clamp(math.floor(level + 0.5), 0, 100)
   if value("muted", player.muted) then
      send(block, "mute", 0)
      expect("muted", false)
   end
   send(block, "volume", level)
   expect("volume", level)
end

local function mute(block: Block)
   local player = current_player
   if not (player and player.can.mute) then
      say(no_volume(player))
      return
   end
   local on = not value("muted", player.muted)
   send(block, "mute", if on then 1 else 0)
   expect("muted", on)
end

local function signature(): string
   local player = current_player
   local parts = {
      tostring(if player then player.seq else -1),
      tostring(base.seq),
      status(),
      if flash then flash.text else "",
   }
   if status() == "playing" then
      table.insert(parts, tostring(position() // 1000))
   end
   for field, pending in optimistic do
      table.insert(parts, field .. "=" .. tostring(pending.value))
   end
   return table.concat(parts, "|")
end

local function tick()
   loop = nil
   local live = alive_panes()
   for pane in blocks do
      if not live[pane] then
         blocks[pane] = nil
      end
   end
   if next(blocks) == nil then
      return
   end

   local latest = spotify.read()
   problem = spotify.ensure(latest)
   if latest and spotify.is_fresh(latest) then
      if latest.pos_seq ~= base.seq then
         base = { seq = latest.pos_seq, pos = latest.position or 0, at = tern.now() }
      end
      current_player = latest
      load_art(latest)
      share_art()
      report(latest)
   elseif latest and current_player == nil then
      current_player = latest
   end
   if flash and tern.now() > flash.expires then
      flash = nil
   end

   local render_signature = signature()
   for _, block in blocks do
      if block.rendered ~= render_signature then
         block.rendered = render_signature
         block.context:render()
      end
   end
   loop = tern.timer(POLL_MS, tick)
end

local function start_loop()
   if loop == nil then
      loop = tern.timer(0, tick)
   end
end

local function with(node: Node, props: { [string]: any }): Node
   local merged: { [string]: any } = node.p or {}
   for name, prop in props do
      merged[name] = prop
   end
   node.p = merged
   return node
end

local function button(key: string, icon: string, act: string, enabled: boolean, on: boolean?, label: string?): Node
   local kids: { Node } = { ui.node("icon", { name = icon }) }
   if label then
      table.insert(kids, ui.text({ ui.span(label, "strong") }))
   end
   local props: { [string]: any } = {
      key = key,
      role = if key == "play"
         then "spotify-player__button spotify-player__button--play spotify-u-interactive"
         else "spotify-player__button spotify-u-interactive",
      tone = if not enabled then "muted" elseif on then "accent" else nil,
   }
   if enabled then
      props.actions = { click = act }
   end
   return with(ui.row(kids), props)
end

local function seek_cells(context: BlockCx): number
   return math.clamp(context.cols - 16, 12, 72)
end

local function cell_bar(key: string, role: string, count: number, fill: number, act: string?): Node
   local cells: { Node } = {}
   local lit_cells = math.floor(fill * count + 0.5)
   for i = 1, count do
      local props: { [string]: any } = {
         key = i,
         role = "spotify-player__cell spotify-u-interactive",
         tone = if i <= lit_cells then "accent" else nil,
      }
      if act then
         props.actions = { click = act .. "=" .. tostring(i) }
      end
      cells[i] = with(ui.text(""), props)
   end
   return with(ui.row(cells), { key = key, role = role })
end

local function message(head: string, body: string, buttons: { Node }, tone: string?): Node
   local children: { Node } = { ui.md(body) }
   if #buttons > 0 then
      table.insert(children, with(ui.row(buttons), { key = "buttons" }))
   end
   return with(ui.card({ ui.span(head, "strong") }, children), { key = "message", tone = tone })
end

local function text_button(key: string, label: string, act: string, tone: string): Node
   return with(ui.badge(label, tone), {
      key = key,
      role = "spotify-player__link spotify-u-interactive",
      actions = { click = act },
   })
end

local function hints(): Node
   local items: { { string } } = {
      { "space", "play" },
      { "←→", "seek" },
      { "n p", "track" },
      { "s", "shuffle" },
      { "r", "repeat" },
      { "+ -", "volume" },
      { "m", "mute" },
   }
   local spans: { Span } = {}
   for index, item in items do
      if index > 1 then
         table.insert(spans, ui.span("  ", "dim"))
      end
      table.insert(spans, ui.span(item[1], "key"))
      table.insert(spans, ui.span(" " .. item[2], "dim"))
   end
   return with(ui.text(spans), { key = "hints", role = "spotify-player__hints" })
end

local function dock(): Node
   local lines: { Node } = {}
   if flash then
      table.insert(lines, with(ui.text({ ui.span(flash.text, "muted") }), { key = "status" }))
   end
   table.insert(lines, hints())
   return with(ui.col(lines), { role = "spotify-player__dock" })
end

local function controls_row(player: Player): Node
   local playing = status() == "playing"
   local shuffle_on = value("shuffle", player.shuffle) == true
   local rep = value("repeat", player["repeat"]) or "off"
   return with(ui.row({
      button("shuffle", "swap", "shuffle", player.can.shuffle, shuffle_on),
      button("prev", "frame-prev", "prev", player.can.prev),
      button("play", if playing then "pause" else "play", "play-pause", player.can.play),
      button("next", "frame-next", "next", player.can.next),
      button("repeat", "repeat", "repeat", player.can["repeat"], rep ~= "off", if rep == "track" then "1" else nil),
   }), { key = "controls", role = "spotify-player__controls" })
end

local function progress_row(player: Player, context: BlockCx): Node
   local pos = position()
   local fill = if player.duration and player.duration > 0 then pos / player.duration else 0
   return with(ui.row({
      with(ui.text({ ui.span(spotify.clock(pos), "muted") }), { key = "at", role = "spotify-player__time" }),
      cell_bar("bar", "spotify-player__bar", seek_cells(context), fill, if player.can.seek then "seek" else nil),
      with(ui.text({ ui.span(spotify.clock(player.duration), "muted") }), { key = "len", role = "spotify-player__time" }),
   }), { key = "progress", role = "spotify-player__progress" })
end

local function cover(block: Block, player: Player, key: string, role: string, clickable: boolean): Node
   if block.blob and block.blob_key == player.art_key then
      local props: { [string]: any } = { key = key, role = role }
      if clickable then
         props.role = role .. " spotify-u-interactive"
         props.actions = { click = "launch" }
      end
      return with(ui.node("image", { blob = block.blob, alt = player.album }), props)
   end
   return with(ui.node("icon", { name = "wave" }), { key = key, role = role .. " spotify-player__cover--empty" })
end

local function now_playing(block: Block, player: Player, context: BlockCx): Node
   local narrow = context.cols < 60
   local meta: { Node } = {
      with(ui.text({ ui.span(player.title, "strong") }), { key = "title", role = "spotify-player__title" }),
   }
   if player.artist ~= "" then
      table.insert(meta, with(ui.text(player.artist), { key = "artist", role = "spotify-player__artist" }))
   end
   if player.album ~= "" then
      table.insert(meta, with(ui.text({ ui.span(player.album, "muted") }), { key = "album", role = "spotify-player__album" }))
   end
   local hero_kids: { Node } = { cover(block, player, "spotify.art", "spotify-player__cover spotify-player__art", true), with(ui.col(meta), { key = "meta", role = "spotify-player__meta" }) }
   local hero = with(if narrow then ui.col(hero_kids) else ui.row(hero_kids), {
      key = "hero",
      role = if narrow then "spotify-player__hero spotify-player__hero--narrow" else "spotify-player__hero",
   })

   local level = value("volume", player.volume)
   local muted = value("muted", player.muted) == true
   local volume_kids: { Node } = {
      button("mute", if muted then "slash-circle" else "wave", "mute", player.can.mute, muted),
   }
   if player.can.volume and level then
      table.insert(volume_kids, cell_bar("level", "spotify-player__bar spotify-player__bar--volume", 20, if muted then 0 else level / 100, "volume"))
      table.insert(volume_kids, with(ui.text({ ui.span(if muted then "muted" else tostring(level) .. "%", "muted") }), {
         key = "pct",
         role = "spotify-player__time",
      }))
   else
      table.insert(volume_kids, with(ui.text({ ui.span(no_volume(player), "dim") }), { key = "pct" }))
   end
   local volume = with(ui.row(volume_kids), { key = "volume", role = "spotify-player__volume" })

   local tools = with(ui.row({
      button("open", "open", "launch", true),
   }), { key = "tools", role = "spotify-player__tools" })

   return with(ui.col({
      cover(block, player, "spotify.backdrop", "spotify-player__cover spotify-player__backdrop", false),
      -- Tern hides a node with 0 content
      with(ui.col({ ui.text(" ") }), { key = "scrim", role = "spotify-player__scrim" }),
      hero,
      progress_row(player, context),
      controls_row(player),
      with(ui.row({ volume, tools }), { key = "lower", role = "spotify-player__lower" }),
   }), { key = "player", role = "spotify-player" })
end

local function view(block: Block, context: BlockCx): BlockView
   local player = current_player
   local main: Node
   if problem and not spotify.is_fresh(player) then
      main = message("Spotify helper not running", problem, { text_button("retry", "Retry", "retry", "accent") }, "error")
   elseif player == nil then
      main = with(ui.progress(nil, "Connecting to Spotify…"), { key = "message" })
   elseif player.problem then
      main = message("Can't reach Spotify", player.problem, { text_button("retry", "Retry", "retry", "accent") }, "warning")
   elseif not player.running then
      main = message(
         "Spotify isn't running",
         "Start the Spotify app on this machine and it shows up here.",
         { text_button("open", "Open Spotify", "launch", "accent") },
         nil
      )
   elseif player.title == "" then
      main = message(
         "Nothing playing",
         "Pick something in Spotify.",
         { text_button("open", "Open Spotify", "launch", "accent") },
         nil
      )
   else
      main = now_playing(block, player, context)
   end
   return {
      main = with(ui.col({ main }), { role = "spotify-player__main" }),
      dock = dock(),
   }
end

local function act(block: Block, name: string, arg: string?)
   local player = current_player
   if name == "play-pause" then
      toggle(block)
   elseif name == "next" then
      send(block, "next")
   elseif name == "prev" then
      send(block, "previous")
   elseif name == "shuffle" then
      shuffle(block)
   elseif name == "repeat" then
      cycle_repeat(block)
   elseif name == "mute" then
      mute(block)
   elseif name == "launch" then
      send(block, "open")
   elseif name == "retry" then
      spotify.retry()
      problem = spotify.ensure(spotify.read())
   elseif name == "seek" and player and player.duration then
      seek(block, ((tonumber(arg) or 1) - 0.5) / seek_cells(block.context) * player.duration)
   elseif name == "volume" then
      set_volume(block, (tonumber(arg) or 0) * 5)
   end
end

tern.block.define("player", {
   init = function(context: BlockCx, _args: { string }, _saved: any): Block
      local block: Block = { context = context, blob_key = nil, blob = nil, resend_at = nil, rendered = "" }
      blocks[context.pane] = block
      current_player = current_player or spotify.read()
      start_loop()
      return block
   end,

   title = function(_block: Block): string?
      local player = current_player
      if player and player.running and player.title ~= "" then
         local symbol = if status() == "playing" then "▶ " else "⏸ "
         if player.artist ~= "" then
            return symbol .. spotify.cut(player.artist, 30) .. " - " .. spotify.cut(player.title, 40)
         end
         return symbol .. spotify.cut(player.title, 40)
      end
      return "Spotify"
   end,

   view = function(block: Block, context: BlockCx): BlockView
      return view(block, context)
   end,

   key = function(block: Block, key: Key, _context: BlockCx): boolean?
      if key.ctrl or key.alt or key.meta then
         return false
      end
      local player = current_player
      local pressed = key.text or key.name
      if key.name == "space" or pressed == "k" then
         act(block, "play-pause")
      elseif key.name == "right" or key.name == "left" then
         seek(block, position() + (if key.name == "right" then SEEK_STEP_MS else -SEEK_STEP_MS))
      elseif pressed == "n" or pressed == "." then
         act(block, "next")
      elseif pressed == "p" or pressed == "," then
         act(block, "prev")
      elseif pressed == "s" then
         act(block, "shuffle")
      elseif pressed == "r" then
         act(block, "repeat")
      elseif pressed == "+" or pressed == "=" or key.name == "up" then
         set_volume(block, (value("volume", player and player.volume) or 0) + VOLUME_STEP)
      elseif pressed == "-" or pressed == "_" or key.name == "down" then
         set_volume(block, (value("volume", player and player.volume) or 0) - VOLUME_STEP)
      elseif pressed == "m" then
         act(block, "mute")
      elseif pressed == "o" then
         act(block, "launch")
      elseif string.match(pressed, "^%d$") and player and player.duration then
         seek(block, (tonumber(pressed) :: number) / 10 * player.duration)
      else
         return false
      end
      return true
   end,

   event = function(block: Block, ui_event: UiEvent, _context: BlockCx)
      if ui_event.ev == "action" and type(ui_event.act) == "string" then
         act(block, ui_event.act, ui_event.value)
      end
   end,
})
