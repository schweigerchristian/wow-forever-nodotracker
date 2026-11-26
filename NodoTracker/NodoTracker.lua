-- NodoTracker: XP and gold tracker in the style of a damage meter (Details)
-- Session = since login (/reload keeps it). Overall = until reset.
-- Frame uses the atlases/templates of Blizzard's built-in damage meter.

local ADDON = ...
local db, S, A, opt
local lastXP, lastMax, lastLevel, lastMoney
local debugMode = false

local DEFAULTS = { font = 1, size = 12, icon = 18, scale = 1.0, width = 280, alpha = 0.8 }
local FONTS = {
  { "Friz Quadrata", "Fonts\\FRIZQT__.TTF" },
  { "Arial Narrow",  "Fonts\\ARIALN.TTF" },
  { "Skurri",        "Fonts\\skurri.ttf" },
  { "Morpheus",      "Fonts\\MORPHEUS.TTF" },
}
local WHITE = "Interface\\Buttons\\WHITE8x8"

local ICON = {
  coin  = "Interface\\Icons\\INV_Misc_Coin_01",
  sword = "Interface\\Icons\\INV_Sword_04",
  quest = "Interface\\GossipFrame\\AvailableQuestIcon",
  other = "Interface\\Icons\\INV_Misc_Map_01",
  level = "Interface\\Icons\\Spell_Holy_SurgeOfLight",
  xp    = "Interface\\Icons\\Spell_Holy_HolyGuidance",
  next  = "Interface\\ChatFrame\\ChatFrameExpandArrow",
  up    = "Interface\\Buttons\\Arrow-Up-Up",
  down  = "Interface\\Buttons\\Arrow-Down-Up",
  gear  = "Interface\\Icons\\INV_Misc_Gear_01",
  reset = "Interface\\Icons\\Spell_Nature_TimeStop",
  check = "Interface\\Buttons\\UI-CheckBox-Check",
}

local GOLD, GREY, GREEN, RED = "|cffffd100", "|cffa89878", "|cff40dc40", "|cffe63c3c"

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
local function num(n)
  n = math.floor((n or 0) + 0.5)
  local neg = n < 0
  local s = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", "")
  return (neg and "-" or "") .. s
end

local function money(c, size)
  c = math.floor(math.abs(c or 0))
  if GetCoinTextureString then return GetCoinTextureString(c, size or ((opt and opt.size or 12) - 1)) end
  return string.format("%dg %ds %dc", c / 10000, (c / 100) % 100, c % 100)
end

local function duration(sec)
  sec = math.max(0, math.floor(sec))
  local h, m, s = math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- inline icon for text: game icons get cropped borders, arrows can be tinted
local function itex(path, size, r, g, b)
  if path:find("Icons") then
    return string.format("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", path, size, size)
  elseif r then
    return string.format("|T%s:%d:%d:0:0:32:32:0:32:0:32:%d:%d:%d|t", path, size, size, r, g, b)
  end
  return string.format("|T%s:%d:%d|t", path, size, size)
end

local function dprint(...)
  if debugMode then print("|cff33ff99NodoTracker debug:|r", ...) end
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
local function newBucket()
  return { since = time(), seconds = 0, xp = 0, kill = 0, quest = 0, earned = 0, spent = 0, levels = 0 }
end

local function syncBaseline()
  lastXP, lastMax, lastLevel = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
  lastMoney = GetMoney()
end

local function add(field, v)
  S[field] = S[field] + v
  A[field] = A[field] + v
end

-- XP source is matched by a short time window between the XP update and the
-- kill / quest signal (whichever arrives first).
local WINDOW = 1.5
local lastKill, lastQuest = 0, 0
local pending

-- Build a Lua pattern from the client's own (localized) kill message, e.g.
-- "%s dies, you gain %d experience." -> "^(.-) dies, you gain (%d+)"
local function killPattern()
  local fmt = COMBATLOG_XPGAIN_FIRSTPERSON
  if type(fmt) ~= "string" then return nil end
  local _, e = fmt:find("%%%d?%$?d")
  if not e then return nil end
  local head = fmt:sub(1, e)
  head = head:gsub("%%%d?%$?s", "\001")
  head = head:gsub("%%%d?%$?d", "\002")
  head = head:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  head = head:gsub("\001", "(.-)")
  head = head:gsub("\002", "(%%d+)")
  return "^" .. head
end
local KILL_PATTERN

local function killSignal(source)
  lastKill = GetTime()
  dprint("kill signal (" .. source .. ")")
  if pending and lastKill - pending.t <= WINDOW then
    add("kill", pending.amount); dprint("  -> pending " .. pending.amount .. " counted as kill"); pending = nil
  end
end

local function questSignal()
  lastQuest = GetTime()
  dprint("quest turned in")
  if pending and lastQuest - pending.t <= WINDOW then
    add("quest", pending.amount); dprint("  -> pending " .. pending.amount .. " counted as quest"); pending = nil
  end
end

---------------------------------------------------------------------------
-- Main window: built from the same parts as Blizzard's damage meter
-- (Blizzard_DamageMeter/DamageMeterSessionWindow.xml)
---------------------------------------------------------------------------
local HEADER = 32
local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil

local f = CreateFrame("Frame", "NodoTrackerFrame", UIParent)
f:SetSize(290, 120)
f:SetPoint("CENTER", 0, 200)
f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local p, _, rp, x, y = self:GetPoint()
  db.pos = { p, rp, x, y }
end)

local background = f:CreateTexture(nil, "BACKGROUND", nil, 0)
background:SetAtlas("damagemeters-background")
background:SetAllPoints()

local header = f:CreateTexture(nil, "BACKGROUND", nil, 1)
header:SetAtlas("ui-damagemeters-header-bar")
header:SetHeight(HEADER)
header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT")

-- [time] top left, like the session timer
local timer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
timer:SetJustifyH("LEFT")
timer:SetPoint("TOPLEFT", header, "TOPLEFT", 6, -9)

-- minimize button (red minus)
local close = CreateFrame("Button", nil, f)
close:SetSize(18, 19)
close:SetPoint("TOPRIGHT", header, "TOPRIGHT", -3, -5)
close:SetNormalAtlas("ui-questtrackerbutton-collapse-all")
close:SetPushedAtlas("ui-questtrackerbutton-collapse-all-pressed")
close:SetHighlightAtlas("ui-questtrackerbutton-red-highlight", "ADD")

-- settings gear (same atlas states as DamageMeterSettingsDropdownButton)
local gear = CreateFrame("DropdownButton", nil, f)
gear:SetSize(27, 27)
gear:SetPoint("RIGHT", close, "LEFT", -2, -2)
gear.Icon = gear:CreateTexture(nil, "ARTWORK")
gear.Icon:SetAllPoints()
local function gearState()
  local a = "common-dropdown-a-button-settings"
  if gear:IsMouseOver() and gear.down then a = a .. "-pressedhover"
  elseif gear:IsMouseOver() then a = a .. "-hover"
  elseif gear.down then a = a .. "-pressed"
  elseif gear:IsMenuOpen() then a = a .. "-open" end
  gear.Icon:SetAtlas(a .. "-shadowless", true)
end
gear:HookScript("OnEnter", gearState)
gear:HookScript("OnLeave", gearState)
gear:HookScript("OnMouseDown", function() gear.down = true; gearState() end)
gear:HookScript("OnMouseUp", function() gear.down = false; gearState() end)
gearState()

-- type dropdown (yellow arrow) with the mode name next to it
local modeDD = CreateFrame("DropdownButton", nil, f, "WowStyle1ArrowDropdownTemplate")
modeDD:SetPoint("TOPLEFT", timer, "TOPRIGHT", 0, 6)
modeDD.hasShadow = false
if modeDD.OnButtonStateChanged then modeDD:OnButtonStateChanged() end
local modeName = modeDD:CreateFontString(nil, "OVERLAY", "GameFontNormalMed1")
modeName:SetJustifyH("LEFT"); modeName:SetWordWrap(false)
modeName:SetPoint("LEFT", modeDD.Arrow or modeDD, "RIGHT", 0, 3)
modeName:SetPoint("RIGHT", gear, "LEFT", -5, 3)

---------------------------------------------------------------------------
-- Content rows (icon | label | value) and sub lines
---------------------------------------------------------------------------
local lines = {}

local function makeRow(iconPath)
  local row = CreateFrame("Frame", nil, f)
  row.kind = "row"
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAtlas("ui-damagemeters-bar-shadowbg")
  row.bg:SetAllPoints(); row.bg:SetAlpha(0.6)

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetPoint("LEFT", 2, 0)
  row.icon:SetTexture(iconPath)
  if iconPath:find("Icons") then row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
  row.icon:SetAlpha(0.85)

  row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.right:SetPoint("RIGHT", -6, 0); row.right:SetJustifyH("RIGHT")
  row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.left:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
  row.left:SetJustifyH("LEFT"); row.left:SetWordWrap(false)

  lines[#lines + 1] = row
  return row
end

local function makeSub()
  local row = CreateFrame("Frame", nil, f)
  row.kind = "sub"
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("RIGHT", -6, 0)
  row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)
  lines[#lines + 1] = row
  return row
end

local L = {}
L.level   = makeRow(ICON.level)
L.levelSub = makeSub()
L.xp      = makeRow(ICON.xp)
L.xpSub   = makeSub()
L.gold    = makeRow(ICON.coin)
L.goldSub = makeSub()

---------------------------------------------------------------------------
-- Style & layout
---------------------------------------------------------------------------
local function rowHeight() return math.max(opt.icon, opt.size + 6) end

local function applyStyle()
  local font = (FONTS[opt.font] or FONTS[1])[2]
  local h = rowHeight()
  for _, row in ipairs(lines) do
    if row.kind == "row" then
      row.left:SetFont(font, opt.size, "OUTLINE")
      row.right:SetFont(font, opt.size, "OUTLINE")
      row.icon:SetSize(h - 2, h - 2)
      row:SetHeight(h)
    else
      row.text:SetFont(font, math.max(7, opt.size - 2), "OUTLINE")
      row:SetHeight(opt.size + 4)
      row.text:SetPoint("LEFT", h + 6, 0)
    end
  end
  background:SetAlpha(opt.alpha)
  f:SetScale(opt.scale)
  f:SetWidth(opt.width)
end

local function layout(visible)
  local y = -HEADER + 2
  for _, row in ipairs(lines) do
    if visible[row] then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", f, "TOPLEFT", 2, y)
      row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, y)
      row:Show()
      y = y - row:GetHeight() - (row.kind == "row" and 1 or 0)
    else
      row:Hide()
    end
  end
  f:SetHeight(-y + 6)
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------
local function isSession() return (db.tab or "session") == "session" end

function f.render()
  if not S or not opt then return end
  local sess = isSession()
  local B = sess and S or A
  local hours = math.max(B.seconds, 1) / 3600
  local other = math.max(0, B.xp - B.kill - B.quest)
  local net = B.earned - B.spent
  local isz = math.max(8, opt.size)
  local ssz = math.max(7, opt.size - 2)
  local visible = {}

  timer:SetText("[" .. duration(B.seconds) .. "]")
  modeName:SetText(sess and "This Session" or ("Overall " .. GREY .. date("%Y-%m-%d", B.since) .. "|r"))

  local lvl = UnitLevel("player")
  local maxLvl = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
  if lvl < maxLvl then
    local cur, max = UnitXP("player"), math.max(1, UnitXPMax("player"))
    local rate = S.xp / (math.max(S.seconds, 1) / 3600)
    local eta = rate > 0 and duration((max - cur) / rate * 3600) or "–"
    L.level.left:SetText("Level " .. lvl .. " " .. itex(ICON.next, isz - 2) .. " " .. (lvl + 1))
    L.level.right:SetText(GREY .. "ETA |r" .. eta)
    L.levelSub.text:SetText(GOLD .. math.floor(cur / max * 100) .. "%|r  " .. num(max - cur) .. GREY .. " XP left|r"
      .. GREY .. "   (|r" .. num(cur) .. GREY .. " / |r" .. num(max) .. GREY .. ")|r")
    visible[L.level] = true
    visible[L.levelSub] = true
  end

  L.xp.left:SetText("Experience")
  if sess then
    L.xp.right:SetText(num(B.xp / hours) .. GREY .. "/h|r")
  else
    L.xp.right:SetText(num(B.xp))
  end
  visible[L.xp] = true

  local sub = itex(ICON.sword, ssz + 2) .. " " .. num(B.kill)
    .. GREY .. "  +  |r" .. itex(ICON.quest, ssz + 2) .. " " .. num(B.quest)
  if other > 0 then sub = sub .. GREY .. "  +  |r" .. itex(ICON.other, ssz + 2) .. " " .. num(other) end
  if sess then sub = num(B.xp) .. GREY .. "   (|r" .. sub .. GREY .. ")|r" end
  if B.levels > 0 then sub = sub .. GOLD .. "   +" .. B.levels .. " lvl|r" end
  L.xpSub.text:SetText(sub)
  visible[L.xpSub] = true

  local arrow = net >= 0 and itex(ICON.up, isz, 64, 220, 64) or itex(ICON.down, isz, 230, 60, 60)
  L.gold.left:SetText("Gold")
  if sess then
    L.gold.right:SetText(arrow .. " " .. money(net / hours) .. GREY .. "/h|r")
  else
    L.gold.right:SetText(arrow .. " " .. money(net))
  end
  visible[L.gold] = true

  local gsub = itex(ICON.up, ssz + 2, 64, 220, 64) .. " " .. money(B.earned, ssz)
    .. GREY .. "  /  |r" .. itex(ICON.down, ssz + 2, 230, 60, 60) .. " " .. money(B.spent, ssz)
  if sess then
    local netArrow = net >= 0 and itex(ICON.up, ssz + 2, 64, 220, 64) or itex(ICON.down, ssz + 2, 230, 60, 60)
    gsub = netArrow .. " " .. money(net, ssz) .. GREY .. "   (|r" .. gsub .. GREY .. ")|r"
  end
  L.goldSub.text:SetText(gsub)
  visible[L.goldSub] = true

  layout(visible)
end

local acc = 0
f:SetScript("OnUpdate", function(_, dt)
  if not S then return end
  S.seconds = S.seconds + dt
  A.seconds = A.seconds + dt
  acc = acc + dt
  if acc >= 1 then acc = 0; f.render() end
end)
f:HookScript("OnShow", function() f.render() end)

local function setTab(tab) db.tab = tab; f.render() end
local function resetSession()
  S = newBucket(); db.session = S; syncBaseline(); f.render()
  print("|cff33ff99NodoTracker:|r Session reset.")
end
local function resetOverall()
  local old = A.xp
  A = newBucket(); db.all = A
  print("|cff33ff99NodoTracker:|r Overall stats reset (was " .. num(old) .. " XP).")
  f.render()
end

---------------------------------------------------------------------------
-- Settings: registered in Blizzard's own options (Options -> AddOns)
---------------------------------------------------------------------------
local category

local function registerSettings()
  if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
  category = Settings.RegisterVerticalLayoutCategory("NodoTracker")

  local function onChange() applyStyle(); f.render() end
  local function addSetting(key, name)
    local setting = Settings.RegisterAddOnSetting(category, "NodoTracker_" .. key, key, opt,
      Settings.VarType.Number, name, DEFAULTS[key])
    setting:SetValueChangedCallback(onChange)
    return setting
  end

  local function fontOptions()
    local c = Settings.CreateControlTextContainer()
    for i, fnt in ipairs(FONTS) do c:Add(i, fnt[1]) end
    return c:GetData()
  end
  Settings.CreateDropdown(category, addSetting("font", "Font"), fontOptions, "Font used for all rows.")

  local function slider(key, name, minV, maxV, step, fmt, tooltip)
    local o = Settings.CreateSliderOptions(minV, maxV, step)
    o:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, fmt)
    Settings.CreateSlider(category, addSetting(key, name), o, tooltip)
  end
  local plain = function(v) return tostring(math.floor(v + 0.5)) end
  local pct = function(v) return math.floor(v * 100 + 0.5) .. "%" end
  slider("size",  "Font Size",  8,   22,  1,    plain, "Text size of the rows.")
  slider("icon",  "Icon Size",  12,  40,  1,    plain, "Size of the row icons.")
  slider("width", "Width",      200, 440, 10,   plain, "Width of the window.")
  slider("scale", "Scale",      0.5, 2.0, 0.05, pct,   "Scales the whole window.")
  slider("alpha", "Background", 0,   1,   0.05, pct,   "Opacity of the window background.")

  Settings.RegisterAddOnCategory(category)
end

local function openSettings()
  if InCombatLockdown() then
    print("|cff33ff99NodoTracker:|r Settings can't be opened in combat.")
    return
  end
  if category then Settings.OpenToCategory(category:GetID()) end
end

---------------------------------------------------------------------------
-- Menus (Blizzard menu system, same as the damage meter)
---------------------------------------------------------------------------
local function modeMenu(_, root)
  root:CreateRadio("This Session", function() return isSession() end, function() setTab("session") end)
  root:CreateRadio("Overall",      function() return not isSession() end, function() setTab("all") end)
end
modeDD:SetupMenu(modeMenu)

gear:SetupMenu(function(_, root)
  root:CreateButton("Settings", openSettings)
  root:CreateDivider()
  root:CreateButton("Reset Session", resetSession)
  root:CreateButton("Reset Overall", resetOverall)
  root:CreateDivider()
  root:CreateButton("Hide Window", function() f:Hide(); db.hidden = true end)
end)
gear:HookScript("OnMouseUp", function() C_Timer.After(0, gearState) end)

close:SetScript("OnClick", function() f:Hide(); db.hidden = true end)
close:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Hide (/ntr to show)"); GameTooltip:Show()
end)
close:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_XP_UPDATE")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("QUEST_TURNED_IN")
ev:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
-- No COMBAT_LOG_EVENT_UNFILTERED: on 12.x clients registering it is a blocked
-- action for addons. Kills are detected via the XP chat message instead.

ev:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "ADDON_LOADED" and a1 == ADDON then
    NodoTrackerDB = NodoTrackerDB or {}
    db = NodoTrackerDB
    db.all = db.all or newBucket()
    A = db.all
    db.opt = db.opt or {}
    for k, v in pairs(DEFAULTS) do if db.opt[k] == nil then db.opt[k] = v end end
    opt = db.opt
    KILL_PATTERN = killPattern()
    if db.pos then f:ClearAllPoints(); f:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4]) end
    registerSettings(); applyStyle()
    if db.hidden then f:Hide() end

  elseif event == "PLAYER_ENTERING_WORLD" then
    if a1 or not db.session then db.session = newBucket() end
    S = db.session
    syncBaseline()
    f.render()

  elseif not S then
    return

  elseif event == "PLAYER_XP_UPDATE" then
    local cur, max, lvl = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    local gain
    if lvl > lastLevel then
      gain = (lastMax - lastXP) + cur
      add("levels", lvl - lastLevel)
    else
      gain = cur - lastXP
    end
    if gain > 0 then
      add("xp", gain)
      local now = GetTime()
      if now - lastQuest <= WINDOW then
        add("quest", gain); dprint("+" .. gain .. " XP -> quest")
      elseif now - lastKill <= WINDOW then
        add("kill", gain); dprint("+" .. gain .. " XP -> kill")
      else
        pending = { amount = gain, t = now }; dprint("+" .. gain .. " XP -> waiting for signal")
      end
    end
    lastXP, lastMax, lastLevel = cur, max, lvl
    f.render()

  elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
    if issecretvalue and issecretvalue(a1) then dprint("chat: <secret>"); return end
    dprint("chat: " .. tostring(a1))
    if KILL_PATTERN and type(a1) == "string" and a1:find(KILL_PATTERN) then killSignal("chat") end

  elseif event == "QUEST_TURNED_IN" then
    questSignal()

  elseif event == "PLAYER_MONEY" then
    local now = GetMoney()
    local d = now - lastMoney
    if d > 0 then add("earned", d) elseif d < 0 then add("spent", -d) end
    lastMoney = now
    f.render()
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_NODOTRACKER1 = "/ntr"
SLASH_NODOTRACKER2 = "/nodotracker"
SlashCmdList.NODOTRACKER = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "reset" then
    resetSession()
  elseif msg == "config" or msg == "options" then
    openSettings()
  elseif msg == "debug" then
    debugMode = not debugMode
    print("|cff33ff99NodoTracker:|r debug " .. (debugMode and "on" or "off")
      .. " | kill pattern: " .. tostring(KILL_PATTERN))
  elseif msg == "" or msg == "toggle" then
    if f:IsShown() then f:Hide(); db.hidden = true else f:Show(); db.hidden = false end
  else
    print("|cff33ff99NodoTracker:|r /ntr (show/hide), /ntr reset (new session), /ntr config, /ntr debug")
  end
end
