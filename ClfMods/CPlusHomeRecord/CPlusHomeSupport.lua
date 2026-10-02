--[[
	CPlusHomeSupport : the shared pieces the home record needs that CLifeUI
	does not have, kept in this folder so that the folder works when added to
	CLifeUI on its own.

	  - CPlusHomeRecord.protectedCall: calls a function with pcall and says in
	    the chat what failed, once for each key, under this module's own name
	    so that nothing is taken from ClfCommon.
	  - The two icons in the actions window ( 6029 and 6030 ), in the
	    category CPlus, with their drawings ( CPlusHomeIcons.xml ). The words
	    are in CPlusHomeTexts.lua.

	Loaded after CPlusHomeRecord.lua ( CPlusHomeRecord.mod ), whose table it
	adds to. Its initialize calls installActions.
]]

LoadResources( "./UserInterface/" .. SystemData.Settings.Interface.customUiName .. "/ClfMods/CPlusHomeRecord", "CPlusHomeIcons.xml", "CPlusHomeIcons.xml" )


----------------------------------------------------------------
-- Faults
----------------------------------------------------------------

-- The keys whose last call failed and was said.
local ReportedFails = {}

--[[
	func( arg ) through pcall. A failure is said in chat the first time only,
	and again after the key has once gone through: some of the work runs on
	every container and every page, and one fault said every time would fill
	the chat. Returns whether it went through.
]]
function CPlusHomeRecord.protectedCall( key, func, arg )
	if ( not func ) then
		return false
	end
	local ok, err = pcall( func, arg )
	if ( ok ) then
		ReportedFails[ key ] = nil
	elseif ( not ReportedFails[ key ] ) then
		ReportedFails[ key ] = true
		pcall( Debug.PrintToChat, towstring( "CPlusHomeRecord: " .. key .. " failed: " .. tostring( err ) ) )
	end
	return ok
end


----------------------------------------------------------------
-- The actions window
----------------------------------------------------------------

--[[
	The icons: { action id, icon id ( CPlusHomeIcons.xml ), name, what it does
	( CPlusHomeTexts.lua ), the macro }. A hotbar slot keeps three things of
	the icon put on it: the action id, the icon id and the macro text ( Default
	hotbar.lua writes the callback into the slot with UserActionSpeechSetText ).
	Nothing writes the text again at login, so none of the three is to change
	without putting the slots right as well.
]]
local ACTIONS = {
	{ 6029, 876029, 3022, 4022, L"script CPlusHomeRecord.show()" },
	{ 6030, 876030, 3023, 4023, L"script CPlusHomeGuide.toggle()" },
}

-- The icon whose hotbar slot gets the right-click menu ( CPlusHomeRecord.lua,
-- Hotbar menu ): the first of ACTIONS.
CPlusHomeRecord.MENU_ACTION = ACTIONS[ 1 ][ 1 ]

--[[
	The category the icons go in. Every CPlus module looks for it by this name
	and adds to it, and the first to come makes it, at the end of the list:
	Default counts its categories from 1 up ( ActionsWindow.lua table.getn ),
	so none is given a number of its own.
]]
local ACTION_GROUP = L"CPlus"

CPlusHomeRecord.InitActionData_org = nil


-- This module's rows in ActionData, and their numbers in the category CPlus.
-- A number the category already holds is not added again.
local function addActions()
	local data = ActionsWindow.ActionData
	local groups = ActionsWindow.Groups
	local group = nil
	for i = 1, #groups do
		if ( groups[ i ].nameString == ACTION_GROUP ) then
			group = groups[ i ]
			break
		end
	end
	if ( group == nil ) then
		group = { nameString = ACTION_GROUP, index = {} }
		groups[ #groups + 1 ] = group
	end

	local index = group.index
	for i = 1, #ACTIONS do
		local action = ACTIONS[ i ]
		data[ action[ 1 ] ] = {
			type            = SystemData.UserAction.TYPE_SPEECH_USER_COMMAND,
			iconId          = action[ 2 ],
			nameString      = CPlusHomeTxt.getString( action[ 3 ] ),
			detailString    = CPlusHomeTxt.getString( action[ 4 ] ),
			callback        = action[ 5 ],
			inActionWindow  = true,
		}
		local listed = false
		for j = 1, #index do
			if ( index[ j ] == action[ 1 ] ) then
				listed = true
				break
			end
		end
		if ( not listed ) then
			index[ #index + 1 ] = action[ 1 ]
		end
	end
end


--[[
	Wraps ActionsWindow.InitActionData, which Default calls every time the
	actions window is made, and which makes ActionData and the categories anew
	each time. The original ( and whatever wraps it inside this ) runs first.
]]
function CPlusHomeRecord.onInitActionData()
	CPlusHomeRecord.InitActionData_org()
	CPlusHomeRecord.protectedCall( "CPlusHomeRecord.addActions", addActions )
end


--[[
	An icon of this module on a hotbar is given its drawing again: an icon a
	module adds is not shown on the hotbar just after logging in. The same as
	ClfReActionsWindow.initFuncAndDatas does for CLifeUI's own.
]]
local function refreshHotbarIcons()
	local data = ActionsWindow.ActionData
	local SPEECH_USER_CMD = SystemData.UserAction.TYPE_SPEECH_USER_COMMAND
	for window, actionId in pairs( HotbarSystem.RegisteredSpellIcons ) do
		local mine = false
		for i = 1, #ACTIONS do
			if ( ACTIONS[ i ][ 1 ] == actionId ) then
				mine = true
				break
			end
		end
		local action = mine and data[ actionId ] or nil
		if ( action and DoesWindowExist( window ) ) then
			local slot = WindowGetId( window )
			local hotbarId = WindowGetId( WindowGetParent( window ) )
			if ( UserActionGetType( hotbarId, slot, 0 ) == SPEECH_USER_CMD ) then
				HotbarSystem.SetHotbarIcon( window, action.iconId )
			end
		end
	end
end


--[[
	Puts the icons into the actions window: wraps ActionsWindow.InitActionData
	once, makes the actions window again if it is there already, so that they
	are in it, and gives the icons on the hotbars their drawings.
]]
function CPlusHomeRecord.installActions()
	if ( CPlusHomeRecord.InitActionData_org ) then
		return
	end
	if ( ActionsWindow == nil or type( ActionsWindow.InitActionData ) ~= "function" ) then
		pcall( Debug.PrintToChat, L"CPlusHomeRecord : ActionsWindow.InitActionData not found, no icons in the actions window" )
		return
	end
	CPlusHomeRecord.InitActionData_org = ActionsWindow.InitActionData
	ActionsWindow.InitActionData = CPlusHomeRecord.onInitActionData

	if ( DoesWindowExist( "ActionsWindow" ) ) then
		local showing = WindowGetShowing( "ActionsWindow" )
		DestroyWindow( "ActionsWindow" )
		CreateWindow( "ActionsWindow", showing )
	end

	CPlusHomeRecord.protectedCall( "CPlusHomeRecord.hotbarIcons", refreshHotbarIcons )
end
