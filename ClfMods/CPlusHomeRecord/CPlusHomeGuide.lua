--[[
	CPlusHomeGuide : guide the player, in the game, to one recorded item.

	The search page ( home_search.html ) has a "guide in game" button on every
	result. It copies a line like

	  CPLUSHOME2 1 1500 1528 800 828 1000000001 1000000002 1000000003 | <house name> | <house> -> <floor> -> <box> -> <bag> -> <item>

	- the area of the house ( its facet, then x from and to, then y from and
	to; "-" when the search page does not know it ), then the ids from the box
	standing on the floor down to the item, then after "|" the house's name,
	and after a second "|" what to show. An item in a jewel box carries one
	word more in front of the first "|" - "J" and the pages the record saw it
	on ( "J1.3", or "J" on its own when the record has none ). A line without
	that word is read the plain way. The Home Search icon ( action
	6030 ) opens a window; paste the line there ( Ctrl+V ) and press Enter:

	  - a magenta arrow goes over the box,
	  - opening a box or bag on the way puts a magenta frame round the slot of
	    the next bag, or of the item ( grid view only; other views are told in
	    chat, once per container ). A jewel box has no slots to light, so for
	    an item in one the window gives the page instead,
	  - the window shows where the guide goes and how it is going, and has a
	    button that stops the guide.

	The same icon closes the window again. The guide ends when the window is
	closed ( whichever way ) or the button stops it, when another line is
	pasted, or when the UI is loaded again.

	The house is told by its area and named by its name, both as the search
	page keeps them: a house's number is only the number one
	character registered it under, and another character may have given the
	same house another. So the line carries no number, and the houses this
	character registered are not looked at. The line the search page copies
	for Home Record's Paste the areas window ( AREA_TAG ) is not read: the
	player is told which window takes it.

	  script CPlusHomeGuide.toggle()   -- open or close the window ( the icon )

	Kept light:

	  - **Nothing runs while not guiding.** No OnUpdate in the .mod, no timer,
	    no event handler. What the rest of the UI does at any time is look at
	    CPlusHomeGuide.Active when a container opens or closes
	    ( CPlusHomeRecord.onInitialize / onShutdown ) - one field, once.
	  - While guiding, a look every TICK_SECONDS ( one ClfCommon check listener,
	    put in when the guide starts and taken out when it ends ). It asks the
	    game two things about the box - whether it knows it, and how far it
	    is - as light as the house's area it also compares.
	  - **Each window is made once**, when first needed - the pasting window,
	    the arrow and the frame - and after that only shown, hidden, attached
	    and moved. EC gives back next to no memory for a destroyed window
	    ( only a UI reload does ). The arrow is never made again; the frame
	    only if it has gone.
	  - What is kept is a few numbers and one line of text. Nothing is
	    registered with RegisterWindowData: the containers read are open ones,
	    which Default registered itself.

	The arrow. It attaches to a box with no ObjectInfo registered ( measured
	in game ). Left on while the box went out of range,
	it stayed where it last was, near the hotbar, and was still there when the
	player came back ( in game ). So the look decides by whether
	the game knows the box ( IsValidObject, GetDistanceFromPlayer ), not by
	where the arrow is: not known, the arrow is taken off and hidden; known, it
	is taken off, put on the box and shown at every look, as Default does its
	own arrow every frame ( Interface.lua:1037, :1176-1193 ). That this brings
	it back over a box that is in range again is not measured. The house's
	area only chooses what the window says ( "enter <house name>" ).

	The frame is one window. While a container on the way is open, it is a
	child of that container's grid ( <window>GridViewScrollChild ) and anchored
	to the slot ( <window>GridViewSocket<gridIndex> - the item's gridIndex in
	ContainedItems, as ClfContnrWin.updateObject finds it and names the
	socket from it ), so it scrolls and is cut off
	with the grid. Before that container's window goes, it is moved back under
	Root and hidden ( CPlusHomeRecord.onShutdown calls closing ), since a child
	goes with its parent.
]]

LoadResources( "./UserInterface/" .. SystemData.Settings.Interface.customUiName .. "/ClfMods/CPlusHomeRecord", "CPlusHomeGuide.xml", "CPlusHomeGuide.xml" )

CPlusHomeGuide = {}

-- Whether a guide is on. Read by CPlusHomeRecord's container wrappers; the one
-- thing looked at when nothing is being guided.
CPlusHomeGuide.Active = false


local WINDOW = "CPlusHomeGuideWindow"
local INPUT = WINDOW .. "Input"
local ARROW_TEMPLATE = "CPlusHomeGuideArrow"
local ARROW = "CPlusHomeGuideArrowWindow"
local FRAME_TEMPLATE = "CPlusHomeGuideFrame"
local FRAME = "CPlusHomeGuideFrameWindow"

--[[
	The pasted line, as home_search.js writes it ( guideLine ):

	  CPLUSHOME2 <area> <ids> [<mark>] | <house name> | <what to show>

	the tag; the area of the house, AREA_WORDS whole numbers - its facet, then
	x from and to, then y from and to - or NO_AREA when the search page does
	not know it; then 2 to 10 ids ( box to item ), all whole decimal numbers.
	The house's name is what stands between the first "|" and the second, and
	what to show is everything after the second, "|" and all. A change of
	shape changes the tag. The search page's lines keep to these.
]]
local TAG = "CPLUSHOME2"
-- The tag of the line the search page copies for Home Record's Paste the
-- areas window ( CPlusHomeArea.lua TAG ). Such a line is not read here either.
local AREA_TAG = "CPLUSAREA1"
local NO_AREA = "-"
local AREA_WORDS = 5                -- facet, min x, max x, min y, max y
--[[
	The largest facet and coordinates an area is read with. The sizes of the
	maps, in tiles: maps 0 and 1 are 7168 x 4096, 2 is 2304 x 1600, 3 is
	2560 x 2048, 4 is 1448 x 1448 and 5 is 1280 x 4096. There are six maps, as
	Default's MapCommon.NumFacets says ( MapCommon.lua:20 ). A tile's x is
	below 7168 and its y below 4096 on every one of them.
]]
local MAX_FACET = 5
local MAX_X = 7167
local MAX_Y = 4095
--[[
	The longest house name read. The search page cuts a name to it, and the
	window puts the name in front of "enter the house" on the state line,
	which it has to fit ( CPlusHomeGuide.xml $parentState maxchars ).
]]
local NAME_MAX = 20
local MIN_IDS = 2                   -- a box and the item in it, the shortest the page writes
local MAX_IDS = 10                  -- CPlusHomeRecord looks 10 containers up at most ( MAX_PARENT_DEPTH )
local MAX_ID = 2147483647           -- the largest id a 31 bit serial can be
local MAX_DIGITS = string.len( tostring( MAX_ID ) )  -- longer is refused before tonumber

--[[
	An item in a jewel box: the word before "|" is this mark,
	and what follows it are the pages the record saw the item on, joined by
	".". A jewel box shows what it holds in a gump, fifty to a page, and its
	slots cannot be lit - the page the record saw is what the window gives
	instead. The mark on its own means the record has no page for the item.
	A line without the mark is read the plain way.
]]
local JEWEL_MARK = "J"
local MAX_PAGE = 9999               -- the largest page number taken
local MAX_PAGES = 3                 -- how many pages the mark carries at most

--[[
	A scroll in a scroll book: the word before "|" is this mark,
	and nothing follows it. A book shows its scrolls in a gump of their own and
	they have no object id at all, so the way ends at the book itself - one id
	where the book stands on the floor, which is fewer than any other line
	carries. The arrow goes on that one as on any first id, and there is no slot
	to light: what to look for is in what the window shows. A line without the
	mark is read the plain way, MIN_IDS and all.
]]
local BOOK_MARK = "B"
local MIN_IDS_BOOK = 1              -- the book itself, when it stands on the floor

--[[
	A map or a SOS in a Davies' locker: read as the book mark is -
	the way ends at the locker's block, one id where it stands on the floor, and
	nothing in it can be lit - but what the state line says is to open the
	locker, not the book ( arrowTailW ).
]]
local LOCKER_MARK = "L"

-- The arrow: the size Default gives its own ( Interface.lua:1173 ), and the
-- colour of the frame as well - magenta, which none of the notoriety colours
-- Default tints its arrow with is ( Source/NameColor.lua:13-21 ).
local ARROW_SCALE = 0.4
local TINT_R = 255
local TINT_G = 0
local TINT_B = 255

-- How often the guide looks at the arrow and the frame while guiding. Asked
-- for as "every 2 seconds or so".
local TICK_SECONDS = 2

-- After a container on the way opens, how long its slots are waited for
-- ( its grid is filled a frame or more after it opens ).
local PLACE_WAIT_SECONDS = 5

-- Text ( CPlusHomeTexts.lua, JPN and ENU ).
local TID_PREFIX = 1072
local TID_NOT_GUIDE = 1073
local TID_TARGET = 1074
local TID_ENTER_HOUSE = 1075
local TID_GET_CLOSER = 1076
local TID_ARROW_OUT = 1077          -- then the distance, then what jewelTailW gives
local TID_NOT_GUIDING = 1078
local TID_STOP = 1079
local TID_STOPPED = 1080
local TID_NOT_GRID = 1081
local TID_NOT_HERE = 1082
local TID_HINT = 1083
local TID_TITLE = 1084
local TID_FAILED = 1085
local TID_STARTED = 1086
local TID_ARROW_OUT_TAIL = 1088
local TID_ARROW_JEWEL = 1094        -- then the pages, then TID_ARROW_JEWEL_TAIL
local TID_ARROW_JEWEL_TAIL = 1095
local TID_ARROW_JEWEL_NONE = 1096   -- the jewel box, with no page recorded
local TID_PAGE_SEPARATOR = 1097     -- between two pages
local TID_ARROW_BOOK = 1118         -- a scroll book: nothing lights up
local TID_ARROW_LOCKER = 1143       -- a Davies' locker: nothing lights up either
local TID_AREA_LINE = 1135          -- a line for the Paste the areas window ( AREA_TAG )


--[[
	The guide, while one is on:
	  area ( the house's, nil when the line had NO_AREA ), houseName ( wide ),
	  path ( the ids, box first ), display ( wide ),
	  jewel ( the pages of an item in a jewel box, an empty list when the record
	  has none, nil for anything else ),
	  book ( true for a scroll in a scroll book: the way ends at the book and
	  nothing in it can be lit ), locker ( true for a map or a SOS in a Davies'
	  locker, which is book as well: only the state line tells them apart ),
	  serial ( of this guide ), told ( container ids already told about in chat ),
	  saidCloser, failed ( the kinds of failure already said )
]]
local Guide = nil
local Serial = 0

-- The id the arrow is attached to, and the container whose grid holds the
-- frame, or nil.
local ArrowOn = nil
local FrameIn = nil

-- The check listener of the look, while guiding.
local Tick = nil


----------------------------------------------------------------
-- Text
----------------------------------------------------------------

local function numA( n )
	if ( type( n ) ~= "number" ) then
		return "-"
	end
	return tostring( n )
end


local function txt( tid )
	return CPlusHomeTxt.getString( tid )
end


local function errorA( err )
	if ( type( err ) == "string" ) then
		return err
	end
	return "<" .. type( err ) .. ">"
end


-- One line to chat, after the prefix.
local function say( wide )
	local line = txt( TID_PREFIX ) .. wide
	local ok = pcall( function()
		WindowUtils.ChatPrint( line, SystemData.ChatLogFilters.SYSTEM )
	end )
	if ( not ok ) then
		pcall( Debug.PrintToChat, line )
	end
end


-- A failure, said once for each kind ( what ) in a guide - the look runs
-- every few seconds, and one kind said already does not hide another - and
-- always when there is no guide.
local function sayFailed( what, err )
	if ( Guide ) then
		if ( Guide.failed[ what ] ) then
			return
		end
		Guide.failed[ what ] = true
	end
	say( txt( TID_FAILED ) .. towstring( what .. ": " .. errorA( err ) ) )
end


----------------------------------------------------------------
-- The pasted line
----------------------------------------------------------------

-- A whole decimal number of at most MAX_DIGITS digits, or nil - nil as well
-- for a word that is not there.
local function wholeNumber( word )
	if ( type( word ) ~= "string" or string.len( word ) > MAX_DIGITS or string.find( word, "^%d+$" ) == nil ) then
		return nil
	end
	return tonumber( word )
end


--[[
	The area in the words from at on - facet, min x, max x, min y, max y - as
	{ facet, minX, maxX, minY, maxY }, the shape of a house CPlusHomeRecord
	registers. nil when any of them is not a whole number, is past MAX_FACET,
	MAX_X or MAX_Y, or a min is above its max.
]]
local function areaOf( words, at )
	local facet = wholeNumber( words[ at ] )
	local minX = wholeNumber( words[ at + 1 ] )
	local maxX = wholeNumber( words[ at + 2 ] )
	local minY = wholeNumber( words[ at + 3 ] )
	local maxY = wholeNumber( words[ at + 4 ] )
	if ( facet == nil or minX == nil or maxX == nil or minY == nil or maxY == nil ) then
		return nil
	end
	if ( facet > MAX_FACET or maxX > MAX_X or maxY > MAX_Y or minX > maxX or minY > maxY ) then
		return nil
	end
	return { facet = facet, minX = minX, maxX = maxX, minY = minY, maxY = maxY }
end


--[[
	The pages in a jewel mark ( "1.3" ), or nil when they are not pages. The
	mark on its own gives an empty list: an item in a jewel box whose record
	has no page for it. More than MAX_PAGES, or a page that is not a number in
	1..MAX_PAGE, is not a line this reads.
	The dots are read loosely ( "3.", "0002" pass ) - no such form gives a wrong page.
]]
local function jewelPages( text )
	local pages = {}
	if ( text == "" ) then
		return pages
	end
	for part in string.gmatch( text, "[^%.]+" ) do
		local page = wholeNumber( part )
		if ( page == nil or page < 1 or page > MAX_PAGE or #pages >= MAX_PAGES ) then
			return nil
		end
		pages[ #pages + 1 ] = page
	end
	return pages
end


-- Wide text without the spaces round it, or nil when nothing is left. An
-- empty wide string is never handed to a wstring routine ( they return a
-- narrow string for it, Default Source/WindowUtils.lua:412-417 ).
local function trimmedW( text )
	if ( type( text ) ~= "wstring" or text == L"" ) then
		return nil
	end
	local ok, trimmed = pcall( wstring.trim, text )
	if ( not ok or type( trimmed ) ~= "wstring" or trimmed == L"" ) then
		return nil
	end
	return trimmed
end


--[[
	The house's name and what to show, from what follows the first "|" of a
	line: the name is what stands before the second "|", trimmed, and what to
	show is everything after it ( nil when nothing is there, or there is no
	second "|" ). The name is nil when there is none, or when it is longer than
	NAME_MAX.
]]
local function nameAndDisplay( rest )
	if ( type( rest ) ~= "wstring" or rest == L"" ) then
		return nil, nil
	end
	local nameW = rest
	local display = nil
	local bar = wstring.find( rest, L"|", 1, true )
	if ( bar ) then
		nameW = bar > 1 and wstring.sub( rest, 1, bar - 1 ) or L""
		display = trimmedW( wstring.sub( rest, bar + 1 ) )
	end
	local name = trimmedW( nameW )
	if ( name == nil or wstring.len( name ) > NAME_MAX ) then
		return nil, nil
	end
	return name, display
end


--[[
	The guide in a pasted line, or nil when it is not one: { area, houseName,
	path, display, jewel, book, locker }. A line for the Paste the areas window
	gives nil and TID_AREA_LINE, which says where it goes, rather than that it
	is no guide. Only the part before the first "|" is made narrow, and read as
	numbers; the rest stays wide as it was pasted, since a wstring through
	tostring loses its Japanese ( measured ). Whatever is wrong, nothing fails:
	the answer is nil.
]]
local function parseGuide( text )
	if ( type( text ) ~= "wstring" or text == L"" ) then
		return nil
	end
	local head = text
	local rest = nil
	local bar = wstring.find( text, L"|", 1, true )
	if ( bar ) then
		head = bar > 1 and wstring.sub( text, 1, bar - 1 ) or L""
		rest = wstring.sub( text, bar + 1 )
	end
	if ( head == L"" ) then
		return nil
	end
	local ok, narrow = pcall( WStringToString, head )
	if ( not ok or type( narrow ) ~= "string" ) then
		return nil
	end

	local words = {}
	for word in string.gmatch( narrow, "%S+" ) do
		words[ #words + 1 ] = word
	end

	-- A line for the Paste the areas window is told apart before anything
	-- else is looked at, so that the player hears where it goes.
	if ( words[ 1 ] == AREA_TAG ) then
		return nil, TID_AREA_LINE
	end

	-- The name is what the window calls the house, so a line without one is
	-- not read; what to show may be left out.
	local houseName, display = nameAndDisplay( rest )
	if ( houseName == nil ) then
		return nil
	end

	-- The jewel mark, when the last word is one, comes off before the ids are
	-- counted and read: a line without it is read the plain way.
	local jewel = nil
	local last = words[ #words ]
	if ( last ~= nil and string.sub( last, 1, 1 ) == JEWEL_MARK ) then
		jewel = jewelPages( string.sub( last, 2 ) )
		if ( jewel == nil ) then
			return nil
		end
		words[ #words ] = nil
	end

	-- The book mark comes off the same way, and takes the shortest way down
	-- to one id for that line alone. That the line carried it is kept: what
	-- the state line says of the way ahead turns on it. The locker mark is
	-- read the same way, and kept apart for the state line.
	local least = MIN_IDS
	local book = false
	local locker = false
	if ( words[ #words ] == BOOK_MARK or words[ #words ] == LOCKER_MARK ) then
		book = true
		locker = ( words[ #words ] == LOCKER_MARK )
		least = MIN_IDS_BOOK
		words[ #words ] = nil
	end

	if ( words[ 1 ] ~= TAG ) then
		return nil
	end
	-- The area, or NO_AREA: with no area the house is not looked for, and the
	-- player is told to get closer.
	local area = nil
	local first = 3
	if ( words[ 2 ] ~= NO_AREA ) then
		area = areaOf( words, 2 )
		if ( area == nil ) then
			return nil
		end
		first = 2 + AREA_WORDS
	end
	local count = #words - first + 1
	if ( count < least or count > MAX_IDS ) then
		return nil
	end
	local path = {}
	for i = first, #words do
		local id = wholeNumber( words[ i ] )
		if ( id == nil or id < 1 or id > MAX_ID ) then
			return nil
		end
		path[ #path + 1 ] = id
	end
	return { area = area, houseName = houseName, path = path, display = display, jewel = jewel, book = book, locker = locker }
end


-- What the window and chat show for the guide: the pasted text, or, when
-- there was none, the house's name and the ids. The search page always
-- writes the text ( 80 at most ); without it, a long name and ten ids can
-- run past the target label ( maxchars 160 ) - only in a line made by hand.
local function targetW( guide )
	if ( guide.display ) then
		return guide.display
	end
	local ids = {}
	for i = 1, #guide.path do
		ids[ #ids + 1 ] = "#" .. numA( guide.path[ i ] )
	end
	return guide.houseName .. towstring( " " .. table.concat( ids, " > " ) )
end


----------------------------------------------------------------
-- The window
----------------------------------------------------------------

local function setLabel( name, wide )
	pcall( LabelSetText, WINDOW .. name, wide )
end


--[[
	The state line, written only when it changes. n goes into two of the
	lines: the distance between the two halves of "the arrow is out"
	( TID_ARROW_OUT ), and what failed after "did not work" ( TID_FAILED ).
	"Enter the house" ( TID_ENTER_HOUSE ) has the guide's house name in front.
]]
--[[
	What comes after the distance in "the arrow is out". A scroll in a scroll
	book and an item in a jewel box both sit where no slot can be lit, so
	neither gets the line about the next slot lighting up: the book's says to
	open the book and look, and the jewel box's gives the pages the record saw
	the item on ( with no page recorded, only that it is in the box ).
	Anything else gets the plain line about the next slot.
]]
local function arrowTailW()
	if ( Guide and Guide.locker ) then
		return txt( TID_ARROW_LOCKER )
	end
	if ( Guide and Guide.book ) then
		return txt( TID_ARROW_BOOK )
	end
	local pages = Guide and Guide.jewel
	if ( pages == nil ) then
		return txt( TID_ARROW_OUT_TAIL )
	end
	if ( #pages == 0 ) then
		return txt( TID_ARROW_JEWEL_NONE )
	end
	local text = txt( TID_ARROW_JEWEL )
	for i = 1, #pages do
		if ( i > 1 ) then
			text = text .. txt( TID_PAGE_SEPARATOR )
		end
		text = text .. towstring( numA( pages[ i ] ) )
	end
	return text .. txt( TID_ARROW_JEWEL_TAIL )
end


local shownState = nil
local function setState( tid, n )
	local key = numA( tid ) .. "/" .. ( type( n ) == "string" and n or numA( n ) )
	if ( key == shownState ) then
		return
	end
	shownState = key
	local text
	if ( tid == TID_ENTER_HOUSE ) then
		text = Guide.houseName .. txt( tid )
	elseif ( tid == TID_ARROW_OUT ) then
		text = txt( tid ) .. towstring( numA( n ) ) .. arrowTailW()
	elseif ( tid == TID_FAILED ) then
		text = txt( tid ) .. towstring( n )
	else
		text = txt( tid )
	end
	setLabel( "State", text )
end


local function showTarget()
	if ( Guide ) then
		setLabel( "Target", txt( TID_TARGET ) .. targetW( Guide ) )
	else
		setLabel( "Target", L"" )
	end
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
	pcall( ButtonSetText, WINDOW .. "Clear", txt( TID_STOP ) )
	shownState = nil
	if ( Guide ) then
		showTarget()
	else
		setState( TID_NOT_GUIDING )
	end
	return true
end


----------------------------------------------------------------
-- The arrow
----------------------------------------------------------------

-- The arrow window, made the first time it is needed and kept after that -
-- hidden until it is on a box. Returns whether it is there.
local function ensureArrow()
	if ( DoesWindowExist( ARROW ) ) then
		return true
	end
	local ok, err = pcall( CreateWindowFromTemplate, ARROW, ARROW_TEMPLATE, "Root" )
	if ( not ok or not DoesWindowExist( ARROW ) ) then
		sayFailed( "CreateWindowFromTemplate " .. ARROW, ok and "no window" or err )
		return false
	end
	pcall( WindowSetScale, ARROW, ARROW_SCALE )
	pcall( WindowSetTintColor, ARROW, TINT_R, TINT_G, TINT_B )
	pcall( AnimatedImageStartAnimation, ARROW .. "Anim", 1, true, false, 0.0 )
	pcall( WindowSetShowing, ARROW, false )
	return true
end


local function detachArrow()
	if ( ArrowOn ~= nil and DoesWindowExist( ARROW ) ) then
		pcall( DetachWindowFromWorldObject, ArrowOn, ARROW )
	end
	ArrowOn = nil
end


--[[
	Puts the arrow on the box: taken off what it is on, put on the box, then
	shown - the order Default moves its own arrow to a creature in
	( Interface.lua:1176-1193 ). It is shown only once it is on; when putting
	it on fails, it is hidden. Returns true, or false and what failed.
]]
local function attachArrow( id )
	if ( not ensureArrow() ) then
		return false, "CreateWindowFromTemplate"
	end
	detachArrow()
	local ok, err = pcall( AttachWindowToWorldObject, id, ARROW )
	if ( not ok ) then
		pcall( WindowSetShowing, ARROW, false )
		sayFailed( "AttachWindowToWorldObject", err )
		return false, "AttachWindowToWorldObject"
	end
	ArrowOn = id
	pcall( WindowSetShowing, ARROW, true )
	return true
end


local function hideArrow()
	detachArrow()
	if ( DoesWindowExist( ARROW ) ) then
		pcall( WindowSetShowing, ARROW, false )
	end
end


--[[
	How far the box is when the game knows it ( it is in the range the game
	keeps things in ), or nil - and, when asking failed, what failed. Asked
	as Default asks about an object ( Source/ObjectHandle.lua:419 ); a
	negative distance is the game not knowing it ( Source/OverheadText.lua:379 ).
	A call that throws, or a distance that is not a number, is said in chat
	( once for each kind ) and counts as not known.
]]
local function boxDistance( id )
	local okValid, valid = pcall( IsValidObject, id )
	if ( not okValid ) then
		sayFailed( "IsValidObject", valid )
		return nil, "IsValidObject"
	end
	if ( not valid ) then
		return nil
	end
	local okDist, dist = pcall( GetDistanceFromPlayer, id )
	if ( not okDist ) then
		sayFailed( "GetDistanceFromPlayer", dist )
		return nil, "GetDistanceFromPlayer"
	end
	if ( type( dist ) ~= "number" or dist ~= dist ) then
		sayFailed( "GetDistanceFromPlayer", "not a number: " .. type( dist ) )
		return nil, "GetDistanceFromPlayer"
	end
	if ( dist < 0 ) then
		return nil
	end
	return dist
end


----------------------------------------------------------------
-- The frame
----------------------------------------------------------------

local function containerWindow( id )
	return "ContainerWindow_" .. numA( id )
end


-- Whether a container is open now, and not the one closing.
local function isOpen( id, closing )
	if ( id == closing ) then
		return false
	end
	local data = WindowData and WindowData.ContainerWindow
	return type( data ) == "table" and data[ id ] ~= nil and DoesWindowExist( containerWindow( id ) )
end


-- The frame window, made the first time it is needed ( and again only if it
-- has gone, which a container taking it along when it closes would do ).
local function ensureFrame()
	if ( DoesWindowExist( FRAME ) ) then
		return true
	end
	FrameIn = nil
	local ok, err = pcall( CreateWindowFromTemplate, FRAME, FRAME_TEMPLATE, "Root" )
	if ( not ok or not DoesWindowExist( FRAME ) ) then
		sayFailed( "CreateWindowFromTemplate " .. FRAME, ok and "no window" or err )
		return false
	end
	pcall( WindowSetTintColor, FRAME .. "Image", TINT_R, TINT_G, TINT_B )
	pcall( WindowSetShowing, FRAME, false )
	return true
end


-- The frame back under Root, hidden.
local function parkFrame()
	if ( FrameIn ~= nil and DoesWindowExist( FRAME ) ) then
		pcall( WindowSetShowing, FRAME, false )
		pcall( WindowClearAnchors, FRAME )
		pcall( WindowSetParent, FRAME, "Root" )
	end
	FrameIn = nil
end


-- Something about a container, said once per guide.
local function tellOnce( id, tid )
	local key = numA( id ) .. "/" .. numA( tid )
	if ( Guide.told[ key ] ) then
		return
	end
	Guide.told[ key ] = true
	say( txt( tid ) )
end


--[[
	The slot the frame should be round now: in the deepest open container on
	the way, the slot of the next id. Returns the container, the slot window
	and whether that is final - "wait" ( false ) while the container's items or
	slots are not there yet.
]]
local function slotNow( closing )
	local path = Guide.path
	for k = #path - 1, 1, -1 do
		local container = path[ k ]
		if ( isOpen( container, closing ) ) then
			if ( ContainerWindow.ViewModes[ container ] ~= "Grid" ) then
				tellOnce( container, TID_NOT_GRID )
				return nil, nil, true
			end
			local data = WindowData.ContainerWindow[ container ]
			local items = data.ContainedItems
			local count = data.numItems
			if ( type( items ) ~= "table" or type( count ) ~= "number" or count < 1 ) then
				return nil, nil, false
			end
			for i = 1, count do
				local item = items[ i ]
				if ( item and item.objectId == path[ k + 1 ] ) then
					local slot = containerWindow( container ) .. "GridViewSocket" .. numA( item.gridIndex )
					if ( not DoesWindowExist( slot ) ) then
						return nil, nil, false
					end
					return container, slot, true
				end
			end
			tellOnce( container, TID_NOT_HERE )
			return nil, nil, true
		end
	end
	return nil, nil, true
end


--[[
	Puts the frame round the slot it should be round, or parks it. Returns
	whether that was settled ( false: the container is still filling in ).
]]
local function placeFrame( closing )
	if ( not Guide ) then
		return true
	end
	local container, slot, settled = slotNow( closing )
	if ( container == nil ) then
		parkFrame()
		return settled
	end
	if ( not ensureFrame() ) then
		return true
	end
	if ( FrameIn ~= container ) then
		pcall( WindowSetShowing, FRAME, false )
		pcall( WindowClearAnchors, FRAME )
		local ok, err = pcall( WindowSetParent, FRAME, containerWindow( container ) .. "GridViewScrollChild" )
		if ( not ok ) then
			sayFailed( "WindowSetParent", err )
			FrameIn = nil
			return true
		end
		FrameIn = container
	end
	pcall( WindowClearAnchors, FRAME )
	pcall( WindowAddAnchor, FRAME, "center", slot, "center", 0, 0 )
	local okScale, scale = pcall( WindowGetScale, slot )
	if ( okScale and type( scale ) == "number" ) then
		pcall( WindowSetScale, FRAME, scale )
	end
	pcall( WindowSetShowing, FRAME, true )
	return true
end


----------------------------------------------------------------
-- The look, every TICK_SECONDS while guiding
----------------------------------------------------------------

--[[
	Whether the game knows the box decides the arrow, wherever the player is:
	known, the arrow is put on the box again at every look, as Default puts
	its own arrow on again every frame ( Interface.lua:1037 -> :1176, :1184 )
	- so a box that went out of range and came back between two looks is
	caught as well; not known, it is taken off and hidden, so that it is not
	left where it last was. The state line says which, with the distance when
	known; when the box is not known, the house's area chooses between "enter
	<house name>" and "the box is too far" - the latter as well when the line
	carried no area. Returns the state it set.
]]
local function look()
	if ( not Guide ) then
		return nil
	end
	local box = Guide.path[ 1 ]
	local dist, failedAsking = boxDistance( box )
	local shown
	if ( dist ~= nil ) then
		local on, failedAttaching = attachArrow( box )
		if ( on ) then
			shown = TID_ARROW_OUT
			setState( shown, math.floor( dist + 0.5 ) )
		else
			shown = TID_FAILED
			setState( shown, failedAttaching )
		end
	else
		if ( ArrowOn ~= nil ) then
			hideArrow()
		end
		local inside = nil
		if ( Guide.area ) then
			inside = CPlusHomeRecord.playerInArea( Guide.area )
		end
		if ( failedAsking ) then
			shown = TID_FAILED
			setState( shown, failedAsking )
		elseif ( inside == false ) then
			shown = TID_ENTER_HOUSE
			setState( shown )
		else
			shown = TID_GET_CLOSER
			setState( shown )
			if ( not Guide.saidCloser ) then
				Guide.saidCloser = true
				say( txt( TID_GET_CLOSER ) )
			end
		end
	end

	placeFrame()
	return shown
end


-- The look through pcall, with a failure said ( once ). Returns what the look
-- returns, or nil when it failed.
local function lookSafely()
	local ok, shown = pcall( look )
	if ( not ok ) then
		sayFailed( "look", shown )
		return nil
	end
	return shown
end


local function startTick()
	local now = ClfCommon.TimeSinceLogin
	local serial = Serial
	Tick = {
		begin = now,
		limit = math.huge,
		remove = false,
		nextAt = now + TICK_SECONDS,
	}
	local tick = Tick
	tick.check = function()
		return Guide ~= nil and Guide.serial == serial and ClfCommon.TimeSinceLogin >= tick.nextAt
	end
	tick.done = function()
		tick.nextAt = ClfCommon.TimeSinceLogin + TICK_SECONDS
		lookSafely()
	end
	-- A name of its own per guide: a listener only leaves ClfCommon's table
	-- once its limit has passed, the frame after the guide ends.
	ClfCommon.addCheckListener( "CPlusHomeGuide.look." .. numA( serial ), tick )
end


-- The look stops: its check says no from now on, and with its limit passed
-- ClfCommon takes it out ( in ClfCommon.processListenersCheck ).
local function stopTick()
	if ( Tick ) then
		Tick.limit = 0
		Tick = nil
	end
end


----------------------------------------------------------------
-- Starting and stopping
----------------------------------------------------------------

local function stopGuide()
	stopTick()
	hideArrow()
	parkFrame()
	Guide = nil
	CPlusHomeGuide.Active = false
	shownState = nil
	if ( DoesWindowExist( WINDOW ) ) then
		showTarget()
		setState( TID_NOT_GUIDING )
	end
end


local function startGuide( guide )
	stopGuide()
	Serial = Serial + 1
	guide.serial = Serial
	guide.told = {}
	guide.saidCloser = false
	guide.failed = {}
	Guide = guide
	CPlusHomeGuide.Active = true

	showTarget()
	say( txt( TID_STARTED ) .. L" / " .. txt( TID_TARGET ) .. targetW( guide ) )
	-- The first look at once ( the arrow, the state line, and a container on
	-- the way that is open already ). "Enter <house name>" goes to chat as well.
	if ( lookSafely() == TID_ENTER_HOUSE ) then
		say( guide.houseName .. txt( TID_ENTER_HOUSE ) )
	end
	startTick()
end


----------------------------------------------------------------
-- From the window and the icon
----------------------------------------------------------------

--[[
** Open or close the window ( the Home Search icon, action 6030 )
]]
function CPlusHomeGuide.toggle()
	if ( not ensureWindow() ) then
		return
	end
	local okShow, showing = pcall( WindowGetShowing, WINDOW )
	if ( okShow and showing ) then
		CPlusHomeGuide.close()
		return
	end
	pcall( WindowSetShowing, WINDOW, true )
	pcall( TextEditBoxSetText, INPUT, L"" )
	pcall( WindowAssignFocus, INPUT, true )
end


--[[
** Close the window ( the Home Search icon, the close button, a right click,
*  Esc in the box ). Closing it ends the guide, the way the button does
*  ( CPlusHomeGuide.clear ); the window is hidden even if that fails.
]]
function CPlusHomeGuide.close()
	if ( not DoesWindowExist( WINDOW ) ) then
		return
	end
	local okClear, errClear = pcall( CPlusHomeGuide.clear )
	if ( not okClear ) then
		sayFailed( "clear", errClear )
	end
	-- false: hidden, not closing, so later saves keep working
	-- ( Default WindowUtils.SaveWindowPosition ).
	local okPos, errPos = pcall( WindowUtils.SaveWindowPosition, WINDOW, false )
	Interface.ErrorTracker( okPos, errPos )
	pcall( WindowAssignFocus, INPUT, false )
	pcall( WindowSetShowing, WINDOW, false )
end


--[[
** Enter in the box: start the guide the pasted line describes. When reading
*  the box, or the line, fails, that is said as a failure ( in chat, once for
*  each kind, and on the state line ), not as a line that is not a guide.
]]
function CPlusHomeGuide.onEnter()
	local ok, text = pcall( TextEditBoxGetText, INPUT )
	if ( not ok or type( text ) ~= "wstring" ) then
		-- What it threw, or, when it gave something that is not wide text, its type.
		sayFailed( "TextEditBoxGetText", ok and ( "not a wstring: " .. type( text ) ) or text )
		setState( TID_FAILED, "TextEditBoxGetText" )
		return
	end
	local okParse, guide, refusal = pcall( parseGuide, text )
	if ( not okParse ) then
		sayFailed( "parseGuide", guide )
		setState( TID_FAILED, "parseGuide" )
		return
	end
	if ( guide == nil ) then
		local tid = refusal or TID_NOT_GUIDE
		shownState = nil
		setState( tid )
		say( txt( tid ) )
		return
	end
	pcall( TextEditBoxSetText, INPUT, L"" )
	-- The keys go back to the game, so that the player can walk at once.
	pcall( WindowAssignFocus, INPUT, false )
	local okStart, errStart = pcall( startGuide, guide )
	if ( not okStart ) then
		sayFailed( "start", errStart )
	end
end


--[[
** The button: stop the guide. The window stays open. Closing the window
*  stops the guide the same way ( CPlusHomeGuide.close ).
]]
function CPlusHomeGuide.clear()
	local wasOn = Guide ~= nil
	stopGuide()
	if ( wasOn ) then
		say( txt( TID_STOPPED ) )
	end
end


----------------------------------------------------------------
-- From CPlusHomeRecord's container wrappers ( only while guiding )
----------------------------------------------------------------

--[[
** A container opened. When it is on the way, its slot is waited for and the
*  frame put round it ( its grid fills in a frame or more after it opens ).
]]
function CPlusHomeGuide.opened( id )
	if ( not Guide ) then
		return
	end
	local onTheWay = false
	for k = 1, #Guide.path - 1 do
		if ( Guide.path[ k ] == id ) then
			onTheWay = true
			break
		end
	end
	if ( not onTheWay ) then
		return
	end
	local serial = Guide.serial
	ClfCommon.addCheckListener( "CPlusHomeGuide.place." .. numA( serial ) .. "." .. numA( id ), {
		check = function()
			if ( Guide == nil or Guide.serial ~= serial ) then
				return true
			end
			local ok, settled = pcall( placeFrame )
			if ( not ok ) then
				sayFailed( "place", settled )
				return true
			end
			return settled
		end,
		done = function() end,
		limit = ClfCommon.TimeSinceLogin + PLACE_WAIT_SECONDS,
	} )
end


--[[
** A container is closing ( before the original Shutdown ). The frame leaves
*  its grid first, then goes to the next container out on the way if that is
*  open.
]]
function CPlusHomeGuide.closing( id )
	if ( FrameIn == id ) then
		parkFrame()
	end
	placeFrame( id )
end


----------------------------------------------------------------
-- The UI going away ( .mod OnShutdown )
----------------------------------------------------------------

function CPlusHomeGuide.shutdown()
	stopTick()
	hideArrow()
	parkFrame()
	Guide = nil
	CPlusHomeGuide.Active = false
	if ( DoesWindowExist( WINDOW ) ) then
		local okPos, errPos = pcall( WindowUtils.SaveWindowPosition, WINDOW )
		Interface.ErrorTracker( okPos, errPos )
	end
end
