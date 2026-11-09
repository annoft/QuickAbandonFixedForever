--[[--------------------------------------------------------------------------
	QuickAbandonFixedForever.lua

	Forever port (game type "camelot", TOC Interface 16001) of QuickAbandonFixed
	(Retail, TOC Interface 120100). Alt + click a quest to abandon it without
	Blizzard's confirmation dialog.

	Port notes (see README.md for the full list):
	  1. The quest log on this branch is Blizzard's QuestMapFrame, so the click
	     hook target is resolved at runtime instead of being hard-coded, with the
	     classic QuestLogFrame entry point as a defensive fallback.
	  2. Blizzard's quest UI is loaded on demand here, so every hook is installed
	     from an event-driven, idempotent installer instead of at file scope.
	  3. /qaf prints which hooks are actually live, so the port can be verified
	     in the client with one command.
----------------------------------------------------------------------------]]

local ADDON_NAME = ...

local PREFIX = "|cff33ff99Quick Abandon|r: "

local hooks = {
	questLog = nil,		-- "QuestMapLogTitleButton" | "QuestLogTitleButton" | nil
}

-- Last click seen by each hook. Blizzard's objective tracker header registers
-- for "LeftButtonUp"/"RightButtonUp" (Blizzard_ObjectiveTrackerBlock.lua:383),
-- so the mouseButton value is the *Up* variant; recording it keeps the failure
-- mode visible in /qaf instead of guessing.
local diagnostics = {
	questLogClick = nil,
	trackerClick = nil,
}

local function Print(message)
	local chatFrame = DEFAULT_CHAT_FRAME
	if chatFrame and chatFrame.AddMessage then
		chatFrame:AddMessage(PREFIX .. tostring(message))
	end
end

-- Accepts the plain and the "Up" variant of the left mouse button, because
-- RegisterForClicks decides which one a Blizzard button actually delivers.
local function IsLeftClick(mouseButton)
	return mouseButton == nil
		or mouseButton == "LeftButton"
		or mouseButton == "LeftButtonUp"
end

local function IsAbandonModifierDown()
	if type(IsAltKeyDown) == "function" then
		return IsAltKeyDown()
	end
	if type(IsLeftAltKeyDown) == "function" and IsLeftAltKeyDown() then
		return true
	end
	if type(IsRightAltKeyDown) == "function" and IsRightAltKeyDown() then
		return true
	end
	return false
end

local function GetQuestLabel(questID)
	if type(GetQuestLink) == "function" then
		local link = GetQuestLink(questID)
		if link then
			return link
		end
	end
	if C_QuestLog and type(C_QuestLog.GetTitleForQuestID) == "function" then
		local title = C_QuestLog.GetTitleForQuestID(questID)
		if title and title ~= "" then
			return title
		end
	end
	return tostring(questID)
end

local function CanAbandonQuest(questID)
	if type(questID) ~= "number" then
		return false
	end
	if not (C_QuestLog and type(C_QuestLog.CanAbandonQuest) == "function") then
		return false
	end
	if not (C_QuestLog and type(C_QuestLog.IsOnQuest) == "function") then
		return false
	end
	return C_QuestLog.CanAbandonQuest(questID) and C_QuestLog.IsOnQuest(questID)
end

-- Sends the abandonment request. Mirrors the Retail original: select, mark for
-- abandonment, abandon. Returns true when a request was sent.
function QuickAbandonFixedForever_Abandon(questID)
	if not IsAbandonModifierDown() then
		return false
	end
	if not CanAbandonQuest(questID) then
		return false
	end
	if not (C_QuestLog and type(C_QuestLog.SetSelectedQuest) == "function"
		and type(C_QuestLog.SetAbandonQuest) == "function"
		and type(C_QuestLog.AbandonQuest) == "function") then
		return false
	end

	C_QuestLog.SetSelectedQuest(questID)
	C_QuestLog.SetAbandonQuest()
	C_QuestLog.AbandonQuest()

	Print("Quest abandoned: " .. GetQuestLabel(questID))
	return true
end

local function InstallQuestLogHook()
	if hooks.questLog then
		return true
	end

	-- Modern quest log (QuestMapFrame): the title button carries the questID.
	if type(_G.QuestMapLogTitleButton_OnClick) == "function" then
		hooks.questLog = "QuestMapLogTitleButton"
		hooksecurefunc("QuestMapLogTitleButton_OnClick", function(button, mouseButton)
			local questID = type(button) == "table" and button.questID or nil
			local sent = false
			if IsLeftClick(mouseButton) then
				sent = QuickAbandonFixedForever_Abandon(questID)
			end
			diagnostics.questLogClick = string.format("%s id=%s sent=%s",
				tostring(mouseButton), tostring(questID), tostring(sent))
		end)
		return true
	end

	-- Classic quest log (QuestLogFrame): the button carries the log index.
	if type(_G.QuestLogTitleButton_OnClick) == "function" then
		hooks.questLog = "QuestLogTitleButton"
		hooksecurefunc("QuestLogTitleButton_OnClick", function(button, mouseButton)
			local logIndex = type(button) == "table" and type(button.GetID) == "function" and button:GetID() or nil
			local questID = nil
			if logIndex and C_QuestLog and type(C_QuestLog.GetQuestIDForLogIndex) == "function" then
				questID = C_QuestLog.GetQuestIDForLogIndex(logIndex)
			end
			local sent = false
			if IsLeftClick(mouseButton) then
				sent = QuickAbandonFixedForever_Abandon(questID)
			end
			diagnostics.questLogClick = string.format("%s index=%s id=%s sent=%s",
				tostring(mouseButton), tostring(logIndex), tostring(questID), tostring(sent))
		end)
		return true
	end

	return false
end

-- Hooks installed on tracker targets, keyed by the hooked object.
local trackerHookTargets = {}

-- The same click can reach two hooks (frame + mixin wrapper); collapse them.
local lastTrackerClick = { questID = nil, at = -100 }

-- hooksecurefunc(table, "method", fn) forwards the *original argument list*, so
-- a colon call arrives as (self, block, mouseButton) and a plain call as
-- (block, mouseButton). Locate the two values by shape instead of position: the
-- block is the first table carrying a numeric id, the button is the first
-- string.
local function ParseTrackerArgs(...)
	local count = select("#", ...)
	local block, mouseButton
	for i = 1, count do
		local value = select(i, ...)
		local valueType = type(value)
		if valueType == "string" then
			if mouseButton == nil then
				mouseButton = value
			end
		elseif valueType == "table" and block == nil and type(value.id) == "number" then
			block = value
		end
	end
	if block == nil and count >= 2 then
		local second = select(2, ...)
		if type(second) == "table" then
			block = second
		end
	end
	return block, mouseButton
end

local function DescribeArgs(...)
	local count = select("#", ...)
	local types = {}
	for i = 1, count do
		types[i] = type((select(i, ...)))
	end
	return count, table.concat(types, ",")
end

local function TrackerClickHandler(...)
	local block, mouseButton = ParseTrackerArgs(...)
	local questID = type(block) == "table" and block.id or nil
	local sent = false
	if IsLeftClick(mouseButton) then
		local now = type(GetTime) == "function" and GetTime() or 0
		local duplicate = questID ~= nil
			and questID == lastTrackerClick.questID
			and (now - lastTrackerClick.at) < 0.15
		if not duplicate then
			sent = QuickAbandonFixedForever_Abandon(questID)
			lastTrackerClick.questID = questID
			lastTrackerClick.at = now
		end
	end
	local count, types = DescribeArgs(...)
	diagnostics.trackerClick = string.format("%s id=%s sent=%s argc=%d types=%s",
		tostring(mouseButton), tostring(questID), tostring(sent), count, types)
end

local function HookTrackerMethod(target, label)
	if type(target) ~= "table" then
		return false
	end
	if trackerHookTargets[target] then
		return true
	end
	if type(target.OnBlockHeaderClick) ~= "function" then
		return false
	end
	trackerHookTargets[target] = label
	hooksecurefunc(target, "OnBlockHeaderClick", TrackerClickHandler)
	return true
end

local function HeaderFallbackHandler(header, mouseButton)
	local block = nil
	if type(header) == "table" and type(header.GetParent) == "function" then
		block = header:GetParent()
	end
	TrackerClickHandler(block, mouseButton)
end

local function InstallTrackerHook()
	-- The live module frame has to be hooked directly. QuestObjectiveTracker is
	-- declared in XML with mixin="QuestObjectiveTrackerMixin", and Mixin() copies
	-- the mixin's methods onto the frame. Patching the mixin table after the
	-- frame exists never reaches the code that actually handles the click
	-- (Blizzard_QuestObjectiveTracker.lua is loaded before the .xml that creates
	-- the frame, which is why Blizzard's own camelot override file also sits
	-- between them in the TOC).
	local frameHooked = HookTrackerMethod(_G.QuestObjectiveTracker, "QuestObjectiveTracker")

	-- Patch the mixin as well, for a module frame created after this point.
	HookTrackerMethod(_G.QuestObjectiveTrackerMixin, "QuestObjectiveTrackerMixin")

	-- Last resort: only when no module frame exists at all.
	if not frameHooked then
		local headerMixin = _G.ObjectiveTrackerBlockHeaderMixin
		if type(headerMixin) == "table" and type(headerMixin.OnClick) == "function"
			and not trackerHookTargets[headerMixin] then
			trackerHookTargets[headerMixin] = "ObjectiveTrackerBlockHeaderMixin"
			hooksecurefunc(headerMixin, "OnClick", HeaderFallbackHandler)
		end
	end

	return frameHooked
end

local loader = CreateFrame("Frame")

local function TryInstallHooks()
	local questLogReady = InstallQuestLogHook()
	local trackerReady = InstallTrackerHook()
	if questLogReady and trackerReady then
		loader:UnregisterAllEvents()
	end
end

-- Blizzard's quest UI (QuestMapFrame, Blizzard_ObjectiveTracker) is loaded on
-- demand on this branch, so retry the install whenever new Blizzard modules or
-- a refreshed quest log make the hook targets available.
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("QUEST_LOG_UPDATE")
loader:SetScript("OnEvent", TryInstallHooks)

-- Report state, so the port can be verified in the client with /qaf.
local function DescribeQuestLogHook()
	if hooks.questLog == "QuestMapLogTitleButton" then
		return "QuestMapFrame (QuestMapLogTitleButton_OnClick)"
	elseif hooks.questLog == "QuestLogTitleButton" then
		return "QuestLogFrame (QuestLogTitleButton_OnClick)"
	end
	return "not installed"
end

local function DescribeTrackerHook()
	local parts = {}
	local function Add(label)
		parts[#parts + 1] = label
	end
	if trackerHookTargets[_G.QuestObjectiveTracker] then
		Add("QuestObjectiveTracker (live module frame)")
	end
	if trackerHookTargets[_G.QuestObjectiveTrackerMixin] then
		Add("QuestObjectiveTrackerMixin (for frames created later)")
	end
	if trackerHookTargets[_G.ObjectiveTrackerBlockHeaderMixin] then
		Add("ObjectiveTrackerBlockHeaderMixin (fallback)")
	end
	if #parts == 0 then
		return "not installed"
	end
	return table.concat(parts, " + ")
end

local function DescribeApi()
	local parts = {}
	parts[#parts + 1] = type(C_QuestLog) == "table" and "C_QuestLog" or "no C_QuestLog"
	for _, name in ipairs({ "SetSelectedQuest", "SetAbandonQuest", "AbandonQuest", "CanAbandonQuest", "IsOnQuest" }) do
		if not (C_QuestLog and type(C_QuestLog[name]) == "function") then
			parts[#parts + 1] = "missing C_QuestLog." .. name
		end
	end
	parts[#parts + 1] = type(IsAltKeyDown) == "function" and "IsAltKeyDown" or "missing IsAltKeyDown"
	parts[#parts + 1] = type(GetQuestLink) == "function" and "GetQuestLink" or "no GetQuestLink"
	return table.concat(parts, ", ")
end

SLASH_QUICKABANDONFIXEDFOREVER1 = "/qaf"
SLASH_QUICKABANDONFIXEDFOREVER2 = "/quickabandon"
SlashCmdList["QUICKABANDONFIXEDFOREVER"] = function()
	TryInstallHooks()

	local _, _, _, interfaceVersion = GetBuildInfo()
	Print("status (" .. tostring(ADDON_NAME) .. ")")
	Print("  client interface: " .. tostring(interfaceVersion))
	Print("  quest log hook: " .. DescribeQuestLogHook())
	Print("  objective tracker hook: " .. DescribeTrackerHook())
	Print("  api: " .. DescribeApi())
	Print("  last quest log click: " .. tostring(diagnostics.questLogClick or "none yet"))
	Print("  last tracker click: " .. tostring(diagnostics.trackerClick or "none yet"))
	Print("  usage: hold Alt and left-click a quest title in the quest log or its tracked header")
end
