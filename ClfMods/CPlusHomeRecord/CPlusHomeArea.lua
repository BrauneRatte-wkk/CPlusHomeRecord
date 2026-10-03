--[[
	CPlusHomeArea : register on this character the houses the search page keeps.

	The search page ( home_search.html ) keeps a table of houses for each pair
	- an account and a shard - and numbers the houses itself.
	Its names tab has a button for each pair whose table holds a house, which
	copies one line:

	  CPLUSAREA1 1 0 1000 1027 500 527 2 1 1200 1223 1600 1623

	- the tag, then six whole numbers a house: its number, its facet, then x
	from and to, then y from and to. The Home Record icon's right-click menu
	has "Paste the areas" ( CPlusHomeRecord.lua addMenu ), which opens this
	window; paste the line there ( Ctrl+V ) and press Enter, and the houses are
	registered on this character under the page's numbers
	( CPlusHomeRecord.pasteAreas ):

	  - a number in the line is registered with its area, over whatever that
	    number held;
	  - a registered number not in the line whose area shares a tile with one
	    of the line's is cleared: a house held under two numbers has its boxes
	    recorded under the smaller, and the other number is never used;
	  - every other registered house is left as it is;
	  - recording is turned on.

	A line any part of which cannot be read, or with a house wider or taller
	than a house can be registered ( CPlusHomeRecord.AREA ), registers
	nothing, and the window says why. A guide text ( CPlusHomeGuide.lua )
	pasted here is told which window takes it, as this line pasted in the
	guide's window is. Whatever is refused, the window stays open with the box
	emptied and the keys in it, so that a line copied again goes in with
	Ctrl+V and Enter.

	  script CPlusHomeArea.open()   -- open the window ( the menu item )

	Keeping it light: nothing runs while the window is not in use - no
	OnUpdate, no timer, no handler. The window is made once, the first time it
	opens, and only shown and hidden after that ( EC gives back next to no
	memory for a destroyed window ).
]]

LoadResources( "./UserInterface/" .. SystemData.Settings.Interface.customUiName .. "/ClfMods/CPlusHomeRecord", "CPlusHomeArea.xml", "CPlusHomeArea.xml" )

CPlusHomeArea = {}


local WINDOW = "CPlusHomeAreaWindow"
local INPUT = WINDOW .. "Input"

--[[
	The pasted line, as home_search.js writes it ( areaLine ):

	  CPLUSAREA1 <number> <facet> <min x> <max x> <min y> <max y> ...

	HOUSE_WORDS whole decimal numbers a house, one to MAX_HOUSES houses, each
	number once. A change of shape changes the tag. The search page's lines
	keep to these, and so do the numbers of CPlusHomeRecord.lua and
	CPlusHomeGuide.lua named beside them.
]]
local TAG = "CPLUSAREA1"
local HOUSE_WORDS = 6               -- number, facet, min x, max x, min y, max y
local MAX_HOUSES = 9                -- CPlusHomeRecord.lua MAX_HOUSES: the houses a character can register
-- The largest facet and coordinates an area is read with: CPlusHomeGuide.lua
-- MAX_FACET, MAX_X and MAX_Y, where the sizes of the maps are written.
local MAX_FACET = 5
local MAX_X = 7167
local MAX_Y = 4095
-- The tag of the guide's lines ( CPlusHomeGuide.lua TAG ). Pasted here, such
-- a line is told to go to the Home Search icon's window.
local GUIDE_TAGS = { CPLUSHOME2 = true }

-- Text ( CPlusHomeTexts.lua, JPN and ENU ).
local TID_PREFIX = 1041             -- Home Record's own, as what pasting says in chat starts with it
local TID_FAILED = 1085             -- the guide's "did not work: "
local TID_TITLE = 1128
local TID_HINT = 1129
local TID_NOT_AREA = 1130
local TID_GUIDE_LINE = 1131
local TID_BAD_COUNT = 1132
local TID_BAD_HOUSE = 1133          -- then which house of the line it is, from the left, then TID_BAD_HOUSE_TAIL
local TID_BAD_HOUSE_TAIL = 1134
local TID_WIDE_HOUSE = 1171         -- then which house, then TID_WIDE_HOUSE_MID, the most tiles a side, TID_WIDE_HOUSE_TAIL
local TID_WIDE_HOUSE_MID = 1172
local TID_WIDE_HOUSE_TAIL = 1173


----------------------------------------------------------------
-- Text
----------------------------------------------------------------

local function txt( tid )
	return CPlusHomeTxt.getString( tid )
end


local function errorA( err )
	if ( type( err ) == "string" ) then
		return err
	end
	return "<" .. type( err ) .. ">"
end


-- One line to chat, after Home Record's prefix.
local function say( wide )
	local line = txt( TID_PREFIX ) .. wide
	local ok = pcall( function()
		WindowUtils.ChatPrint( line, SystemData.ChatLogFilters.SYSTEM )
	end )
	if ( not ok ) then
		pcall( Debug.PrintToChat, line )
	end
end


----------------------------------------------------------------
-- The pasted line
----------------------------------------------------------------

-- A whole decimal number, or nil - nil as well for a word that is not there.
-- Digits only: no sign, point, exponent or hex, which tonumber would take.
local function wholeNumber( word )
	if ( type( word ) ~= "string" or string.find( word, "^%d+$" ) == nil ) then
		return nil
	end
	return tonumber( word )
end


--[[
	The house in the HOUSE_WORDS words from at on, in the shape
	CPlusHomeRecord.pasteAreas takes: { n, facet, minX, maxX, minY, maxY }. nil
	when any of them is not a whole number, the number is not 1 to MAX_HOUSES,
	or the area is past MAX_FACET, MAX_X or MAX_Y or a min is above its max.
]]
local function houseIn( words, at )
	local n = wholeNumber( words[ at ] )
	local facet = wholeNumber( words[ at + 1 ] )
	local minX = wholeNumber( words[ at + 2 ] )
	local maxX = wholeNumber( words[ at + 3 ] )
	local minY = wholeNumber( words[ at + 4 ] )
	local maxY = wholeNumber( words[ at + 5 ] )
	if ( n == nil or facet == nil or minX == nil or maxX == nil or minY == nil or maxY == nil ) then
		return nil
	end
	if ( n < 1 or n > MAX_HOUSES ) then
		return nil
	end
	if ( facet > MAX_FACET or maxX > MAX_X or maxY > MAX_Y or minX > maxX or minY > maxY ) then
		return nil
	end
	return { n = n, facet = facet, minX = minX, maxX = maxX, minY = minY, maxY = maxY }
end


--[[
	The houses in a pasted line, in the order of the line - or nil and why not:
	a tid, and for a house that cannot be read, or is wider or taller than a
	house can be registered ( CPlusHomeRecord.areaFits ), which house of the
	line it is, counted from the left. Only a line every part of which reads
	gives houses: nothing is taken from a line read halfway. Whatever is
	wrong, nothing fails.
]]
local function parseAreas( text )
	if ( type( text ) ~= "wstring" or text == L"" ) then
		return nil, TID_NOT_AREA
	end
	local ok, narrow = pcall( WStringToString, text )
	if ( not ok or type( narrow ) ~= "string" ) then
		return nil, TID_NOT_AREA
	end

	local words = {}
	for word in string.gmatch( narrow, "%S+" ) do
		words[ #words + 1 ] = word
	end

	-- A guide text is told apart before anything else, so that the player
	-- hears which window takes it.
	if ( GUIDE_TAGS[ words[ 1 ] ] ) then
		return nil, TID_GUIDE_LINE
	end
	if ( words[ 1 ] ~= TAG ) then
		return nil, TID_NOT_AREA
	end

	local count = #words - 1
	if ( count < HOUSE_WORDS or count > HOUSE_WORDS * MAX_HOUSES or count % HOUSE_WORDS ~= 0 ) then
		return nil, TID_BAD_COUNT
	end
	local houses = {}
	local seen = {}
	for at = 2, #words, HOUSE_WORDS do
		local house = houseIn( words, at )
		if ( house == nil or seen[ house.n ] ) then
			return nil, TID_BAD_HOUSE, #houses + 1
		end
		if ( not CPlusHomeRecord.areaFits( house ) ) then
			return nil, TID_WIDE_HOUSE, #houses + 1
		end
		seen[ house.n ] = true
		houses[ #houses + 1 ] = house
	end
	return houses
end


----------------------------------------------------------------
-- The window
----------------------------------------------------------------

local function setLabel( name, wide )
	pcall( LabelSetText, WINDOW .. name, wide )
end


-- A failure, said on the state line and in chat.
local function sayFailed( what, err )
	local text = txt( TID_FAILED ) .. towstring( what .. ": " .. errorA( err ) )
	setLabel( "State", text )
	say( text )
end


-- The window, made the first time it is asked for. Returns whether it is there.
local function ensureWindow()
	if ( DoesWindowExist( WINDOW ) ) then
		return true
	end
	local ok, err = pcall( CreateWindow, WINDOW, false )
	if ( not ok or not DoesWindowExist( WINDOW ) ) then
		sayFailed( "CreateWindow " .. WINDOW, ok and "no window" or err )
		return false
	end
	local okPos, errPos = pcall( WindowUtils.RestoreWindowPosition, WINDOW )
	Interface.ErrorTracker( okPos, errPos )

	setLabel( "Title", txt( TID_TITLE ) )
	setLabel( "Hint", txt( TID_HINT ) )
	return true
end


--[[
** Open the window ( Home Record's right-click menu, "Paste the areas" ), with
*  the box empty and the keys in it, ready for Ctrl+V.
]]
function CPlusHomeArea.open()
	if ( not ensureWindow() ) then
		return
	end
	setLabel( "State", L"" )
	pcall( TextEditBoxSetText, INPUT, L"" )
	pcall( WindowSetShowing, WINDOW, true )
	pcall( WindowAssignFocus, INPUT, true )
end


--[[
** Close the window ( the close button, a right click, Esc in the box ).
]]
function CPlusHomeArea.close()
	if ( not DoesWindowExist( WINDOW ) ) then
		return
	end
	-- false: hidden, not closing, so later saves keep working
	-- ( Default WindowUtils.SaveWindowPosition ).
	local okPos, errPos = pcall( WindowUtils.SaveWindowPosition, WINDOW, false )
	Interface.ErrorTracker( okPos, errPos )
	pcall( WindowAssignFocus, INPUT, false )
	pcall( WindowSetShowing, WINDOW, false )
end


-- The box emptied, with the keys in it, as open() leaves it: a line copied
-- again goes in with Ctrl+V on its own, not after what was refused.
local function clearInput()
	pcall( TextEditBoxSetText, INPUT, L"" )
	pcall( WindowAssignFocus, INPUT, true )
end


--[[
** Enter in the box: register the houses of the pasted line on this character,
*  then close the window. A line that cannot be read changes nothing: why is
*  said on the state line and in chat, and the window stays open. When reading
*  the box, or registering, fails, that is said as a failure. Whenever the
*  window stays open, the box is emptied and keeps the keys ( clearInput ).
]]
function CPlusHomeArea.onEnter()
	local ok, text = pcall( TextEditBoxGetText, INPUT )
	if ( not ok or type( text ) ~= "wstring" ) then
		-- What it threw, or, when it gave something that is not wide text, its type.
		sayFailed( "TextEditBoxGetText", ok and ( "not a wstring: " .. type( text ) ) or text )
		clearInput()
		return
	end
	local okParse, houses, refusal, which = pcall( parseAreas, text )
	if ( not okParse ) then
		sayFailed( "parseAreas", houses )
		clearInput()
		return
	end
	if ( houses == nil ) then
		local why = txt( refusal )
		if ( refusal == TID_BAD_HOUSE ) then
			why = why .. towstring( tostring( which ) ) .. txt( TID_BAD_HOUSE_TAIL )
		elseif ( refusal == TID_WIDE_HOUSE ) then
			why = why .. towstring( tostring( which ) ) .. txt( TID_WIDE_HOUSE_MID )
				.. towstring( tostring( CPlusHomeRecord.AREA.MAX_SIDE ) ) .. txt( TID_WIDE_HOUSE_TAIL )
		end
		setLabel( "State", why )
		say( why )
		clearInput()
		return
	end
	-- Through a function, so that a missing CPlusHomeRecord fails inside pcall too.
	local okPaste, pasted = pcall( function()
		return CPlusHomeRecord.pasteAreas( houses )
	end )
	if ( not okPaste or pasted ~= true ) then
		sayFailed( "pasteAreas", okPaste and "refused" or pasted )
		clearInput()
		return
	end
	CPlusHomeArea.close()
end


----------------------------------------------------------------
-- The UI going away ( .mod OnShutdown )
----------------------------------------------------------------

function CPlusHomeArea.shutdown()
	if ( DoesWindowExist( WINDOW ) ) then
		local okPos, errPos = pcall( WindowUtils.SaveWindowPosition, WINDOW )
		Interface.ErrorTracker( okPos, errPos )
	end
end
