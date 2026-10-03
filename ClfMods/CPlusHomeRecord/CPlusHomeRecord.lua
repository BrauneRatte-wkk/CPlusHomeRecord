--[[
	CPlusHomeRecord : write out what is in the containers of your own houses.

	Inside one of your own houses, a container whose properties say it is
	locked down ( "Locked Down" or "Locked Down & Secure" ), or a container
	opened from inside one, is written to its own file when you close it:

	  logs/CPlusExport/home<house>_[<clock>]_<box id>_<serial>.txt

	The files are for a search page on the PC, built separately, that answers
	"which house, which box, and what is in it" - weapons and armour with every
	line of their properties. Nothing in this module reads the files back.

	  script CPlusHomeRecord.corner( 1 )   -- add where you stand as a corner of house 1
	  script CPlusHomeRecord.clear( 1 )    -- forget house 1
	  script CPlusHomeRecord.show()        -- houses, where you are, and which house that is
	  script CPlusHomeRecord.toggle()      -- recording ON / OFF ( ON unless turned off )

	The same four are on one hotbar icon, "Home Record" ( action 6029 ): a left
	click runs show(), and its right-click menu has the other three, with the
	house picked from a sub-menu. See the Hotbar menu section further down.
	The menu has one item more, "Paste the areas", which opens the window of
	CPlusHomeArea.lua: a line the search page copies, pasted there, registers the
	houses the page keeps under the page's numbers ( pasteAreas ).

	A house is the rectangle round the corners added to it, edges included, on
	one facet: two opposite corners, at most AREA.MAX_SIDE tiles a side. Height
	is not looked at: a house's floors all share one rectangle.

	The houses are registered on each character, and a house's number is only
	that character's. Every record carries the area of its house ( areaRow ),
	and the search page keeps a table of houses of its own for each account and
	shard, which tells houses apart by their areas.

	When things happen, and why then:

	  - **Deciding happens when a container opens.** Its parent is open at that
	    moment, so the chain of containers can be walked up to the one that is
	    locked down. Wrapped round ContainerWindow.Initialize.
	  - **Writing happens when it closes.** That is its final state, with
	    anything moved in or out while it was open, and it does not depend on
	    how long the contents take to arrive after opening ( never measured ).
	    Wrapped round ContainerWindow.Shutdown, and done before the original
	    runs: the original lets go of the items' ObjectInfo and of the
	    container's own data ( Default Source/ContainerWindow.lua:480-489 ).
	    A container still open when the client dies is not written.

	What it touches, and what it leaves alone:

	  - ItemProperties is registered when it is missing, and never unregistered.
	    Unregistering it from outside broke the property display once, and
	    CLifeUI itself leaves it registered ( ClfContnrWin.getInterestPropObj ).
	  - ObjectInfo is registered only for a moment: a walk up through the
	    containers that finds one not there registers it, reads it, and
	    unregisters again what it registered, and only that ( registering:
	    whether a container is recorded ). Default's
	    ReleaseRegisteredObjects only lets go of what Default registered itself
	    ( :90-97 ), so anything left registered here would stay for good. It was
	    already there for every item and box looked at in game, but
	    Default takes it away again - the target moving off an object, for one
	    ( decide ).
	  - ContainerWindow is never registered. Nothing else is unregistered.
	  - Nothing is moved, opened, closed or pressed.

	A cabinet opens no container window: it shows what it holds
	in a generic gump, fifty to a page, made again for every page turned. The
	jewel box, the dye tub cabinet and the armour refinement cabinet all do
	( CABINET_GUMP_IDS ). Their pages are gathered from the first one seen until
	the cabinet closes, and written then as one record, in the same file and
	format as any other box, with two records added that older readers pass
	over:

	  jewelbox <pages seen> <pages> <items gathered> <items in the box> <kind>
	      after time; the pages and the items in the box as its labels said,
	      and the kind: the tid of the name in the gump's title ( 1157694 the
	      jewel box, 1164139 the dye tub, 1165086 the armour refinement ). A
	      record written before the kind was in it is a jewel box's.
	  jewelpage <page>...
	      after each item's params: the pages the item was seen on

	An item record carries what its ObjectInfo says when it has one ( the dye
	tub cabinet's items do ), and where there is none the objectType is read
	from the name line when the line names the base item, "-" otherwise, with
	no hue. The box is the containerId the items on the page all carry, or else
	Interface.LastItem once its properties name it as the gump's title does:
	LastItem is whatever item was last used, so nothing is written for an id
	that does not answer for itself. It is closed when, a little after its
	window shuts down, no cabinet window has come in its place ( a turn of the
	page ). Wrapped round ClfjewelryBox.gumParse for the pages - which
	ClfGGMod.GGParseData calls for every generic gump - and, from the first
	cabinet on, round GenericGump.Shutdown; the items' ItemProperties are
	registered by ClfGGMod.getItemPropsInGump, as for ClfjewelryBox, and only
	the box's own is registered here. See the cabinet section.

	A scroll book is gathered the same way: the counts of each skill whose page
	the player opens, through the same two wrappers, written as one record when
	it closes - with book, booktier and bookskill records of its own. A Davies'
	locker too, page by page as the player turns them, with locker records of
	its own; for which block of it was used, a third wrapper, round
	Interface.ItemUseRequest, notes the item each use asks for. Nothing is
	pressed. See the sections of the scroll books and the lockers.

	**The files carry facts, not verdicts.** Whether an item is itself a
	container, whether that container has been recorded, whether a record is
	complete - the search page works those out from the lines. The one thing
	counted here is how many items had no properties to write.

	Wide strings are never passed through tostring or table.concat - a wstring
	through tostring loses its Japanese ( measured ) - and a file is
	never built by adding onto one growing string. Its pieces go into a table
	and are joined two at a time at the end ( joinW ).
]]

CPlusHomeRecord = {}

CPlusHomeRecord.Enable = true

-- The functions this wraps, as they were before. Set once; a second
-- initialize finds them set and does not wrap again.
CPlusHomeRecord.Initialize_org = nil
CPlusHomeRecord.Shutdown_org = nil
CPlusHomeRecord.CreateUserActionContextMenuOptions_org = nil
CPlusHomeRecord.ContextMenuCallback_org = nil
CPlusHomeRecord.JewelParse_org = nil
CPlusHomeRecord.GumpShutdown_org = nil
CPlusHomeRecord.ItemUseRequest_org = nil


--[[
	The locals on this file's outside ( the main chunk ). Lua 5.1 lets a function
	hold at most 200 at once, and past that the game cannot compile the file at
	all: CPlusHomeRecord is then nil, nothing is recorded and the icon does
	nothing. Keep them under 190, with room to spare. A new constant goes
	into the table of its
	kind ( DECIDED, CABINET, BOOK_PAGE, BOOK_BACK, CODE, TID_MENU, TID_PASTE, TID_AREA )
	rather than a local of its own.
]]

--[[
	How many houses can be registered.

	Nine leaves room without changing shape: a house number stays one digit,
	so the file name home<house>_ and the hotbar sub-menu of houses stay short.
	Each house keeps its own setting keys by number.
]]
local MAX_HOUSES = 9

--[[
	How large a house's area can be: at most MAX_SIDE tiles from side to side,
	along x and along y alike, its edges counted ( x 1000 to 1039 is 40 ), and
	at most MAX_CORNERS corners - two opposite corners make the rectangle.
	The largest house in UO is some 30 tiles a side.

	CPlusHomeArea.lua reads these from here ( CPlusHomeRecord.areaFits ), so
	the pasted areas keep to the same limit.
]]
CPlusHomeRecord.AREA = { MAX_SIDE = 40, MAX_CORNERS = 2 }

--[[
	How far up the chain of containers to look for a locked down one, counting
	the container itself as step 0.

	The deepest nesting measured is two: a box opened inside a chest.
	This is not sized to that. It is a guard, so that a chain that never reaches
	0 cannot walk for ever, and it is set well past any bag-in-a-bag a player
	keeps; a chain that comes back to an id already seen is stopped before it
	gets here.
]]
local MAX_PARENT_DEPTH = 10

--[[
	The property lines that mark a container as part of a house, by tid.
	Measured on the live client: secure containers carried 501644, a container
	that was only locked down carried 501643, and neither appeared on the
	backpack being worn or on a box sitting inside a chest.
]]
local TID_LOCKED_DOWN = 501643
local TID_LOCKED_DOWN_SECURE = 501644

--[[
	The property lines that say how much is inside a container, by tid. The
	first value after the line's @<tid> in PropertiesTidsParams is the count.

	Both measured on the live client, in the recorded files and in what the
	client said: 1073841 as "Contents: 3/125, Weight: 10" with params @1073841 3
	125 10, and 1072241 as "Contents: 5/125, Weight: 20/400" with params
	@1072241 5 125 20 400 ( example values ). The count matched the items directly inside plus
	the counts of the containers among them in every record looked at.

	Only these two are counted, and only for the chat line - a rough reminder
	of bags not yet opened. Whether other kinds of container use another tid
	has not been measured, and the file does not use this at all: the search
	page works out containers from the property lines itself.
]]
local TID_CONTENTS = 1073841
local TID_CONTENTS_WEIGHT = 1072241

-- The first line of every file, and the version of the format it announces.
-- The search page reads both; a change to the format changes the number.
-- Version 2 adds the base name as the item record's seventh field ( see
-- baseNameW ), and writes <br> and <p> inside a text field as a space
-- ( see fieldW ). The search page still reads version 1 files as they are.
-- The char record ( see charRow ) is added within version 2: it is one more
-- record, which a reader that does not know it passes over, as it does the
-- jewelbox and book records. The area record ( see areaRow ) is
-- added the same way.
local FORMAT_TAG = "CPLUS_HOME_RECORD"
local FORMAT_VERSION = "2"

--[[
	The tid of an item's base name - what the item is called before any
	crafter's mark or magic name - from its objectType: below 16384 the base
	names start at tid 1020000, from 16384 on at tid 1078872.

	Checked on the live client with GetStringFromTid, on 13 types taken from
	both ranges, below 16384 and from 16384 on.
]]
local BASE_NAME_TID_LOW = 1020000
local BASE_NAME_TID_HIGH = 1078872
local BASE_NAME_HIGH_FROM = 16384

-- Files go to logs/CPlusExport/, a folder of the home record's own, given to
-- ClfUtil.exportStr as its folder. The player makes it in the game's logs
-- folder: EC does not create a folder that is not there, and a write into one
-- fails without a word. CLifeUI's own default folder is not used: CLifeUI's
-- other exports go there too.
local EXPORT_DIR = "CPlusExport"
local EXPORT_PREFIX = "home"

-- What a number that could not be read is written as.
local NO_NUMBER = "-"

local KEY_ENABLE = "CPlusHomeRecordEnable"

-- The text in CPlusHomeTexts.lua, in both the JPN and the ENU table.
local TID_PREFIX = 1041
local TID_HOUSE = 1042
local TID_CORNERS = 1043
local TID_FACET = 1044
local TID_RANGE_X = 1045
local TID_RANGE_Y = 1046
local TID_OTHER_FACET = 1047
local TID_CLEARED = 1048
local TID_BAD_NUMBER = 1050
local TID_BAD_NUMBER_END = 1051
local TID_RECORDING = 1052
local TID_NOW_AT = 1053
local TID_INSIDE = 1054
local TID_OUTSIDE = 1055
local TID_UNDECIDED = 1056
local TID_ITEMS = 1057
local TID_NO_PROPS = 1058
local TID_WRITE_FAILED = 1059
local TID_NO_POSITION = 1060
local TID_CORNER_ADDED = 1061
local TID_CONTAINERS = 1062
local TID_HOLDING = 1063
local TID_NO_HOUSES = 1064
-- The items of the right-click menu ( see the Hotbar menu section ).
local TID_MENU = { CORNER = 1065, CLEAR = 1066, SHOW = 1067, RECORDING = 1068, PASTE = 1124 }
local TID_OPEN = 1069
local TID_CLOSE = 1070
local TID_UNREGISTERED = 1071
local TID_PAGES = 1089
local TID_NOT_CABINET = 1090
local TID_FIRST_LINE = 1091
local TID_TITLE_TID = 1092
local TID_BOX_NAME = 1093

-- The scroll books.
local TID_BOOK_SKILLS = 1099
local TID_BOOK_TIERS = 1108
local TID_BOOK_NAME_TID = 1114
local TID_BOOK_UNGROUPED = 1162        -- then how many, then TID_BOOK_UNGROUPED_TAIL
local TID_BOOK_UNGROUPED_TAIL = 1163

-- What pasting the areas says in chat ( CPlusHomeRecord.pasteAreas ).
local TID_PASTE = { DONE = 1125, CLEARED = 1126, OVERLAP = 1127 }
-- A corner not added, and the hint after a second corner on the same line:
-- FULL, then how many, then FULL_TAIL / WIDE, then how many tiles, then
-- WIDE_TAIL, then the area as it is / LINE. Each then ends with AGAIN, the
-- menu item that clears a house, and AGAIN_TAIL.
local TID_AREA = { FULL = 1164, FULL_TAIL = 1165, WIDE = 1166, WIDE_TAIL = 1167, LINE = 1168, AGAIN = 1169, AGAIN_TAIL = 1170 }

local TAB = L"\t"
local NL = L"\r\n"
local SEPARATOR = L" / "

-- The registered houses by number, nil for a number with no corners.
local Houses = {}

--[[
	The containers that were opened inside a house and are waiting to be
	written, by id. An entry goes in when a container that should be recorded
	opens, and comes out when that container closes - before anything is
	written, so that a failed write cannot leave it behind. Entries whose
	window has gone without closing through Shutdown are swept out whenever
	another container opens.
]]
local Opened = {}

-- How many files this UI load has written. Part of the file name, so that
-- closing the same container twice in one second still makes two names.
local Serial = 0

--[[
	The items used, as Interface.ItemUseRequest is handed them ( Use.note ):
	latest is the latest one not yet spent, { item, serial }, or nil; serial
	how many uses have been noted. A Davies' locker takes its box from it.
	Filled in by Use.note and Use.watch, after the wrappers.
]]
local Use = { latest = nil, serial = 0 }

-- The Davies' lockers: everything of theirs in this one table - one local for
-- the outside - declared before the cabinet wrappers that call into it, and
-- filled in by its own section further down.
local Locker = {}


----------------------------------------------------------------
-- Text
----------------------------------------------------------------

-- A number as ASCII, or NO_NUMBER. tostring is only ever handed numbers here.
local function numA( n )
	if ( type( n ) ~= "number" ) then
		return NO_NUMBER
	end
	return tostring( n )
end


local function txt( tid )
	return CPlusHomeTxt.getString( tid )
end


-- One line to chat, in the system channel.
local function say( wide )
	local ok = pcall( function()
		WindowUtils.ChatPrint( wide, SystemData.ChatLogFilters.SYSTEM )
	end )
	if ( not ok ) then
		pcall( Debug.PrintToChat, wide )
	end
end


local function houseW( n )
	return txt( TID_HOUSE ) .. towstring( numA( n ) )
end


--[[
	Join every piece into one wstring, two at a time. Each pass joins
	neighbours and halves the count, so every character is copied once per
	pass and there are log2 of the pieces passes - rather than the whole text
	once per piece, which is what adding onto one string does.
]]
local function joinW( body )
	local count = #body
	if ( count == 0 ) then
		return L""
	end

	while ( count > 1 ) do
		local joined = 0
		for i = 1, count, 2 do
			joined = joined + 1
			if ( i < count ) then
				body[ joined ] = body[ i ] .. body[ i + 1 ]
			else
				body[ joined ] = body[ i ]
			end
		end
		for i = joined + 1, count do
			body[ i ] = nil
		end
		count = joined
	end

	return body[ 1 ]
end


--[[
	A text field for the file: a wstring with every TAB, CR and LF turned into
	one space, so that it cannot break a line or a column. Anything that is not
	a wstring is written as an empty field. wstring.gsub is what Default itself
	uses on property params ( Source/ItemProperties.lua:577 ).

	<br> and <p> become one space first. Default reads both as line breaks
	( Source/WindowUtils.lua:421,425 ), and the file log writes a <br> left in
	a line as a bare LF. Other marks such as <BASEFONT ...> stay as they are;
	the search page takes them out for display.

	Every step is checked. LuaPlus's wstring.gsub can hand back a narrow
	string instead of a wstring, above all when the result is empty, and it
	does not work on an empty source ( Default Source/WindowUtils.lua:412-417;
	its translateMarkup checks after every step, :418-440 ). On the live client
	an empty base name - GetStringFromTid gives L"" for a type
	with no base name - came back from the first step as a string, the next
	step stopped with "wstring expected, got string", and no record was
	written. So an empty value is an empty field without any gsub, a narrow
	result is made wide again, and an empty result ends as an empty field.
]]
local FIELD_REPLACEMENTS = {
	{ L"<[Bb][Rr]>", L" " },
	{ L"<[Pp]>", L" " },
	{ L"\t", L" " },
	{ L"\r", L" " },
	{ L"\n", L" " },
}

local function fieldW( value )
	if ( type( value ) ~= "wstring" or value == L"" ) then
		return L""
	end
	local text = value
	for i = 1, #FIELD_REPLACEMENTS do
		local step = FIELD_REPLACEMENTS[ i ]
		local result = wstring.gsub( text, step[ 1 ], step[ 2 ] )
		if ( type( result ) ~= "wstring" ) then
			if ( type( result ) ~= "string" or result == "" ) then
				return L""
			end
			result = towstring( result )
		end
		if ( result == L"" ) then
			return L""
		end
		text = result
	end
	return text
end


-- An item's base name as a text field ( BASE_NAME_TID_LOW and the others
-- above ), or an empty field when there is no objectType or no name.
local function baseNameW( objectType )
	if ( type( objectType ) ~= "number" ) then
		return L""
	end
	local tid = BASE_NAME_TID_LOW + objectType
	if ( objectType >= BASE_NAME_HIGH_FROM ) then
		tid = BASE_NAME_TID_HIGH + objectType
	end
	return fieldW( GetStringFromTid( tid ) )
end


--[[
	One record: its tag, then each field after a TAB, then the line end. A
	field is ASCII text ( a string ) or a wstring that has been through fieldW.
]]
local function row( body, tag, ... )
	body[ #body + 1 ] = towstring( tag )
	for i = 1, select( "#", ... ) do
		local field = select( i, ... )
		body[ #body + 1 ] = TAB
		if ( type( field ) == "string" ) then
			if ( field ~= "" ) then
				body[ #body + 1 ] = towstring( field )
			end
		else
			body[ #body + 1 ] = field
		end
	end
	body[ #body + 1 ] = NL
end


----------------------------------------------------------------
-- Readings
----------------------------------------------------------------

local function indexOnce( tbl, key )
	return tbl[ key ]
end


-- One entry of a WindowData table, or nil when it is not there or cannot be read.
local function entry( dataName, key )
	local data = WindowData and WindowData[ dataName ]
	if ( type( data ) ~= "table" ) then
		return nil
	end
	local ok, value = pcall( indexOnce, data, key )
	if ( not ok ) then
		return nil
	end
	return value
end


--[[
	An object's ItemProperties, registered first if they are missing. Measured
	on the live client they are there straight after registering ( a few
	needed it, and none gained a line afterwards ).
	Never unregistered: see the note at the top.
]]
local function propertiesOf( objectId )
	if ( type( objectId ) ~= "number" ) then
		return nil
	end
	local props = entry( "ItemProperties", objectId )
	if ( props == nil ) then
		pcall( RegisterWindowData, WindowData.ItemProperties.Type, objectId )
		props = entry( "ItemProperties", objectId )
	end
	if ( type( props ) ~= "table" ) then
		return nil
	end
	return props
end


-- Where the player stands: x, y, z and facet, or nil when any of them cannot
-- be read.
local function position()
	local location = WindowData and WindowData.PlayerLocation
	if ( type( location ) ~= "table" ) then
		return nil
	end
	local x, y, z, facet = location.x, location.y, location.z, location.facet
	if ( type( x ) ~= "number" or type( y ) ~= "number"
		or type( z ) ~= "number" or type( facet ) ~= "number" ) then
		return nil
	end
	return x, y, z, facet
end


----------------------------------------------------------------
-- Houses
----------------------------------------------------------------

local function houseKey( n, field )
	return "CPlusHomeRecordHouse" .. numA( n ) .. field
end


--[[
	One house as saved, or nil when it has no corners or any of its numbers
	cannot be read. A house half saved is treated as not registered rather
	than guessed at.
]]
local function loadHouse( n )
	local corners = Interface.LoadNumber( houseKey( n, "Corners" ), 0 )
	if ( type( corners ) ~= "number" or corners < 1 ) then
		return nil
	end
	local house = {
		corners = corners,
		facet = Interface.LoadNumber( houseKey( n, "Facet" ), nil ),
		minX = Interface.LoadNumber( houseKey( n, "MinX" ), nil ),
		maxX = Interface.LoadNumber( houseKey( n, "MaxX" ), nil ),
		minY = Interface.LoadNumber( houseKey( n, "MinY" ), nil ),
		maxY = Interface.LoadNumber( houseKey( n, "MaxY" ), nil ),
	}
	if ( type( house.facet ) ~= "number" or type( house.minX ) ~= "number"
		or type( house.maxX ) ~= "number" or type( house.minY ) ~= "number"
		or type( house.maxY ) ~= "number" ) then
		return nil
	end
	return house
end


local function saveHouse( n, house )
	Interface.SaveNumber( houseKey( n, "Corners" ), house.corners )
	Interface.SaveNumber( houseKey( n, "Facet" ), house.facet )
	Interface.SaveNumber( houseKey( n, "MinX" ), house.minX )
	Interface.SaveNumber( houseKey( n, "MaxX" ), house.maxX )
	Interface.SaveNumber( houseKey( n, "MinY" ), house.minY )
	Interface.SaveNumber( houseKey( n, "MaxY" ), house.maxY )
end


-- Whether a point is inside an area - { facet, minX, maxX, minY, maxY }, a
-- registered house or the one a guide was given - edges included.
local function inArea( area, x, y, facet )
	return area.facet == facet
		and x >= area.minX and x <= area.maxX
		and y >= area.minY and y <= area.maxY
end


--[[
	Whether an area - { minX, maxX, minY, maxY } - is no wider and no taller
	than AREA.MAX_SIDE tiles, edges included. An area whose from is past its
	to does not fit. For the corners added here, the areas pasted here and
	the paste window ( CPlusHomeArea.lua ).
]]
function CPlusHomeRecord.areaFits( area )
	local side = CPlusHomeRecord.AREA.MAX_SIDE
	return area.minX <= area.maxX and area.minY <= area.maxY
		and area.maxX - area.minX + 1 <= side and area.maxY - area.minY + 1 <= side
end


-- The first registered house the point is inside, edges included, or nil.
local function houseAt( x, y, facet )
	for n = 1, MAX_HOUSES do
		local house = Houses[ n ]
		if ( house and inArea( house, x, y, facet ) ) then
			return n
		end
	end
	return nil
end


--[[
	For the guide ( CPlusHomeGuide.lua ): whether the player stands in an area
	now - the house's area as the search page gave it, not one registered on
	this character - true or false, or nil when where the player stands cannot
	be read. Reads only.
]]
function CPlusHomeRecord.playerInArea( area )
	local x, y, _, facet = position()
	if ( x == nil ) then
		return nil
	end
	return inArea( area, x, y, facet )
end


-- "corners c / facet f / x a-b / y c-d", for chat.
local function houseSummaryW( house )
	return txt( TID_CORNERS ) .. towstring( numA( house.corners ) )
		.. SEPARATOR .. txt( TID_FACET ) .. towstring( numA( house.facet ) )
		.. SEPARATOR .. txt( TID_RANGE_X ) .. towstring( numA( house.minX ) .. "-" .. numA( house.maxX ) )
		.. SEPARATOR .. txt( TID_RANGE_Y ) .. towstring( numA( house.minY ) .. "-" .. numA( house.maxY ) )
end


-- How to register a house again: clear it with the menu item, then add its
-- corners. The end of what corner says when it does not add one.
local function againW()
	return txt( TID_AREA.AGAIN ) .. txt( TID_MENU.CLEAR ) .. txt( TID_AREA.AGAIN_TAIL )
end


-- The house number from a macro, or nil after saying why it will not do.
local function houseNumber( n )
	local ok, number = pcall( tonumber, n )
	if ( ok and type( number ) == "number" and number == math.floor( number )
		and number >= 1 and number <= MAX_HOUSES ) then
		return number
	end
	say( txt( TID_PREFIX ) .. txt( TID_BAD_NUMBER ) .. towstring( numA( MAX_HOUSES ) ) .. txt( TID_BAD_NUMBER_END ) )
	return nil
end


----------------------------------------------------------------
-- Opening: decide
----------------------------------------------------------------

-- The answers decide can give.
local DECIDED = { RECORD = 1, SKIP = 2, UNKNOWN = 3 }


local function hasLockdownLine( tids )
	for i = 1, #tids do
		local tid = tids[ i ]
		if ( tid == TID_LOCKED_DOWN or tid == TID_LOCKED_DOWN_SECURE ) then
			return true
		end
	end
	return false
end


--[[
	A walk up through ObjectInfo that registers what is not there: runs
	walk( registered ) and hands back the two values it returns, each
	ObjectInfo read through infoOf. What was registered - and only that - is
	unregistered again when walk ends, whichever way it ends, an error
	included ( which then goes on up as it was, level 0 as onJewelParse's -
	no second place put in front of it ): registering is not counted, so
	unregistering an id that was there before would take it from the window
	that needs it too.
]]
local function registering( walk )
	local registered = {}
	local ok, first, second = pcall( walk, registered )
	for i = 1, #registered do
		pcall( UnregisterWindowData, WindowData.ObjectInfo.Type, registered[ i ] )
	end
	if ( not ok ) then
		error( first, 0 )
	end
	return first, second
end


-- An object's ObjectInfo, or nil. When it is not there it is registered and
-- read again, and the id noted in registered for registering to unregister.
local function infoOf( id, registered )
	local info = entry( "ObjectInfo", id )
	if ( type( info ) ~= "table" and type( id ) == "number" and id > 0 ) then
		if ( pcall( RegisterWindowData, WindowData.ObjectInfo.Type, id ) ) then
			registered[ #registered + 1 ] = id
		end
		info = entry( "ObjectInfo", id )
	end
	if ( type( info ) ~= "table" ) then
		return nil
	end
	return info
end


--[[
	Whether a container should be recorded: walk from it up through
	ObjectInfo.containerId, and record it if any container on the way has a
	locked down line. The container itself is step 0, and every step is looked
	at in the same order:

	  a. no ObjectInfo, even registered       -> not recorded, silently
	  b. properties cannot be read            -> undecided, said in chat
	  c. a locked down line                   -> recorded
	  d. containerId is 0, or not a number    -> not recorded
	  e. go on to the parent

	Returned with the answer: the container's own containerId, step 0's ( the
	parent its record writes ), or nil when step 0 was not read.

	An ObjectInfo that is not there is registered on the spot and read again,
	and what the walk registered - and only that - is unregistered when it
	ends ( registering ). A
	house's container had its ObjectInfo when it opened in every record so
	far - a locked down one stands on the floor with it left registered
	( ClfContnrWin.checkIsTreasureBox ), one
	opened inside it has it as an item of the parent's window
	( Source/ContainerWindow.lua:1978-1979 ) or from the hotbar
	( Source/HotbarSystem.lua:313-315 ) - but Default takes it away again in
	ways nothing here can see coming. The target moving off an object
	unregisters that object's ObjectInfo, whoever registered it
	( Source/TargetWindow.lua:110, Default's :105; also :136 and :225 ):
	measured in a house: a box clicked, then another piece of
	furniture, then a bag in the box opened - the bag was not recorded, and
	nothing was said, both times. Opened straight after the box, or
	after double-clicking the box again, it was.

	What has no ObjectInfo even registered - a mobile, for one: the owner of a
	pack animal's backpack - is still not recorded, and silently: a pack
	animal's or a vendor's backpack is no house's, and saying so would talk on
	every one opened.

	a comes before b on every step, so an id with no ObjectInfo never has
	properties registered for it. An item whose window is closed can have them
	asked for; that is registering only, never unregistering, as CLifeUI does
	for items anyway.

	b stays loud. Whether a house's container has its properties the moment it
	opens has not been measured, and a container that should be recorded must
	not be dropped without a word.

	An id seen before, or a walk past MAX_PARENT_DEPTH, is not recorded.
]]
local function decide( id )
	return registering( function( registered )
		local seen = {}
		local current = id
		local own = nil

		for _ = 0, MAX_PARENT_DEPTH do
			if ( seen[ current ] ) then
				return DECIDED.SKIP, own
			end
			seen[ current ] = true

			-- a
			local info = infoOf( current, registered )
			if ( info == nil ) then
				return DECIDED.SKIP, own
			end
			local parent = info.containerId
			if ( current == id ) then
				own = parent
			end

			-- b
			local props = propertiesOf( current )
			if ( props == nil or type( props.PropertiesTids ) ~= "table" ) then
				return DECIDED.UNKNOWN, own
			end

			-- c
			if ( hasLockdownLine( props.PropertiesTids ) ) then
				return DECIDED.RECORD, own
			end

			-- d
			if ( type( parent ) ~= "number" or parent == 0 ) then
				return DECIDED.SKIP, own
			end

			-- e
			current = parent
		end

		return DECIDED.SKIP, own
	end )
end


-- Forget containers whose window has gone without passing through Shutdown.
local function sweepOpened()
	for id in pairs( Opened ) do
		if ( not DoesWindowNameExist( "ContainerWindow_" .. numA( id ) ) ) then
			Opened[ id ] = nil
		end
	end
end


-- After the original Initialize: is this a container to record, and if so
-- note what the file will need from this moment.
local function opened( id )
	sweepOpened()

	-- An object id is a positive number; 0 or anything else is not a
	-- container this could look up.
	if ( not CPlusHomeRecord.Enable or type( id ) ~= "number" or id <= 0 ) then
		return
	end

	-- Outside every house nothing is said: other people's houses would
	-- otherwise talk on every container. show() is how to check.
	local x, y, z, facet = position()
	if ( x == nil ) then
		return
	end
	local house = houseAt( x, y, facet )
	if ( house == nil ) then
		return
	end

	local data = entry( "ContainerWindow", id )
	if ( type( data ) == "table" and data.isCorpse == true ) then
		return
	end

	-- The parent comes from the walk: an ObjectInfo it had to register is gone
	-- again once it ends ( decide ).
	local decided, parent = decide( id )
	if ( decided == DECIDED.UNKNOWN ) then
		say( txt( TID_PREFIX ) .. txt( TID_UNDECIDED ) .. towstring( numA( id ) ) )
		return
	end
	if ( decided ~= DECIDED.RECORD ) then
		return
	end

	Opened[ id ] = {
		house = house,
		x = x,
		y = y,
		z = z,
		facet = facet,
		openedAt = ClfUtil.getClockString(),
		parent = parent,
	}
end


----------------------------------------------------------------
-- Closing: write
----------------------------------------------------------------

-- The prop and params records for one set of properties. Returns the lines
-- written.
local function writeProperties( body, props, propTag, paramsTag )
	local lines = 0
	local list = props and props.PropertiesList
	local tids = props and props.PropertiesTids

	if ( type( list ) == "table" ) then
		for i = 1, #list do
			local tid = NO_NUMBER
			if ( type( tids ) == "table" ) then
				tid = numA( tids[ i ] )
			end
			row( body, propTag, tid, fieldW( list[ i ] ) )
			lines = lines + 1
		end
	end

	local params = props and props.PropertiesTidsParams
	local fields = {}
	if ( type( params ) == "table" ) then
		for i = 1, #params do
			fields[ i ] = fieldW( params[ i ] )
		end
	end
	row( body, paramsTag, unpack( fields ) )

	return lines
end


--[[
	A count out of one property param: a whole number of 0 or more, or nil.
	The param is a wstring, turned narrow without going through tostring.
]]
local function countOf( value )
	local number = nil
	if ( type( value ) == "number" ) then
		number = value
	elseif ( type( value ) == "wstring" ) then
		local ok, narrow = pcall( WStringToString, value )
		if ( ok and type( narrow ) == "string" ) then
			number = tonumber( narrow )
		end
	end
	if ( type( number ) == "number" and number >= 0 and number == math.floor( number ) ) then
		return number
	end
	return nil
end


--[[
	Whether an item's properties say it is a container ( TID_CONTENTS or
	TID_CONTENTS_WEIGHT ), and if so how many things are in it. The second
	value is nil when the count could not be read - not 0.
]]
local function containerCount( props )
	local tids = props and props.PropertiesTids
	if ( type( tids ) ~= "table" ) then
		return false, nil
	end

	local found = nil
	for i = 1, #tids do
		if ( tids[ i ] == TID_CONTENTS or tids[ i ] == TID_CONTENTS_WEIGHT ) then
			found = tids[ i ]
			break
		end
	end
	if ( found == nil ) then
		return false, nil
	end

	local params = props.PropertiesTidsParams
	if ( type( params ) ~= "table" ) then
		return true, nil
	end
	local marker = towstring( "@" .. numA( found ) )
	for i = 1, #params - 1 do
		if ( params[ i ] == marker ) then
			return true, countOf( params[ i + 1 ] )
		end
	end
	return true, nil
end


--[[
	Which character wrote this record:

	  char  <the character's own number>  <the name, titles and all>

	The number is what tells characters apart. Measured on the live client: a
	number of its own for each character, and the same number again after leaving
	the game and logging in afresh. The name is the hint for a person reading the
	file, and it carries whatever titles the character has - they come before the
	name and after it, so it is not a name on its own and nothing here tries to
	cut one out of it. It goes **last** on the line, being the one field that
	holds spaces.

	The account and the shard are not in the client at all: SystemData.Login
	is the login screen's own and is empty in game, and no other place in the
	client was found to hold them. The PC side pairs this
	number with the folders under User Data instead.

	**The number is what the line is for**; the name is written beside it when
	it can be trusted, and left out when it cannot:

	  char <number>          the name was not this character's, or not readable
	  char <number> <name>   both

	**The name belongs to whichever paperdoll was opened last, and that is not
	always this character's.** Default reads it when it builds a paperdoll
	window ( Source/PaperdollWindow.lua:89-90, :113-115 ) and opens other
	people's paperdolls as readily as one's own, so a single look at someone
	else leaves their name in SystemData.Paperdoll until another window is
	built - and one's own window, being open already, is not built again. The
	id beside the name says whose it is, so the name is taken **only when that
	id is this character's**. Without that, a session's records would quietly
	carry a stranger's name.

	The name is not quite the one on screen either: Default writes ", " back
	into SystemData.Paperdoll.Name as "<BR>" ( :131 ), and fieldW turns that
	into one space, so a title's comma reads as a space in the file. The
	number is what anything is matched on; the name is a hint for a person.

	A record that cannot read the number writes no line at all, and an older
	record without the line is read as "not known" ( home_search_parse.js ).
	Read only: nothing is registered, and nothing is written back.
]]
local function charRow( body )
	local id = tonumber( entry( "PlayerStatus", "PlayerId" ) )
	if ( type( id ) ~= "number" or id <= 0 ) then
		return
	end

	local name = L""
	local okWhose, whose = pcall( function()
		return SystemData and SystemData.Paperdoll and SystemData.Paperdoll.Id
	end )
	if ( okWhose and tonumber( whose ) == id ) then
		local okName, raw = pcall( function()
			return SystemData.Paperdoll.Name
		end )
		name = okName and fieldW( raw ) or L""
	end

	if ( name == L"" ) then
		row( body, "char", numA( id ) )
		return
	end

	row( body, "char", numA( id ), name )
end


--[[
	The area of the house this record was made in:

	  area  <house>  <facet>  <min x>  <max x>  <min y>  <max y>

	The house is the box record's, and the area is Houses[ house ] as it is
	when the record is written. A house number is this character's own - the
	houses are registered on each character, numbered as the player numbered
	them there - so another character may give the same house another number.
	The search page keeps its own table of houses for each account and shard,
	learned from these lines, and tells one house from another by the area.

	Only this record's house is written, never every house registered: a
	registration no record was ever made in does not reach the page. A house
	cleared between opening the box and closing it writes no line, and the
	page reads the record by where the player stood, as it reads records
	that carry no such line.
]]
local function areaRow( body, n )
	local house = Houses[ n ]
	if ( house == nil ) then
		return
	end
	row( body, "area", numA( n ), numA( house.facet ), numA( house.minX ), numA( house.maxX ),
		numA( house.minY ), numA( house.maxY ) )
end


--[[
	The head every record begins with, whatever kind it is: the format, who
	wrote it, the box, where the player stood, the area of the house and the
	times.

	One place, so that a box's record, a cabinet's and a scroll book's cannot
	drift apart - each of the three writers below calls this and adds its own
	records after it.
]]
local function writeHead( body, box, place )
	row( body, FORMAT_TAG, FORMAT_VERSION )
	charRow( body )
	row( body, "box", numA( box ), numA( place.parent ), numA( place.house ) )
	row( body, "pos", numA( place.x ), numA( place.y ), numA( place.z ), numA( place.facet ) )
	areaRow( body, place.house )
	row( body, "time", place.openedAt, ClfUtil.getClockString() )
end


--[[
	Build and write the file for one container. Every record goes through row,
	which starts it with its tag; END is the last record added, after every
	loop has finished, and nothing is added after it.

	Returns the line for chat rather than saying it: see onShutdown.
]]
local function writeRecord( id, record )
	local body = {}

	writeHead( body, id, record )

	local boxProps = propertiesOf( id )
	writeProperties( body, boxProps, "boxprop", "boxparams" )

	local items = 0
	local withoutProps = 0
	local containers = 0
	local inside = 0
	local insideShort = false
	local data = entry( "ContainerWindow", id )
	local contained = type( data ) == "table" and data.ContainedItems or nil

	if ( type( contained ) == "table" ) then
		for i = 1, #contained do
			local element = contained[ i ]
			local objectId = type( element ) == "table" and element.objectId or nil
			local info = nil
			if ( type( objectId ) == "number" ) then
				info = entry( "ObjectInfo", objectId )
			end
			if ( type( info ) ~= "table" ) then
				info = {}
			end

			row( body, "item", numA( objectId ), numA( info.objectType ), numA( info.hueId ),
				numA( info.quantity ), fieldW( info.name ), baseNameW( info.objectType ) )

			local props = propertiesOf( objectId )
			if ( props == nil or type( props.PropertiesList ) ~= "table" ) then
				withoutProps = withoutProps + 1
			end
			writeProperties( body, props, "prop", "params" )
			items = items + 1

			-- For the chat line only; nothing about it goes into the file.
			local isContainer, count = containerCount( props )
			if ( isContainer ) then
				containers = containers + 1
				if ( count ) then
					inside = inside + count
				else
					insideShort = true
				end
			end
		end
	end

	row( body, "count", numA( items ), numA( withoutProps ) )
	row( body, "END" )

	Serial = Serial + 1
	ClfUtil.exportStr( joinW( body ), EXPORT_PREFIX .. numA( record.house ),
		"_" .. numA( id ) .. "_" .. numA( Serial ), EXPORT_DIR, true )

	-- The box's name is the first line of its properties.
	local name = L"-"
	local list = boxProps and boxProps.PropertiesList
	if ( type( list ) == "table" and type( list[ 1 ] ) == "wstring" ) then
		name = list[ 1 ]
	end

	local line = txt( TID_PREFIX ) .. houseW( record.house ) .. L": " .. name
		.. SEPARATOR .. txt( TID_ITEMS ) .. towstring( numA( items ) )
	if ( withoutProps > 0 ) then
		line = line .. SEPARATOR .. txt( TID_NO_PROPS ) .. towstring( numA( withoutProps ) )
	end

	--[[
		"containers inside N ( holding M )". When a container's count could
		not be read it is still counted in N, and M is marked with a "?" so
		that it reads as short rather than as a total.
	]]
	if ( containers > 0 ) then
		local holding = numA( inside )
		if ( insideShort ) then
			holding = holding .. "?"
		end
		line = line .. SEPARATOR .. txt( TID_CONTAINERS ) .. towstring( numA( containers ) )
			.. txt( TID_OPEN ) .. txt( TID_HOLDING ) .. towstring( holding ) .. txt( TID_CLOSE )
	end
	return line
end


-- The chat line saying a container's file could not be written.
local function failedLine( id, reason )
	return txt( TID_PREFIX ) .. txt( TID_WRITE_FAILED ) .. towstring( numA( id ) .. reason )
end


--[[
	Before the original Shutdown: write the container if it was noted when it
	opened. The note is taken out first, whatever happens next.

	Nothing is said to chat from here. The line - the record's, or the one
	saying the write failed - goes into context.lines, and onShutdown says it
	once the original has run.
]]
local function closing( context )
	local id = context.id
	if ( type( id ) ~= "number" ) then
		return
	end

	local record = Opened[ id ]
	Opened[ id ] = nil
	if ( record == nil or not CPlusHomeRecord.Enable ) then
		return
	end

	local ok, result = pcall( writeRecord, id, record )
	if ( ok ) then
		context.lines[ #context.lines + 1 ] = result
		return
	end

	local reason = ""
	if ( type( result ) == "string" ) then
		reason = " ( " .. result .. " )"
	end
	-- Made through pcall as well, so that not even this can put a line in
	-- chat before the original runs.
	local okLine, line = pcall( failedLine, id, reason )
	if ( not okLine ) then
		line = towstring( "CPlusHomeRecord: write failed, box " .. numA( id ) .. reason )
	end
	context.lines[ #context.lines + 1 ] = line
end


----------------------------------------------------------------
-- The wrappers
----------------------------------------------------------------

-- Work of this module's own, kept apart from the container's opening and
-- closing: a fault is reported and goes no further ( CPlusHomeRecord.protectedCall,
-- CPlusHomeSupport.lua ).
local function isolated( key, work, arg )
	if ( CPlusHomeRecord.protectedCall ) then
		CPlusHomeRecord.protectedCall( key, work, arg )
		return
	end

	-- CPlusHomeSupport.lua should always be read. Should it not be, the work
	-- is still kept apart and a fault said out loud, and whatever called this
	-- goes on to the original.
	local ok, err = pcall( work, arg )
	if ( not ok ) then
		pcall( Debug.PrintToChat, towstring( "CPlusHomeRecord: " .. key .. " failed: " .. tostring( err ) ) )
	end
end


local function dynamicWindowId()
	return SystemData.DynamicWindowId
end


local function activeDialogId()
	return WindowGetId( WindowUtils.GetActiveDialog() )
end


local function activeWindowName()
	return SystemData.ActiveWindow.name
end


local function setActiveWindowName( name )
	SystemData.ActiveWindow.name = name
end


--[[
	Wraps ContainerWindow.Initialize.

	The id is read before the original runs, from the same place the original
	reads it ( Default Source/ContainerWindow.lua:167 ), and through pcall so
	that the read cannot stop the original from being called. The original is
	then called whatever the id turned out to be - this does not copy
	ClfContnrWin.onWindowInitialize's early return - and this module's own
	work comes after it, kept apart.
]]
function CPlusHomeRecord.onInitialize()
	local okId, id = pcall( dynamicWindowId )

	CPlusHomeRecord.Initialize_org()

	if ( okId ) then
		isolated( "CPlusHomeRecord.opened", opened, id )
		-- The guide looks at an opened container only while it is guiding.
		if ( CPlusHomeGuide and CPlusHomeGuide.Active ) then
			isolated( "CPlusHomeGuide.opened", CPlusHomeGuide.opened, id )
		end
	end
end


--[[
	Wraps ContainerWindow.Shutdown.

	The original works out which container is closing from
	SystemData.ActiveWindow.name - WindowGetId( WindowUtils.GetActiveDialog() )
	( Source/ContainerWindow.lua:443, and WindowUtils.lua:164 ). That name is
	not certain to survive a call into the engine made inside a handler:
	Default itself sets it back straight after one ( Source/spellbook.lua:773-774,
	after UserActionCastSpell ). The work here does call into the engine before
	the original - RegisterWindowData, and the TextLog calls behind
	ClfUtil.exportStr - so:

	  1. the name is noted on the way in
	  2. the id is read the way the original reads it, and the reading and the
	     writing still come before the original, which lets go of the data they
	     need ( :480-489 )
	  3. lines for chat are only made there, and said after the original
	  4. the name is put back just before the original is called, when a name
	     could be noted at all

	The work is kept apart, and the original is called whatever happened
	above. Whether the name really moves has not been measured; putting it back
	changes nothing when it did not.
]]
function CPlusHomeRecord.onShutdown()
	local okName, activeName = pcall( activeWindowName )
	local okId, id = pcall( activeDialogId )

	local context = { id = id, lines = {} }
	if ( okId ) then
		isolated( "CPlusHomeRecord.closing", closing, context )
		-- While guiding, the guide takes its frame out of the closing window
		-- before the original destroys it with the window.
		if ( CPlusHomeGuide and CPlusHomeGuide.Active ) then
			isolated( "CPlusHomeGuide.closing", CPlusHomeGuide.closing, id )
		end
	end

	if ( okName and type( activeName ) == "string" ) then
		pcall( setActiveWindowName, activeName )
	end

	CPlusHomeRecord.Shutdown_org()

	for i = 1, #context.lines do
		say( context.lines[ i ] )
	end
end


----------------------------------------------------------------
-- The cabinets ( the jewel box, the dye tub, the armour refinement )
----------------------------------------------------------------

--[[
	The cabinet gumps watched, and the labels read from them, measured in
	game on the jewel box, the dye tub cabinet and the armour
	refinement cabinet.

	A jewel box and a dye tub cabinet share one gump ( 999143 ), an armour
	refinement cabinet has another ( 9302 ), and all of them hold their items
	fifty to a page under the same two labels: "items: 10 / 500" is tid 1157698
	with the count and the room as its params, "1 / 2 pages" is tid 1153561 with
	this page and the pages. Another cabinet of the same shape is added to this
	table and to nothing else.

	"jewel" is the word the records use for all of them ( the rows jewelbox and
	jewelpage ), and it is kept here with them so that
	the records already written are read exactly as they were.
]]
local CABINET_GUMP_IDS = { 999143, 9302 }
local TID_JEWEL_COUNT = 1157698
local TID_JEWEL_PAGE = 1153561

--[[
	A name line that carries its name as its value: "#<tid>" for a base name,
	or a text such as a maker's name for the item. Seen on the jewel box's
	items in the same measurement.
]]
local TID_NAME_VALUE = 1042971

--[[
	The gump's title, which is the name of the cabinet it belongs to: a label of
	this tid whose first param is "#<the name's tid>" - measured #1157694 the
	jewel box, #1164139 the dye tub cabinet, #1165086 the armour refinement
	cabinet. That name's tid is the kind written into the record, and what the
	box's own first property line is held against: no list of names is kept
	here, so a cabinet that is not known yet needs nothing but its gump id.

	The line the game showed for a dye tub cabinet ( in a chat line )
	carried 1164139 as its first property line's tid, the title's tid.
]]
local TID_GUMP_TITLE = 1114513

-- What cabinetCheck answers. UNKNOWN is "no properties to read yet", which
-- the next page looks at again; NO is "read, and it is not the one".
local CABINET = { YES = 1, NO = 2, UNKNOWN = 3 }

-- The highest objectType looked for from a base name tid: item graphics are
-- numbered in 16 bits.
local MAX_OBJECT_TYPE = 65535

--[[
	How long after a jewel box's window shuts down to look whether one is there
	again, in seconds.

	A second was not enough. On the runic atlas, a generic gump of the same kind,
	the next window came in the same frame as the last one's shutdown, but on the
	live client a jewel box of many pages broke into several records in one
	opening, because the page turned into arrived more than a second after the
	window before it went. Three seconds covers those turns; the chat line comes
	three seconds after the box closes, and nothing else waits on it.
]]
local JEWEL_CLOSE_WAIT = 3

--[[
	How long after a page arrives to read it once more, in seconds: the end of
	the time ClfjewelryBox gives the same page's properties to arrive after
	logging in ( ClfjewelryBox.gumParse, 0.15 to 0.6 ).
]]
local JEWEL_READ_AGAIN = 0.6

--[[
	The jewel box being gathered, from its first page until it is written, or
	nil. Only one can be open at a time: opening another replaces its gump.
	Everything in it goes when it is written.
]]
local Jewel = nil

-- The number of the latest jewel box gathered, part of its timers' names.
local JewelSerial = 0

-- The ids already said in chat as not confirmed, so that one is said once.
local JewelSaid = {}


-- The objectType whose base name has this tid ( BASE_NAME_TID_LOW and the
-- others ), or nil when it is not a base name's tid.
local function typeOfBaseName( tid )
	if ( type( tid ) ~= "number" ) then
		return nil
	end
	local low = tid - BASE_NAME_TID_LOW
	if ( low >= 0 and low < BASE_NAME_HIGH_FROM ) then
		return low
	end
	local high = tid - BASE_NAME_TID_HIGH
	if ( high >= BASE_NAME_HIGH_FROM and high <= MAX_OBJECT_TYPE ) then
		return high
	end
	return nil
end


--[[
	A jewel box item's objectType from its name line, which is all there is to
	go on: the jewel box's items have no ObjectInfo, even registered ( same
	measurement ). The line's tid is a base name's, or it is TID_NAME_VALUE and
	its value is "#<a base name's tid>". nil otherwise: a name of its own
	( tid 1151757 and the like ) or a text says nothing of the type. Measured,
	this finds most items in a box of jewellery and few in a box of talismans.
]]
local function typeFromName( props )
	local tids = props and props.PropertiesTids
	if ( type( tids ) ~= "table" ) then
		return nil
	end
	local tid = tids[ 1 ]
	if ( tid ~= TID_NAME_VALUE ) then
		return typeOfBaseName( tid )
	end
	-- The first line's params come first: its @<tid>, then its value.
	local params = props.PropertiesTidsParams
	if ( type( params ) ~= "table" or params[ 1 ] ~= towstring( "@" .. numA( TID_NAME_VALUE ) )
		or type( params[ 2 ] ) ~= "wstring" ) then
		return nil
	end
	local ok, narrow = pcall( WStringToString, params[ 2 ] )
	if ( not ok or type( narrow ) ~= "string" ) then
		return nil
	end
	local named = string.match( narrow, "^#(%d+)$" )
	if ( named == nil ) then
		return nil
	end
	return typeOfBaseName( tonumber( named ) )
end


--[[
	The gump data of a cabinet whose window is there, and its gump id, or nil.
	GumpData keeps a closed gump's data ( ClfGGMod.onGenericGumpShutdown ), so the window is
	what says. Only one can be open at a time - each gump has one window, and
	two cabinets of the same gump replace one another - so the first found is
	the one being looked at.
]]
local function jewelGump()
	local gumps = GumpData and GumpData.Gumps
	if ( type( gumps ) ~= "table" ) then
		return nil
	end
	for i = 1, #CABINET_GUMP_IDS do
		local gumpId = CABINET_GUMP_IDS[ i ]
		local gump = gumps[ gumpId ]
		if ( type( gump ) == "table" and type( gump.windowName ) == "string"
			and DoesWindowExist( gump.windowName ) ) then
			return gump, gumpId
		end
	end
	return nil
end


--[[
	The tid of the name in the gump's title ( TID_GUMP_TITLE ), or nil when the
	title is not there or does not carry one. This is the kind of cabinet the
	gump belongs to.
]]
local function gumpKind( gump )
	if ( type( gump.Labels ) ~= "table" ) then
		return nil
	end
	for _, label in pairs( gump.Labels ) do
		if ( type( label ) == "table" and label.tid == TID_GUMP_TITLE and type( label.tidParms ) == "table" ) then
			-- Every param of the title is looked at, not only the first: what
			-- was measured is that one of them is the name, as "#<tid>".
			for _, parm in pairs( label.tidParms ) do
				local narrow = nil
				if ( type( parm ) == "wstring" ) then
					local ok, text = pcall( WStringToString, parm )
					narrow = ok and type( text ) == "string" and text or nil
				elseif ( type( parm ) == "string" ) then
					narrow = parm
				end
				local named = narrow and string.match( narrow, "^#(%d+)$" ) or nil
				if ( named ~= nil ) then
					return tonumber( named )
				end
			end
		end
	end
	return nil
end


-- The page shown, the pages, and the items in the box, from the gump's
-- labels: each a number, or nil when its label is not there or not a number.
local function jewelLabels( gump )
	local page, pages, count = nil, nil, nil
	if ( type( gump.Labels ) ~= "table" ) then
		return page, pages, count
	end
	for _, label in pairs( gump.Labels ) do
		if ( type( label ) == "table" and type( label.tidParms ) == "table" ) then
			if ( label.tid == TID_JEWEL_PAGE ) then
				page = countOf( label.tidParms[ 1 ] )
				pages = countOf( label.tidParms[ 2 ] )
			elseif ( label.tid == TID_JEWEL_COUNT ) then
				count = countOf( label.tidParms[ 1 ] )
			end
		end
	end
	return page, pages, count
end


--[[
	The items of the page shown in the gump, through ClfGGMod.getItemPropsInGump, which
	registers their ItemProperties where they are missing - as it does for
	ClfjewelryBox on the same page - and in the order of their windows' numbers,
	the order the gump made them in. An item whose ItemProperties are not there
	even registered is not among them; reading the page again
	( JEWEL_READ_AGAIN ) can find it.
]]
local function pageItems( gumpId )
	local props, windows = ClfGGMod.getItemPropsInGump( gumpId )
	local ids = {}
	if ( type( props ) ~= "table" ) then
		return ids
	end
	for objectId in pairs( props ) do
		ids[ #ids + 1 ] = objectId
	end
	local numbers = {}
	for i = 1, #ids do
		local name = type( windows ) == "table" and windows[ ids[ i ] ] or nil
		local number = type( name ) == "string" and tonumber( string.match( name, "(%d+)$" ) or "" ) or nil
		numbers[ ids[ i ] ] = number or ids[ i ]
	end
	table.sort( ids, function( a, b ) return numbers[ a ] < numbers[ b ] end )
	return ids
end


--[[
	The cabinet the items on the page belong to, from their ObjectInfo: the
	containerId all of them carry, when every one carries the same. A page holds
	the items of one cabinet only, so anything but one shared id - a missing
	one among them, two different ones, no item at all - is no answer, and nil
	sends the reading back to Interface.LastItem and cabinetCheck.

	The dye tub cabinet's items have ObjectInfo and its containerId is the
	cabinet itself ( measured: the id of the cabinet just used ); the
	jewel box's and the armour refinement cabinet's items have none at all.
]]
local function boxFromItems( ids )
	local box = nil
	for i = 1, #ids do
		local info = entry( "ObjectInfo", ids[ i ] )
		local parent = type( info ) == "table" and info.containerId or nil
		if ( type( parent ) ~= "number" or parent <= 0 ) then
			return nil
		end
		if ( box == nil ) then
			box = parent
		elseif ( box ~= parent ) then
			return nil
		end
	end
	return box
end


--[[
	Whether an id is the cabinet the open gump belongs to: its properties
	( registered here when they are missing, never unregistered ) name it as the
	gump's title does - the first line's tid is the title's tid, or its text is
	that tid's text.

	Interface.LastItem alone will not do. It is set whenever an item is used,
	a bandage from the hotbar among them ( Default Interface.lua:2212, the item
	use request ), and a cabinet's page is read whenever any generic gump's
	data arrives - so without this an item just used would be written as a box.

	A locked down line is not asked for. The jewel box carried one, but the dye
	tub and armour refinement cabinets carry none ( the game ), and
	the title is what tells a cabinet apart in any case.

	CABINET.UNKNOWN means there is nothing to hold it against yet: the title has
	not been read, or the properties have not arrived - after logging in they
	can take a moment ( ClfjewelryBox.gumParse ) - so the next page looks again.
]]
local function cabinetCheck( objectId, titleTid )
	if ( type( objectId ) ~= "number" or objectId <= 0 ) then
		return CABINET.NO
	end
	if ( type( titleTid ) ~= "number" ) then
		return CABINET.UNKNOWN
	end
	local props = propertiesOf( objectId )
	local tids = props and props.PropertiesTids
	local list = props and props.PropertiesList
	if ( type( tids ) ~= "table" or type( list ) ~= "table" or type( list[ 1 ] ) ~= "wstring" ) then
		return CABINET.UNKNOWN
	end
	if ( tids[ 1 ] == titleTid ) then
		return CABINET.YES
	end
	local ok, name = pcall( GetStringFromTid, titleTid )
	if ( ok and type( name ) == "wstring" and name ~= L"" and list[ 1 ] == name ) then
		return CABINET.YES
	end
	return CABINET.NO
end


--[[
	Said once for an id that was not confirmed as the cabinet whose gump was
	open, with what was read of it: its number, the tid and the text of its
	first property line, and the tid of the gump's title it was held against.
	Nothing is written for such an id, so this line is the only sign of it -
	and it says what the two sides carried, for the next time in the game.
]]
local function sayNotCabinet( objectId, titleTid )
	if ( type( objectId ) ~= "number" or JewelSaid[ objectId ] ) then
		return
	end
	JewelSaid[ objectId ] = true

	local props = entry( "ItemProperties", objectId )
	local tids = type( props ) == "table" and props.PropertiesTids or nil
	local list = type( props ) == "table" and props.PropertiesList or nil
	local tid = NO_NUMBER
	if ( type( tids ) == "table" ) then
		tid = numA( tids[ 1 ] )
	end
	local name = L"-"
	if ( type( list ) == "table" and type( list[ 1 ] ) == "wstring" ) then
		name = list[ 1 ]
	end

	say( txt( TID_PREFIX ) .. txt( TID_NOT_CABINET ) .. towstring( numA( objectId ) )
		.. txt( TID_FIRST_LINE ) .. towstring( tid )
		.. txt( TID_TITLE_TID ) .. towstring( numA( titleTid ) )
		.. txt( TID_BOX_NAME ) .. name )
end


--[[
	Where a cabinet found now would be written: the player's place and the house
	it stands in, or nil when recording is off, the place cannot be read, or it
	is outside every registered house - as for any other box. Read before a page
	is, so that nothing is registered for a page that would not be written.
]]
local function gatherPlace()
	if ( not CPlusHomeRecord.Enable ) then
		return nil
	end
	local x, y, z, facet = position()
	if ( x == nil ) then
		return nil
	end
	local house = houseAt( x, y, facet )
	if ( house == nil ) then
		return nil
	end
	return { house = house, x = x, y = y, z = z, facet = facet }
end


--[[
	A new cabinet to gather, from the first page seen: where the player stands
	is where it stands. nil, and nothing gathered, when there is no place to
	write it ( gatherPlace ), the box is not an id, or the id is read and is not
	the cabinet the gump belongs to ( said once ).

	fromItems is for a box the items themselves named ( boxFromItems ): it is
	the cabinet holding them, so it counts as confirmed as soon as nothing read
	of it disagrees. Otherwise an id whose properties, or whose gump title, are
	not there yet is gathered and looked at again on every page: checked says
	whether it has been confirmed, and nothing is written until it is.
]]
local function startJewel( box, kind, fromItems, place )
	if ( type( box ) ~= "number" or box <= 0 or type( place ) ~= "table" ) then
		return nil
	end
	-- The box is held against the gump's title whichever way it was found, and
	-- turned away only when what was read of it says it is another thing
	-- ( CABINET.NO ). A box the items named is otherwise taken as it was: with
	-- its properties not there yet ( CABINET.UNKNOWN ) it is still confirmed,
	-- so a dye tub cabinet is gathered from its first page on.
	--
	-- A containerId that has gone stale - an item still naming a box it has
	-- left - has not been measured, and nothing here guesses at one: only a
	-- reading that disagrees with the title turns a box away.
	local state = cabinetCheck( box, kind )
	if ( state == CABINET.NO ) then
		sayNotCabinet( box, kind )
		return nil
	end
	local checked = fromItems or ( state == CABINET.YES )
	local info = entry( "ObjectInfo", box )
	JewelSerial = JewelSerial + 1
	return {
		serial = JewelSerial,
		box = box,
		kind = kind,
		checked = checked,
		parent = type( info ) == "table" and info.containerId or nil,
		house = place.house,
		x = place.x,
		y = place.y,
		z = place.z,
		facet = place.facet,
		openedAt = ClfUtil.getClockString(),
		items = {},      -- objectId -> the pages it was seen on, in order
		order = {},      -- the objectIds, in the order first seen
		pagesSeen = {},  -- page -> true
		pageCount = 0,   -- how many pages were seen
		pages = nil,     -- the most pages a page label said
		count = nil,     -- the most items the count label said
		window = nil,    -- the window the latest page came in ( jewelClosing )
	}
end


--[[
	Whether a page is another cabinet's than the one being gathered: a box the
	items named, or one confirmed against the gump's title ( cabinetCheck ), not
	the one being gathered, the page shown is its first, and it holds no item
	read or at least one this cabinet has not shown ( ids, the page's items ). Interface.LastItem
	changes whenever an item is used, so a different LastItem alone does not
	decide it; and a box whose properties are not there yet is not taken for
	another one either, since another cabinet's would arrive with its gump.

	A first page of nothing but items already seen is this cabinet's, even after
	another cabinet was used whose gump never came ( as a book's is ) - taken for
	the other one, its items would be written as that one's. A first page with no
	item read at all is the other one's: pageItems leaves out an item whose
	properties have not come, and a new cabinet's first page can come with none
	of them yet - kept on this one, its labels and then its later pages would be
	this one's, and it would have no record of its own.
]]
local function otherBox( jewel, box, page, kind, fromItems, ids )
	if ( box == jewel.box or page ~= 1 ) then
		return false
	end
	local unseen = #ids == 0
	for i = 1, #ids do
		if ( jewel.items[ ids[ i ] ] == nil ) then
			unseen = true
		end
	end
	return unseen and ( fromItems or cabinetCheck( box, kind ) == CABINET.YES )
end


--[[
	Build and write the file for one jewel box: the records writeRecord writes,
	with a jewelbox record after time and a jewelpage record after each item's
	params ( see the note at the top ). The jewelbox record ends with the kind
	of cabinet - the tid of the name in its gump's title - and an item record
	carries what its ObjectInfo says when it has one, or else the objectType
	typeFromName finds or "-", no hue, and the quantity 1; its name line is the
	name, and the base name is as writeRecord finds it. The items' properties
	are read as they are now, not registered again: ClfGGMod.getItemPropsInGump
	registered them on their page.

	Returns the line for chat: as a box's, with the items and the pages
	gathered out of those the gump's labels said.
]]
local function writeJewel( jewel )
	local body = {}

	writeHead( body, jewel.box, jewel )
	row( body, "jewelbox", numA( jewel.pageCount ), numA( jewel.pages ), numA( #jewel.order ), numA( jewel.count ), numA( jewel.kind ) )

	local boxProps = propertiesOf( jewel.box )
	writeProperties( body, boxProps, "boxprop", "boxparams" )

	local withoutProps = 0
	for i = 1, #jewel.order do
		local objectId = jewel.order[ i ]
		local props = entry( "ItemProperties", objectId )
		if ( type( props ) ~= "table" ) then
			props = nil
		end
		local list = props and props.PropertiesList
		local name = nil
		if ( type( list ) == "table" ) then
			name = list[ 1 ]
		else
			withoutProps = withoutProps + 1
		end

		-- The dye tub cabinet's items have ObjectInfo, the jewel box's and the
		-- armour refinement cabinet's have none: with it the type and the hue
		-- are read as any other box's item is ( so its art shows in its colour ),
		-- without it the type is guessed from the name line and there is no hue.
		local info = entry( "ObjectInfo", objectId )
		if ( type( info ) ~= "table" ) then
			info = nil
		end
		local objectType = info and info.objectType or nil
		if ( type( objectType ) ~= "number" ) then
			objectType = typeFromName( props )
		end
		local hue = NO_NUMBER
		local quantity = "1"
		if ( info ~= nil ) then
			hue = numA( info.hueId )
			if ( type( info.quantity ) == "number" ) then
				quantity = numA( info.quantity )
			end
			if ( name == nil ) then
				name = info.name
			end
		end

		row( body, "item", numA( objectId ), numA( objectType ), hue, quantity, fieldW( name ), baseNameW( objectType ) )
		writeProperties( body, props, "prop", "params" )

		local pages = {}
		for k, page in ipairs( jewel.items[ objectId ] ) do
			pages[ k ] = numA( page )
		end
		row( body, "jewelpage", unpack( pages ) )
	end

	row( body, "count", numA( #jewel.order ), numA( withoutProps ) )
	row( body, "END" )

	Serial = Serial + 1
	ClfUtil.exportStr( joinW( body ), EXPORT_PREFIX .. numA( jewel.house ),
		"_" .. numA( jewel.box ) .. "_" .. numA( Serial ), EXPORT_DIR, true )

	local boxName = L"-"
	local boxList = boxProps and boxProps.PropertiesList
	if ( type( boxList ) == "table" and type( boxList[ 1 ] ) == "wstring" ) then
		boxName = boxList[ 1 ]
	end

	local line = txt( TID_PREFIX ) .. houseW( jewel.house ) .. L": " .. boxName
		.. SEPARATOR .. txt( TID_ITEMS ) .. towstring( numA( #jewel.order ) .. "/" .. numA( jewel.count ) )
		.. SEPARATOR .. txt( TID_PAGES ) .. towstring( numA( jewel.pageCount ) .. "/" .. numA( jewel.pages ) )
	if ( withoutProps > 0 ) then
		line = line .. SEPARATOR .. txt( TID_NO_PROPS ) .. towstring( numA( withoutProps ) )
	end
	return line
end


--[[
	Ends a jewel box: forgotten first, so that a write that fails cannot leave
	it behind, then written if recording is still on, and its line said.

	A box never confirmed as the cabinet whose gump was open is thrown away
	without being written, and said once instead: its properties never came, or
	what came was not that cabinet's.
]]
local function endJewel( jewel )
	if ( Jewel == jewel ) then
		Jewel = nil
	end
	if ( not jewel.checked ) then
		sayNotCabinet( jewel.box, jewel.kind )
		return
	end
	if ( not CPlusHomeRecord.Enable ) then
		return
	end

	local ok, result = pcall( writeJewel, jewel )
	if ( ok ) then
		say( result )
		return
	end

	local reason = ""
	if ( type( result ) == "string" ) then
		reason = " ( " .. result .. " )"
	end
	local okLine, line = pcall( failedLine, jewel.box, reason )
	if ( not okLine ) then
		line = towstring( "CPlusHomeRecord: write failed, box " .. numA( jewel.box ) .. reason )
	end
	say( line )
end


--[[
	JEWEL_CLOSE_WAIT after the cabinet's window named name shut down: the
	cabinet was closed when no page has come since in another window - name is
	still the window its latest page came in ( jewel.window ) - and no cabinet
	window is there.

	The window's name decides:
	asked only whether a cabinet window was there three seconds on, the look a
	window left as its page was turned could land in a later turn - the window
	before gone, the next not come yet - and write the cabinet in the middle of
	its reading, one opening split into two records.
]]
local function jewelClosing( jewel, name )
	if ( Jewel ~= jewel or jewel.window ~= name or jewelGump() ~= nil ) then
		return
	end
	endJewel( jewel )
end


--[[
	Before the original GenericGump.Shutdown: if the window shutting down is a
	cabinet's while one is being gathered, look again JEWEL_CLOSE_WAIT later,
	with that window's name ( jewelClosing ). Which gump the window was is read
	before the original, which forgets it ( ClfGGMod.onGenericGumpShutdown ): Default's
	list of gump windows, or the jewel box's own gump data when the list has no
	entry for it. Nothing here calls into the engine.
]]
local function jewelShutdown()
	local jewel = Jewel
	if ( jewel == nil ) then
		return
	end
	local name = SystemData.ActiveWindow.name
	if ( type( name ) ~= "string" ) then
		return
	end
	local list = GenericGump and GenericGump.GumpsList
	local listed = type( list ) == "table" and list[ name ] or nil
	local gumps = GumpData and GumpData.Gumps
	local wasCabinet = false
	for i = 1, #CABINET_GUMP_IDS do
		local gumpId = CABINET_GUMP_IDS[ i ]
		local gump = type( gumps ) == "table" and gumps[ gumpId ] or nil
		if ( listed == gumpId or ( type( gump ) == "table" and gump.windowName == name ) ) then
			wasCabinet = true
		end
	end
	if ( not wasCabinet ) then
		return
	end
	ClfCommon.setTimeout( "CPlusHomeRecord.jewelClosing." .. numA( jewel.serial ) .. "." .. name, {
		timeout = ClfCommon.TimeSinceLogin + JEWEL_CLOSE_WAIT,
		done = function()
			isolated( "CPlusHomeRecord.jewelClosing", function()
				jewelClosing( jewel, name )
			end )
		end,
	} )
end


-- The scroll book's look at a window shutting down, and its reading of a
-- page: set in the section of the scroll books, further down.
local bookShutdown, readBookPage


--[[
	Wraps GenericGump.Shutdown, put in when the first jewel box, scroll book or
	locker is gathered - long after ClfGGMod.initialize has put in CLifeUI's own
	( ClfGGMod.onGenericGumpShutdown, which does not call Default's ) and the
	any other module may have gone round it, so this goes round all of them. The original is
	called whatever happened before it.
]]
function CPlusHomeRecord.onGumpShutdown( ... )
	isolated( "CPlusHomeRecord.jewelShutdown", jewelShutdown )
	isolated( "CPlusHomeRecord.bookShutdown", bookShutdown )
	isolated( "CPlusHomeRecord.lockerShutdown", Locker.onShutdown )
	return CPlusHomeRecord.GumpShutdown_org( ... )
end


--[[
	Wraps Interface.ItemUseRequest, put in by initialize
	( Use.watch ): Default hands it every item the player uses - double-
	clicked, or from the hotbar - by name ( Interface.lua:476, ITEM_USE_REQUEST ),
	with the item in GameData.UseRequests.UseItem. **It only looks**: the item
	is noted before the original runs ( Use.note ), nothing calls into the
	engine, Interface.LastItem and GameData are left as they are, and the
	original is called with the same arguments whatever happened before it -
	its error, if it throws one, goes on up as it was. The original writes
	LastItem only when the item's ObjectInfo can be read ( :2201-2203 ); the
	note is taken either way.
]]
function CPlusHomeRecord.onItemUseRequest( ... )
	isolated( "CPlusHomeRecord.use", Use.note )
	return CPlusHomeRecord.ItemUseRequest_org( ... )
end


--[[
	The item used is noted ( Use.latest ), with the number of the use, whatever
	the item is - whether it is a locker is asked when its page comes
	( Locker.start ), since asking reads and registers its properties. Only
	read: nothing here calls into the engine or writes GameData or
	Interface.LastItem, and an item that cannot be read notes that nothing
	usable was used.
]]
function Use.note()
	Use.serial = Use.serial + 1
	local requests = GameData and GameData.UseRequests
	local item = type( requests ) == "table" and requests.UseItem or nil
	if ( type( item ) == "number" and item > 0 ) then
		Use.latest = { item = item, serial = Use.serial }
	else
		Use.latest = nil
	end
end


--[[
	Wraps Interface.ItemUseRequest ( CPlusHomeRecord.onItemUseRequest ), put in by
	initialize, so that the use that opens the first locker is seen too.
	Without it a locker's record never names its box ( it is written with box
	0 ), and chat says so once.
]]
function Use.watch()
	if ( CPlusHomeRecord.ItemUseRequest_org ~= nil ) then
		return
	end
	if ( type( Interface ) ~= "table" or type( Interface.ItemUseRequest ) ~= "function" ) then
		pcall( Debug.PrintToChat, L"CPlusHomeRecord : Interface.ItemUseRequest not found, a Davies' locker is written without its box" )
		return
	end
	CPlusHomeRecord.ItemUseRequest_org = Interface.ItemUseRequest
	Interface.ItemUseRequest = CPlusHomeRecord.onItemUseRequest
end


local function watchGumpShutdown()
	if ( CPlusHomeRecord.GumpShutdown_org ) then
		return
	end
	if ( type( GenericGump ) ~= "table" or type( GenericGump.Shutdown ) ~= "function" ) then
		pcall( Debug.PrintToChat, L"CPlusHomeRecord : GenericGump.Shutdown not found, a jewel box, a scroll book or a locker is written only when another opens or the UI goes" )
		return
	end
	CPlusHomeRecord.GumpShutdown_org = GenericGump.Shutdown
	GenericGump.Shutdown = CPlusHomeRecord.onGumpShutdown
end


--[[
	One page of a cabinet, gathered into Jewel: every item on it, with this
	page added to the pages it was seen on, and the most pages and items the
	labels have said. A cabinet is started when there is none, and ended -
	written - first when the page is another cabinet's. Nothing happens unless a
	cabinet's window is there, which is also all that happens for any other
	gump; and outside every house, or with recording off, no cabinet is started
	and the page is not read ( nothing registered for its items ).
	The window the page came in is noted last, for jewelClosing.
	Unless this is that reading, the page is read once more JEWEL_READ_AGAIN
	later, for items whose ItemProperties came late.
]]
local function readJewelPage( again )
	local gump, gumpId = jewelGump()
	if ( gump == nil ) then
		return
	end
	-- Nothing is read - so nothing is registered - unless there is a place to
	-- write what is read. A cabinet already being gathered keeps the place it
	-- was found in.
	local place = Jewel ~= nil and Jewel.place or gatherPlace()
	if ( place == nil ) then
		return
	end

	local kind = gumpKind( gump )
	local page, pages, count = jewelLabels( gump )
	local ids = pageItems( gumpId )
	local fromItems = boxFromItems( ids )
	local box = fromItems or ( Interface and Interface.LastItem )

	-- The title was not there when the cabinet was found: take it when it comes,
	-- so that the kind is written even for one the items themselves named.
	if ( Jewel ~= nil and Jewel.kind == nil ) then
		Jewel.kind = kind
	end

	if ( Jewel == nil ) then
		Jewel = startJewel( box, kind, fromItems ~= nil, place )
		if ( Jewel == nil ) then
			return
		end
		Jewel.place = place
		watchGumpShutdown()
	elseif ( not Jewel.checked ) then
		-- Its properties, or the gump's title, were not there when it was
		-- taken: look again.
		local state = cabinetCheck( Jewel.box, Jewel.kind )
		if ( state == CABINET.YES ) then
			Jewel.checked = true
		elseif ( state == CABINET.NO ) then
			sayNotCabinet( Jewel.box, Jewel.kind )
			Jewel = nil
			return
		end
	end

	if ( otherBox( Jewel, box, page, kind, fromItems ~= nil, ids ) ) then
		endJewel( Jewel )
		Jewel = startJewel( box, kind, fromItems ~= nil, place )
		if ( Jewel == nil ) then
			return
		end
		Jewel.place = place
	end

	local jewel = Jewel
	for i = 1, #ids do
		local objectId = ids[ i ]
		local seen = jewel.items[ objectId ]
		if ( seen == nil ) then
			seen = {}
			jewel.items[ objectId ] = seen
			jewel.order[ #jewel.order + 1 ] = objectId
		end
		local listed = false
		for k = 1, #seen do
			if ( seen[ k ] == page ) then
				listed = true
			end
		end
		if ( page ~= nil and not listed ) then
			seen[ #seen + 1 ] = page
		end
	end
	if ( page ~= nil and not jewel.pagesSeen[ page ] ) then
		jewel.pagesSeen[ page ] = true
		jewel.pageCount = jewel.pageCount + 1
	end
	if ( pages ~= nil and ( jewel.pages == nil or pages > jewel.pages ) ) then
		jewel.pages = pages
	end
	if ( count ~= nil and ( jewel.count == nil or count > jewel.count ) ) then
		jewel.count = count
	end
	jewel.window = gump.windowName

	if ( not again ) then
		ClfCommon.setTimeout( "CPlusHomeRecord.jewelPage." .. gump.windowName, {
			timeout = ClfCommon.TimeSinceLogin + JEWEL_READ_AGAIN,
			done = function()
				isolated( "CPlusHomeRecord.jewelPage", readJewelPage, true )
			end,
		} )
	end
end


--[[
	Wraps ClfjewelryBox.gumParse, which ClfGGMod.GGParseData calls each time a
	generic gump's data arrives, after Default's own parsing
	( ClfGGMod.GGManagerGGParseData_org ): the moment a jewel box's page is there to read,
	a scroll book's ( readBookPage ) and a Davies' locker's ( Locker.onPage ). The original runs first and
	whatever happens - the jewel box's search window and the captions on its
	slots go on as they are - and its error, if it throws, goes on up after
	this module's readings, each kept apart, have run.
]]
function CPlusHomeRecord.onJewelParse( ... )
	local ok, err = pcall( CPlusHomeRecord.JewelParse_org, ... )
	isolated( "CPlusHomeRecord.jewelPage", readJewelPage, false )
	isolated( "CPlusHomeRecord.bookPage", readBookPage, false )
	isolated( "CPlusHomeRecord.lockerPage", Locker.onPage )
	if ( not ok ) then
		error( err, 0 )
	end
end


----------------------------------------------------------------
-- The scroll books
----------------------------------------------------------------

--[[
	A scroll book holds its scrolls in a gump of its own ( 9157 ), not in a
	container window: the client answers "not a container" for one.
	Measured on a power scroll book and a transcendence scroll book.

	The contents list and every skill are in that one gump from the start, and
	turning the pages of the contents is the client's own doing - a dump before
	and after a page button is the same. Pressing a skill, though, asks the
	server, and the answer is a gump of how many scrolls of that skill are held,
	in the book's place: the same gump id, in a window of its own.

	**The player turns the pages; nothing here presses anything.** A book is
	gathered from its contents until it closes, and written then as one record
	of the skills whose answers came while it was open: JEWEL_CLOSE_WAIT after
	a window of it shuts down, when no page has come since in another window
	( bookClosing - the window's name decides, as for a cabinet ). A book closed
	with no answer seen is not written. A book is read in as many openings as
	the player likes: the search page lays the records of one book over each
	other, and works out from them whether every skill has been read.

	**The answer names its own skill** ( its first label's tid ), so no table of
	buttons to skills is kept here: such a table was measured to slip by one at
	the seventh line of the contents.

	Every button of an answer but its back arrow takes a scroll out of the
	book. The answer that comes back after one is read as any other: the
	newest answer of a skill is the one written.
]]
local BOOK_GUMP_ID = 9157

-- The books, by the tid of the name their gump's first label carries.
local TID_BOOK_POWER = 1155689
local TID_BOOK_TRANSCENDENCE = 1151675

--[[
	The books that may be read, and against each the tid of the **book's own
	name**, which is not the tid its gump is titled with.

	Measured in the game, from the line the first reading said of
	itself ( "the container could not be confirmed" ):

	  power scrolls    gump title 1155689 "Power Scrolls"
	                   the book   1155684 "power scroll book"
	  transcendence    gump title 1151675
	                   the book   1151679

	A cabinet is named as its gump is titled ( measured ), which is
	why cabinetCheck holds a box against the title; a book is not, so a book is
	held against this name instead. This table is the only list of books there
	is: a gump whose title is not a key here is not read.
]]
local BOOK_NAME_TIDS = {
	[ TID_BOOK_POWER ] = 1155684,
	[ TID_BOOK_TRANSCENDENCE ] = 1151679,
}

--[[
	The tabs of the game's skills window, each the skills in it as the ID column
	of skilldata.csv, in the order the window shows them: copied as they are from
	Default.zip Source/SkillsWindow.lua:20-26, tab1 to tab7, where they are
	locals no other file can read. The window shows a tab's skills in
	this order ( SkillsWindow.ShowTab walks tabContents[ tab ] as it is ).
	What a scroll's skill is grouped by on the search page is the tab it is in
	here and its place in that tab, written into the book's record ( writeBook ).
]]
local SKILL_TABS = {
	{ 7,  22, 28, 53 },                                -- tab1  1078117 その他
	{ 2, 5, 18, 21, 23, 31, 40, 50, 51, 58, 54 },      -- tab2  1077760 戦闘
	{ 1, 6, 8, 11, 12, 14, 20, 27, 30, 35, 52, 55 },   -- tab3  1077761 生産
	{ 9, 13, 17, 32, 33, 34, 38, 39, 46, 47, 37, 26 }, -- tab4  1077762 魔法
	{ 3, 4, 10, 19, 24, 56, 57 },                      -- tab5  1077763 野生
	{ 15, 25, 29, 42, 44, 45, 48, 49 },                -- tab6  1078116 シーフ
	{ 16, 36, 41, 43 },                                -- tab7  1077765 バード
}

--[[
	A skill's tid in a book is this plus its ServerId in skilldata.csv: so for
	every one of the 58 skills the books measured showed ( 1044060 to 1044117 ).
	Not the csv's NameTid, which differs for Mysticism, Imbuing and Throwing
	( 1079711 to 1079713 ).
]]
local SKILL_TID_FROM = 1044060

-- The book being gathered, from its contents until it is written, or nil.
-- Only one at a time: a book's gump takes the place of the one before.
local Book = nil
local BookSerial = 0


--[[
	Whether an id is the scroll book whose gump is open: its first property
	line names it as the **book's own name** does, by tid or by text. Everything
	else is the cabinets' way, cabinetCheck, which this hands the name to -
	CABINET.UNKNOWN while there is nothing read of the id yet, CABINET.NO when
	what was read is another thing.
]]
local function bookCheck( objectId, kind )
	return cabinetCheck( objectId, BOOK_NAME_TIDS[ kind ] )
end


--[[
	Said once for an id that could not be held against the book whose gump is
	open, as a cabinet's is ( sayNotCabinet ): its number, the tid and the text
	of its first property line, the tid the gump is titled with and the tid of
	the book's own name. Both tids are in it because they are not the same,
	which is what the first reading in the game showed.
]]
local function sayNotBook( objectId, kind )
	if ( type( objectId ) ~= "number" or JewelSaid[ objectId ] ) then
		return
	end
	JewelSaid[ objectId ] = true

	local props = entry( "ItemProperties", objectId )
	local tids = type( props ) == "table" and props.PropertiesTids or nil
	local list = type( props ) == "table" and props.PropertiesList or nil
	local tid = NO_NUMBER
	if ( type( tids ) == "table" ) then
		tid = numA( tids[ 1 ] )
	end
	local name = L"-"
	if ( type( list ) == "table" and type( list[ 1 ] ) == "wstring" ) then
		name = list[ 1 ]
	end

	say( txt( TID_PREFIX ) .. txt( TID_NOT_CABINET ) .. towstring( numA( objectId ) )
		.. txt( TID_FIRST_LINE ) .. towstring( tid )
		.. txt( TID_TITLE_TID ) .. towstring( numA( kind ) )
		.. txt( TID_BOOK_NAME_TID ) .. towstring( numA( BOOK_NAME_TIDS[ kind ] ) )
		.. txt( TID_BOX_NAME ) .. name )
end


--[[
	The keys of a gump's buttons, smallest first. They were measured to run
	1, 2, 3 ... on both books and on an answer, but a gump half built has not
	been measured, and the labels of the same gumps do have holes - so the keys
	are taken as they are rather than counted.
]]
local function buttonKeys( gump )
	local keys = {}
	local buttons = type( gump ) == "table" and gump.Buttons or nil
	if ( type( buttons ) ~= "table" ) then
		return keys
	end
	for key, name in pairs( buttons ) do
		if ( type( key ) == "number" and type( name ) == "string" ) then
			keys[ #keys + 1 ] = key
		end
	end
	table.sort( keys )
	return keys
end


--[[
	Whether a button's window is a back arrow, or nil when its size or its
	place could not be read. Measured on all three pages: the arrow is 37 wide
	and 27 high, at 23, 14 from its parent, while a skill's button, a
	category's and a button that takes a scroll out of the book are 9 or 11
	wide and 11 high, at x 30 or 190.
]]
local BOOK_BACK = { WIDTH = 37, HEIGHT = 27, X = 23, Y = 14 }

local function isBackArrow( name )
	local okSize, width, height = pcall( WindowGetDimensions, name )
	local okAt, x, y = pcall( WindowGetOffsetFromParent, name )
	if ( not okSize or not okAt or type( width ) ~= "number" or type( height ) ~= "number"
		or type( x ) ~= "number" or type( y ) ~= "number" ) then
		return nil
	end
	return width == BOOK_BACK.WIDTH and height == BOOK_BACK.HEIGHT and x == BOOK_BACK.X and y == BOOK_BACK.Y
end


-- The scroll book gump while its window is there, or nil ( as jewelGump ).
local function bookGump()
	local gumps = GumpData and GumpData.Gumps
	local gump = type( gumps ) == "table" and gumps[ BOOK_GUMP_ID ] or nil
	if ( type( gump ) ~= "table" or type( gump.windowName ) ~= "string"
		or not DoesWindowExist( gump.windowName ) ) then
		return nil
	end
	return gump
end


--[[
	A gump's labels in the order they are shown.

	**The table has holes.** Measured on the answer to a skill
	( entries 27, highest key 532 - the keys are 1, 2, 4 ... 26 for the names and
	503, 506 ... 532 for the counts; the power scroll book's answer is the same
	shape, 9 entries up to key 323 ). Lua's # gives only a border of such a
	table - two, for that one - so nothing here counts or walks the labels with
	it: pairs is the only way through, and each label's own id is what orders
	them ( 1 the skill, 2 and 3 the first grade and its counts, and so on ), or
	its key where there is no id.

	The list handed back is built here, one after another, so # is its own.
]]
local function labelsInOrder( gump )
	local labels = type( gump ) == "table" and gump.Labels or nil
	if ( type( labels ) ~= "table" ) then
		return {}
	end
	local found = {}
	for key, label in pairs( labels ) do
		if ( type( label ) == "table" ) then
			local order = label.id
			if ( type( order ) ~= "number" ) then
				order = type( key ) == "number" and key or nil
			end
			if ( order ~= nil ) then
				found[ #found + 1 ] = { order = order, label = label }
			end
		end
	end
	table.sort( found, function( a, b ) return a.order < b.order end )
	local ordered = {}
	for i = 1, #found do
		ordered[ i ] = found[ i ].label
	end
	return ordered
end


--[[
	The tid of a gump's first label, which is what the gump is: the book's own
	name while the book is shown, the skill's name in the answer to a skill.
	nil when there is no first label with a tid.
]]
local function gumpFirstTid( gump )
	local first = labelsInOrder( gump )[ 1 ]
	if ( type( first ) ~= "table" or type( first.tid ) ~= "number" ) then
		return nil
	end
	return first.tid
end


--[[
	What page a book is showing, told apart by its **shape** rather than by any
	list of names ( measured on the dumps of both books ):

	  an answer       **it carries a label whose text is a table** - the counts,
	                  one number a grade. Nothing else does. Its buttons are a
	                  back arrow and one for each grade the book holds, and
	                  those take a scroll out of the book.
	  the contents    its first label is a book's own title ( BOOK_NAME_TIDS ).
	                  What it shows is either the list of categories or one
	                  category's page, and which of the two is told by the
	                  buttons on screen: a category's page has a back arrow
	                  among them, the list has none ( bookTotal ).
	  a category      anything else. A category's page comes as a gump of its
	                  own as well, with the category's name at its head.

	Nothing readable yet is BOOK_PAGE.UNKNOWN and is read again
	( JEWEL_READ_AGAIN ). No tid is held against a range here: a book with
	another category would still be read.
]]
local BOOK_PAGE = { CONTENTS = 1, CATEGORY = 2, ANSWER = 3, UNKNOWN = 4 }

local function bookPageKind( gump )
	local ordered = labelsInOrder( gump )
	for i = 1, #ordered do
		if ( type( ordered[ i ].text ) == "table" ) then
			return BOOK_PAGE.ANSWER
		end
	end
	local first = ordered[ 1 ]
	local tid = type( first ) == "table" and first.tid or nil
	if ( type( tid ) ~= "number" ) then
		return BOOK_PAGE.UNKNOWN
	end
	if ( BOOK_NAME_TIDS[ tid ] ~= nil ) then
		return BOOK_PAGE.CONTENTS
	end
	return BOOK_PAGE.CATEGORY
end


--[[
	The grades in an answer, by tid and in the order they stand: every label
	with a tid after the first, which is the skill's own name ( measured: the
	four power scroll grades, the thirteen transcendence ones ). The counts
	stand in the same order.
]]
local function bookTiers( gump )
	local tiers = {}
	local ordered = labelsInOrder( gump )
	for i = 2, #ordered do
		local label = ordered[ i ]
		if ( type( label.tid ) == "number" and label.tid > 0 ) then
			tiers[ #tiers + 1 ] = label.tid
		end
	end
	return tiers
end


--[[
	How many scrolls of each grade an answer holds, in the grades' order: the
	array a label carries as its text. Every text label in the gump was measured
	to carry the same array ( 1, 0, 2, 0 for a skill the screen shows as 1/0/2/0 ),
	so one reading gives every grade. A copy is taken: the array is the client's
	own and is made again for the next answer.
]]
local function bookCounts( gump )
	local ordered = labelsInOrder( gump )
	for i = 1, #ordered do
		local label = ordered[ i ]
		if ( type( label.text ) == "table" ) then
			-- Read from the first up, and counted here rather than left to #:
			-- the counts were measured to stand one after another ( thirteen
			-- keys in the answer above ), but a hole would otherwise make the
			-- length of the copy a matter of chance. The reading stops at the
			-- first thing that is not a number, and how many were read is what
			-- the answer is held against ( the grades ).
			local counts = {}
			local read = 0
			local k = 1
			while ( true ) do
				local count = countOf( label.text[ k ] )
				if ( count == nil ) then
					break
				end
				read = read + 1
				counts[ read ] = count
				k = k + 1
			end
			return counts, read
		end
	end
	return nil, 0
end


-- Whether two lists of grades are the same, in the same order.
local function sameTiers( a, b )
	if ( #a ~= #b ) then
		return false
	end
	for i = 1, #a do
		if ( a[ i ] ~= b[ i ] ) then
			return false
		end
	end
	return true
end


-- A tid's text for a record's field, or empty when there is none.
local function tidTextW( tid )
	if ( type( tid ) ~= "number" ) then
		return L""
	end
	local ok, text = pcall( GetStringFromTid, tid )
	if ( not ok or type( text ) ~= "wstring" ) then
		return L""
	end
	return fieldW( text )
end


--[[
	The keys of the buttons a gump is showing now, smallest first. A book's
	gump carries the buttons of every one of its pages at once and shows the
	few that belong to the page on screen - measured: while the list of
	categories was up only its buttons were showing, and while one category's
	page was only that category's, with the rest hidden.
]]
local function showingKeys( gump )
	local buttons = type( gump ) == "table" and gump.Buttons or nil
	if ( type( buttons ) ~= "table" ) then
		return {}
	end
	local keys = buttonKeys( gump )
	local shown = {}
	for i = 1, #keys do
		local ok, showing = pcall( WindowGetShowing, buttons[ keys[ i ] ] )
		if ( ok and showing ) then
			shown[ #shown + 1 ] = keys[ i ]
		end
	end
	return shown
end


--[[
	How many skills the book holds scrolls of, read from its contents while the
	list of categories is up, or nil when that cannot be said.

	The book's gump carries the buttons of all its pages at once ( measured on
	a power scroll book and a transcendence one ), of three sorts: a
	category's, on the list of categories; the back arrow of a category's page;
	and a skill's - **only a skill the book holds a scroll of has one**: in the
	records of books read to the end, the buttons were the skills read and 13
	or 14 more. The list of categories shows its own buttons and no arrow, so
	the skills are every button less the ones shown and less the arrows, told
	apart by their windows ( isBackArrow ).

	The labels are no count: the book carries the name of every skill, held or
	not ( 58 ), and a skill with no scroll has no button to open its page by.

	nil - the count not known, which the record writes as "-" and the search
	page says out loud - when the list of categories is not what is up ( an
	arrow among the buttons shown ), nothing is shown, a window's size or
	place cannot be read, or no skill is left over.
]]
local function bookTotal( gump )
	local buttons = type( gump ) == "table" and gump.Buttons or nil
	if ( type( buttons ) ~= "table" ) then
		return nil
	end
	local showing = showingKeys( gump )
	if ( #showing < 1 ) then
		return nil
	end
	local shown = {}
	for i = 1, #showing do
		if ( isBackArrow( buttons[ showing[ i ] ] ) ~= false ) then
			return nil
		end
		shown[ showing[ i ] ] = true
	end
	local keys = buttonKeys( gump )
	local skills = 0
	for i = 1, #keys do
		if ( not shown[ keys[ i ] ] ) then
			local arrow = isBackArrow( buttons[ keys[ i ] ] )
			if ( arrow == nil ) then
				return nil
			end
			if ( not arrow ) then
				skills = skills + 1
			end
		end
	end
	if ( skills < 1 ) then
		return nil
	end
	return skills
end


--[[
	The tab of the skills window a skill of a book is in, and its place in that
	tab ( SKILL_TABS ), or nil when that cannot be said: the table the game's own
	UI reads at login ( WindowData.SkillsCSV, from SkillsWindow.Initialize ) is
	not there, or no row of the tabs carries the skill's ServerId. Nothing is
	guessed: a skill not found here is written with no group.
]]
local function skillGroup( tid )
	local csv = WindowData and WindowData.SkillsCSV
	if ( type( csv ) ~= "table" or type( tid ) ~= "number" ) then
		return nil
	end
	local serverId = tid - SKILL_TID_FROM
	for tab = 1, #SKILL_TABS do
		local ids = SKILL_TABS[ tab ]
		for place = 1, #ids do
			local ok, csvRow = pcall( indexOnce, csv, ids[ place ] )
			if ( ok and type( csvRow ) == "table" and tonumber( csvRow.ServerId ) == serverId ) then
				return tab, place
			end
		end
	end
	return nil
end


--[[
	The file for one book: the head every box gets ( box, pos, time, and the
	book's own properties ), then records of its own that older readers pass
	over. No item records: what is in a book has no object id to write.

	  book      <the kind's tid> <buttons> <presses> <skills read> <every skill read 0/1> <skills in the book>
	  booktier  <the grade's tid> <its text>            the grades, in order
	  bookskill <the skill's tid> <its text> <count>... the counts, in that order
	  bookgroup <the skill's tid> <its tab 1-7> <its place in the tab>
	                                                    straight after its bookskill, for
	                                                    a skill whose group was found ( skillGroup )

	presses is 0: nothing is pressed. The skills in the book are bookTotal's,
	"-" when it was not read, and every skill was read when this one record
	read as many as that. Returns the line for chat - the skills read out of
	the skills in the book - and how many skills were written with no group.
]]
local function writeBook( book )
	local body = {}
	local done = book.total ~= nil and #book.order >= book.total
	local ungrouped = 0

	writeHead( body, book.box, book )
	row( body, "book", numA( book.kind ), numA( book.buttons ), numA( 0 ), numA( #book.order ),
		done and "1" or "0", numA( book.total ) )

	writeProperties( body, propertiesOf( book.box ), "boxprop", "boxparams" )

	local tiers = book.tiers or {}
	for i = 1, #tiers do
		row( body, "booktier", numA( tiers[ i ] ), tidTextW( tiers[ i ] ) )
	end
	for i = 1, #book.order do
		local skill = book.order[ i ]
		local counts = {}
		for k = 1, #book.skills[ skill ] do
			counts[ k ] = numA( book.skills[ skill ][ k ] )
		end
		row( body, "bookskill", numA( skill ), tidTextW( skill ), unpack( counts ) )
		local tab, place = skillGroup( skill )
		if ( tab ~= nil ) then
			row( body, "bookgroup", numA( skill ), numA( tab ), numA( place ) )
		else
			ungrouped = ungrouped + 1
		end
	end

	row( body, "count", numA( 0 ), numA( 0 ) )
	row( body, "END" )

	Serial = Serial + 1
	ClfUtil.exportStr( joinW( body ), EXPORT_PREFIX .. numA( book.house ),
		"_" .. numA( book.box ) .. "_" .. numA( Serial ), EXPORT_DIR, true )

	return txt( TID_PREFIX ) .. houseW( book.house ) .. L": " .. tidTextW( book.kind )
		.. SEPARATOR .. txt( TID_BOOK_SKILLS ) .. towstring( numA( #book.order ) .. "/" .. numA( book.total ) ), ungrouped
end


--[[
	Where a book is, decided as for a container that opens ( decide ): a
	house's - on its floor or in its containers - or not, or undecided while
	its properties have not arrived. The parent written is the one the walk
	read: the book's ObjectInfo is taken away when it is used ( Default's
	Interface.ItemUseRequest ), so read on its own it is not there.
]]
local function decideBook( book )
	local decided, parent = decide( book.box )
	book.decided = decided
	if ( decided == DECIDED.RECORD ) then
		book.parent = parent
	end
	return decided
end


--[[
	Ends a book: forgotten first, so that a write that fails cannot leave it
	behind, then written when recording is still on and an answer was seen,
	and its line said - and, when any skill was written with no group, one line
	more saying how many ( once a book, not once a skill: the search page shows
	them under 分類なし, and that must not look the same as a skill grouped so
	without a word ). A book never confirmed against its name is not written,
	and said once instead ( sayNotBook ) - its properties are read once more
	first, for a book opened just after logging in. Where the book is is
	decided as for a container ( decide ): a book still undecided is decided
	once more here, and is not written unless it is a house's - said as a
	container's is when it is still undecided, and not said at all when it is
	not a house's ( a book in the backpack ).
]]
local function endBook( book )
	if ( Book == book ) then
		Book = nil
	end
	if ( not CPlusHomeRecord.Enable ) then
		return
	end
	if ( not book.checked ) then
		if ( bookCheck( book.box, book.kind ) ~= CABINET.YES ) then
			sayNotBook( book.box, book.kind )
			return
		end
		book.checked = true
	end
	if ( #book.order == 0 ) then
		return
	end
	if ( book.decided ~= DECIDED.RECORD ) then
		decideBook( book )
	end
	if ( book.decided == DECIDED.UNKNOWN ) then
		say( txt( TID_PREFIX ) .. txt( TID_UNDECIDED ) .. towstring( numA( book.box ) ) )
		return
	end
	if ( book.decided ~= DECIDED.RECORD ) then
		return
	end

	local ok, result, ungrouped = pcall( writeBook, book )
	if ( ok ) then
		say( result )
		if ( type( ungrouped ) == "number" and ungrouped > 0 ) then
			say( txt( TID_PREFIX ) .. txt( TID_BOOK_UNGROUPED ) .. towstring( numA( ungrouped ) ) .. txt( TID_BOOK_UNGROUPED_TAIL ) )
		end
		return
	end
	local reason = ""
	if ( type( result ) == "string" ) then
		reason = " ( " .. result .. " )"
	end
	local okLine, line = pcall( failedLine, book.box, reason )
	if ( not okLine ) then
		line = towstring( "CPlusHomeRecord: write failed, book " .. numA( book.box ) .. reason )
	end
	say( line )
end


--[[
	A new book to gather, from its contents: box is Interface.LastItem - the book
	was double clicked to open it - and kind its gump's title. nil, and nothing
	gathered, when box is not an id or is read and is not that book ( said
	once ), or is decided not to be a house's ( decideBook - nothing said, as
	for a container ). A box whose properties have not arrived yet is gathered
	unconfirmed and undecided, looked at again on every contents, and written
	only once confirmed and decided a house's ( endBook ).
]]
local function startBook( box, kind, place )
	if ( type( box ) ~= "number" or box <= 0 ) then
		return nil
	end
	local state = bookCheck( box, kind )
	if ( state == CABINET.NO ) then
		sayNotBook( box, kind )
		return nil
	end
	BookSerial = BookSerial + 1
	local book = {
		serial = BookSerial,
		box = box,
		kind = kind,
		checked = state == CABINET.YES,
		decided = nil,   -- decideBook's answer: DECIDED.RECORD before it is written
		parent = nil,    -- the book's container, from decideBook
		place = place,
		house = place.house,
		x = place.x,
		y = place.y,
		z = place.z,
		facet = place.facet,
		openedAt = ClfUtil.getClockString(),
		buttons = nil,   -- the most buttons the book's gump was seen to carry
		total = nil,     -- the skills the book holds scrolls of ( bookTotal )
		tiers = nil,     -- the grades, from the first answer
		skills = {},     -- the skill's tid -> its counts, the newest answer's
		order = {},      -- the skills' tids, in the order first seen
		window = nil,    -- the window the latest page came in ( bookClosing )
		odd = false,     -- whether an answer of other grades was said
	}
	if ( decideBook( book ) == DECIDED.SKIP ) then
		return nil
	end
	return book
end


--[[
	The book's contents: the book whose gump this is, and how many skills it
	holds. The book being gathered goes on unless this is another book's - a
	book of another kind, or another book confirmed as one: Interface.LastItem
	is whatever item was last used, a bandage from the hotbar among them, so a
	LastItem that is not a book does not end the one being read ( the contents
	come again each time the player goes back from an answer ), nor does one
	whose properties are not there yet, as for a cabinet ( otherBox ).
]]
local function bookContents( gump, place )
	local kind = gumpFirstTid( gump )
	local box = Interface and Interface.LastItem
	local book = Book
	if ( book ~= nil and ( book.kind ~= kind or ( box ~= book.box and bookCheck( box, kind ) == CABINET.YES ) ) ) then
		endBook( book )
		book = nil
	end
	if ( book == nil ) then
		book = startBook( box, kind, place )
		if ( book == nil ) then
			return
		end
		Book = book
		watchGumpShutdown()
	else
		if ( not book.checked ) then
			local state = bookCheck( book.box, book.kind )
			if ( state == CABINET.YES ) then
				book.checked = true
			elseif ( state == CABINET.NO ) then
				sayNotBook( book.box, book.kind )
				Book = nil
				return
			end
		end
		if ( book.decided ~= DECIDED.RECORD and decideBook( book ) == DECIDED.SKIP ) then
			Book = nil
			return
		end
	end
	book.buttons = math.max( book.buttons or 0, #buttonKeys( gump ) )
	local total = bookTotal( gump )
	if ( total ~= nil ) then
		book.total = total
	end
end


--[[
	An answer: the counts of the skill it names, kept as the newest of that
	skill. One still filling in - its counts not all there - is left for the
	reading again ( JEWEL_READ_AGAIN ). One whose grades are not the ones the
	book's first answer had is not kept, and said once a book: what is
	written has one list of grades for every skill.
]]
local function bookAnswer( gump )
	local book = Book
	if ( book == nil ) then
		return
	end
	local skill = gumpFirstTid( gump )
	local counts, read = bookCounts( gump )
	local tiers = bookTiers( gump )
	if ( skill == nil or counts == nil or #tiers == 0 or read < #tiers ) then
		return
	end
	if ( book.tiers == nil ) then
		book.tiers = tiers
	elseif ( not sameTiers( book.tiers, tiers ) ) then
		if ( not book.odd ) then
			book.odd = true
			say( txt( TID_PREFIX ) .. tidTextW( skill ) .. SEPARATOR .. txt( TID_BOOK_TIERS ) )
		end
		return
	end
	if ( book.skills[ skill ] == nil ) then
		book.order[ #book.order + 1 ] = skill
	end
	book.skills[ skill ] = counts
end


--[[
	One page of a scroll book, as a generic gump's data arrives
	( CPlusHomeRecord.onJewelParse ). Nothing happens unless a book's window is
	there, which is all that happens for any other gump; and outside every
	house, or with recording off, no book is started. The contents start a
	book or go on with one ( bookContents ), an answer is kept ( bookAnswer ),
	and the window the page came in is noted last, for bookClosing. Unless
	this is that reading, the page is read once more JEWEL_READ_AGAIN later,
	for an answer still filling in and for buttons shown late.
]]
function readBookPage( again )
	local gump = bookGump()
	if ( gump == nil ) then
		return
	end
	local place = Book ~= nil and Book.place or gatherPlace()
	if ( place == nil ) then
		return
	end

	local page = bookPageKind( gump )
	if ( page == BOOK_PAGE.CONTENTS ) then
		bookContents( gump, place )
	elseif ( page == BOOK_PAGE.ANSWER ) then
		bookAnswer( gump )
	end

	local book = Book
	if ( book == nil ) then
		return
	end
	book.window = gump.windowName

	if ( not again ) then
		ClfCommon.setTimeout( "CPlusHomeRecord.bookPage." .. numA( book.serial ) .. "." .. gump.windowName, {
			timeout = ClfCommon.TimeSinceLogin + JEWEL_READ_AGAIN,
			done = function()
				isolated( "CPlusHomeRecord.bookPage", readBookPage, true )
			end,
		} )
	end
end


-- JEWEL_CLOSE_WAIT after the book's window named name shut down: it was closed
-- when no page has come since in another window, and no book window is there
-- ( see jewelClosing for why the name decides, not the moment alone ).
local function bookClosing( book, name )
	if ( Book ~= book or book.window ~= name or bookGump() ~= nil ) then
		return
	end
	endBook( book )
end


--[[
	Before the original GenericGump.Shutdown ( CPlusHomeRecord.onGumpShutdown ):
	if the window shutting down is the book's while one is being gathered, look
	again JEWEL_CLOSE_WAIT later, with that window's name ( bookClosing ). Every
	answer comes in a window of its own and the one before shuts down, so this
	runs on every page turned. Nothing here calls into the engine.
]]
function bookShutdown()
	local book = Book
	if ( book == nil ) then
		return
	end
	local name = SystemData.ActiveWindow.name
	if ( type( name ) ~= "string" ) then
		return
	end
	local list = GenericGump and GenericGump.GumpsList
	local listed = type( list ) == "table" and list[ name ] or nil
	local gumps = GumpData and GumpData.Gumps
	local gump = type( gumps ) == "table" and gumps[ BOOK_GUMP_ID ] or nil
	if ( listed ~= BOOK_GUMP_ID and not ( type( gump ) == "table" and gump.windowName == name ) ) then
		return
	end
	ClfCommon.setTimeout( "CPlusHomeRecord.bookClosing." .. numA( book.serial ) .. "." .. name, {
		timeout = ClfCommon.TimeSinceLogin + JEWEL_CLOSE_WAIT,
		done = function()
			isolated( "CPlusHomeRecord.bookClosing", function()
				bookClosing( book, name )
			end )
		end,
	} )
end

--[[
** Called from the .mod OnShutdown: a jewel box, a scroll book or a locker
*  being gathered when the UI goes ( reloaded, or logging out ) is written
*  with what was gathered by then.
]]
function CPlusHomeRecord.shutdown()
	if ( Jewel ~= nil ) then
		isolated( "CPlusHomeRecord.jewelEnd", endJewel, Jewel )
	end
	if ( Book ~= nil ) then
		isolated( "CPlusHomeRecord.bookEnd", endBook, Book )
	end
	if ( Locker.current ~= nil ) then
		isolated( "CPlusHomeRecord.lockerEnd", Locker.finish, Locker.current )
	end
end


----------------------------------------------------------------
-- The Davies' lockers
----------------------------------------------------------------

--[[
	A Davies' locker holds treasure maps and SOS bottles, and shows them in a
	generic gump of its own ( 999102 ), ten rows a page. Measured
	in game on a locker, several pages ( among them the last, with a SOS
	unopened and opened ). Each page came in a window of a name of
	its own, so the gump is taken to be made again for every page turned, as a
	scroll book's is. The locker is six blocks, each named 「デイビーズの
	ロッカー」, and whichever is double-clicked opens the same gump.

	**The player turns the pages; nothing here presses anything.** Its buttons
	take a map out, add one, or turn a page. A locker is gathered from the page
	it opens at until it closes, and written then as one record: JEWEL_CLOSE_WAIT
	after a window of it shuts down, when no page has come since in another
	window ( Locker.closing - the window's name decides, as for a cabinet ). A page
	of a locker in another house ends the one gathered, which is written first.
	Outside every house, or with recording off, nothing is read.

	A page, as Locker.readPage reads it - from the gump's data alone:

	  - The labels in the order they are shown ( labelsInOrder ), the first ten
	    the heading ( Locker.HEADING ): the title 1153552, five column heads,
	    「地図: ~1_NUM~ / ~2_MAX~」 1153560 ( its params the maps and SOS held,
	    and the room ), 「~1_CUR~ / ~2_MAX~ 頁」 1153561 ( this page and the
	    pages ), ページ and 地図の追加.
	  - After it the rows. A row begins with its coordinates: a text label
	    ( "<BASEFONT COLOR=#FFFF88>25N 40W</BASEFONT>" ) or 1153569 「不明」.
	    A map's row is five labels - coordinates, facet, 「〜の」, grade,
	    status - and a SOS's four - coordinates, facet ( 1153567 「T / F」 ),
	    1153568 「SOS」 and status. A row of any other shape is kept as the text
	    of its labels, never dropped.
	  - The page's number is the gump's own ( 1153561 ), not counted from
	    presses: a page seen again takes the place of what was read of it.

	Which locker it is: the house. The record's box is the item of the latest
	use ( Use.latest ) when its first property line reads as the title - the
	title's marks taken off both - and 0 when that cannot be said; the search
	page puts a house's locker records together whatever their box, so two
	lockers in one house are shown as one.
	A use is taken by one locker at most.

	The record, after the head every record begins with ( its box's parent 0 ):

	  locker     <pages seen> <pages> <rows read> <maps held> <room> <box confirmed 1/0> <title>
	  lockerrow  <page> <map or sos> <coordinates> <facet tid> <facet> <「〜の」 tid> <「〜の」>
	             <grade tid> <grade> <status tid> <status>     ( a SOS's 「〜の」 and grade "-" )
	  lockerodd  <page> <the text of each label>...            ( a row of another shape )
	  count 0 0, and END

	A page whose number could not be read writes "-" for it. Whether the locker
	was read to the end is not written: the search page works it out.
]]
Locker.GUMP_ID = 999102

-- The game's tids, as measured above.
Locker.TID = {
	TITLE = 1153552,    -- 「デイビーズのロッカー」, the first label
	COUNT = 1153560,    -- 「地図: ~1_NUM~ / ~2_MAX~」: the maps and SOS held, and the room
	PAGE = 1153561,     -- 「~1_CUR~ / ~2_MAX~ 頁」: this page, and the pages
	UNKNOWN = 1153569,  -- 「不明」: coordinates not known, a row's first label
	SOS = 1153568,      -- 「SOS」: a SOS's row's third label
}

-- The labels before the first row ( every page measured ), and how many a
-- map's row and a SOS's row hold.
Locker.HEADING = 10
Locker.MAP_LABELS = 5
Locker.SOS_LABELS = 4

-- The marks round a text of the gump, taken out as Default's
-- WindowUtils.translateMarkup takes out "anything else between < >"
-- ( Source/WindowUtils.lua ).
Locker.MARK = L"<.->"

-- The locker being gathered, from its first page until it is written, or nil;
-- the number of the latest one, part of its timers' names; and the number of
-- the latest use taken for a locker's box ( Use.serial ), so that one use
-- names one locker at most.
Locker.current = nil
Locker.serial = 0
Locker.spent = 0


--[[
	A text with its marks taken out ( <BASEFONT ...>, <DIV ...> and their ends ),
	or nil when there is none or nothing is left. Checked as fieldW's steps are:
	LuaPlus's wstring.gsub can hand back a narrow string, above all an empty one.
]]
function Locker.plain( text )
	if ( type( text ) ~= "wstring" or text == L"" ) then
		return nil
	end
	local result = wstring.gsub( text, Locker.MARK, L"" )
	if ( type( result ) == "string" and result ~= "" ) then
		result = towstring( result )
	end
	if ( type( result ) ~= "wstring" or result == L"" ) then
		return nil
	end
	return result
end


-- A tid's text as the client gives it, or nil.
function Locker.textOf( tid )
	if ( type( tid ) ~= "number" ) then
		return nil
	end
	local ok, text = pcall( GetStringFromTid, tid )
	if ( ok ) then
		return text
	end
	return nil
end


-- A label's text: its tid's, or a text label's own. nil when it has neither.
function Locker.labelText( label )
	if ( type( label.tid ) == "number" ) then
		return Locker.textOf( label.tid )
	end
	if ( type( label.text ) == "table" and type( label.text[ 1 ] ) == "wstring" ) then
		return label.text[ 1 ]
	end
	return nil
end


-- Whether a label begins a row: coordinates, as a text label or 「不明」.
function Locker.startsRow( label )
	return type( label.text ) == "table" or label.tid == Locker.TID.UNKNOWN
end


-- The locker's gump while its window is there, or nil: gump 999102 whose first
-- label is the locker's title.
function Locker.gump()
	local gumps = GumpData and GumpData.Gumps
	local gump = type( gumps ) == "table" and gumps[ Locker.GUMP_ID ] or nil
	if ( type( gump ) ~= "table" or type( gump.windowName ) ~= "string"
		or not DoesWindowExist( gump.windowName ) ) then
		return nil
	end
	local first = labelsInOrder( gump )[ 1 ]
	if ( type( first ) ~= "table" or first.tid ~= Locker.TID.TITLE ) then
		return nil
	end
	return gump
end


--[[
	One page of the locker, from its gump's data alone:

	  { number, pages, count, room, rows = { row... } }

	number and pages from 1153561, count and room from 1153560, each nil when
	not read. A row is Locker.readRow's.
]]
function Locker.readPage( gump )
	local ordered = labelsInOrder( gump )
	local page = { rows = {} }
	for i = 1, #ordered do
		local label = ordered[ i ]
		if ( type( label.tidParms ) == "table" ) then
			if ( label.tid == Locker.TID.COUNT ) then
				page.count = countOf( label.tidParms[ 1 ] )
				page.room = countOf( label.tidParms[ 2 ] )
			elseif ( label.tid == Locker.TID.PAGE ) then
				page.number = countOf( label.tidParms[ 1 ] )
				page.pages = countOf( label.tidParms[ 2 ] )
			end
		end
	end
	-- Rows run from a row's first label to the label before the next one's. A
	-- label after the heading that comes before any first label is a row of its
	-- own, of no shape ( Locker.readRow ).
	local rows = {}
	local labels = nil
	for i = Locker.HEADING + 1, #ordered do
		local label = ordered[ i ]
		if ( labels == nil or Locker.startsRow( label ) ) then
			labels = {}
			rows[ #rows + 1 ] = labels
		end
		labels[ #labels + 1 ] = label
	end
	for k = 1, #rows do
		page.rows[ k ] = Locker.readRow( rows[ k ] )
	end
	return page
end


--[[
	One row, from its labels:

	  a map   { kind = "map", coords, facet, facetText, prefix, prefixText, tier,
	            tierText, status, statusText }
	  a SOS   { kind = "sos", coords, facet, facetText, status, statusText }
	  other   { kind = "odd", texts = { the text of each label }, labels }

	coords is the first label's text with its marks taken out ( 「不明」 as the
	client gives it ). A map is five labels, a SOS four with 「SOS」 third - the
	first a row's first, every other one a tid's - and nothing else is either:
	its labels' texts are kept as they are.
]]
function Locker.readRow( labels )
	local count = #labels
	local shaped = Locker.startsRow( labels[ 1 ] ) and ( count == Locker.MAP_LABELS
		or ( count == Locker.SOS_LABELS and labels[ 3 ].tid == Locker.TID.SOS ) )
	for k = 2, count do
		if ( type( labels[ k ].tid ) ~= "number" ) then
			shaped = false
		end
	end
	if ( not shaped ) then
		local texts = {}
		for k = 1, count do
			texts[ k ] = Locker.labelText( labels[ k ] )
		end
		return { kind = "odd", texts = texts, labels = count }
	end

	local row = { kind = "map", coords = Locker.plain( Locker.labelText( labels[ 1 ] ) ) }
	if ( count == Locker.SOS_LABELS ) then
		row.kind = "sos"
	else
		row.prefix = labels[ 3 ].tid
		row.prefixText = Locker.textOf( row.prefix )
		row.tier = labels[ 4 ].tid
		row.tierText = Locker.textOf( row.tier )
	end
	row.facet = labels[ 2 ].tid
	row.facetText = Locker.textOf( row.facet )
	row.status = labels[ count ].tid
	row.statusText = Locker.textOf( row.status )
	return row
end


--[[
	A locker to gather, from the moment its first page comes: place is where the
	player stands ( gatherPlace ), and title the gump's, its marks taken out.
	The latest use not yet taken for a locker is kept as the box to confirm
	( Locker.confirm ).
]]
function Locker.start( place, title )
	Locker.serial = Locker.serial + 1
	local locker = {
		serial = Locker.serial,
		box = 0,
		use = nil,          -- the item used that may be the locker, until confirmed
		confirmed = false,  -- whether box is that item, its name read as the title
		title = title,
		parent = 0,
		house = place.house,
		x = place.x,
		y = place.y,
		z = place.z,
		facet = place.facet,
		openedAt = ClfUtil.getClockString(),
		pages = {},         -- page number -> the page as it was last seen
		loose = {},         -- the pages whose number was not read, in the order seen
		pageCount = nil,    -- the pages, as the latest page said
		count = nil,        -- the maps and SOS held, as the latest page said
		room = nil,         -- the room, as the latest page said
		window = nil,       -- the window the latest page came in ( Locker.closing )
	}
	local use = Use.latest
	if ( use ~= nil and use.serial > Locker.spent ) then
		locker.use = use.item
		Locker.spent = use.serial
	end
	return locker
end


-- The locker's box confirmed, when it has not been yet and the item used
-- names itself as the title does ( its properties registered if missing,
-- propertiesOf ). Asked on every page, and once more as it is written.
function Locker.confirm( locker )
	if ( locker.confirmed or locker.use == nil or locker.title == nil ) then
		return
	end
	local props = propertiesOf( locker.use )
	local list = props and props.PropertiesList
	if ( type( list ) == "table" and Locker.plain( list[ 1 ] ) == locker.title ) then
		locker.confirmed = true
		locker.box = locker.use
	end
end


--[[
	After a generic gump's data arrives ( CPlusHomeRecord.onJewelParse ): when the
	locker's window is there and the player is in a house with recording on,
	its page is read and put in the place of its number. A page of a locker
	in another house ends the one being gathered first. The window the page
	came in is noted last, for Locker.closing. The same window's data coming
	again reads the same page again, and changes nothing.
]]
function Locker.onPage()
	local gump = Locker.gump()
	if ( gump == nil ) then
		return
	end
	local place = gatherPlace()
	if ( place == nil ) then
		return
	end
	local locker = Locker.current
	if ( locker ~= nil and locker.house ~= place.house ) then
		Locker.finish( locker )
		locker = nil
	end
	local page = Locker.readPage( gump )
	if ( locker == nil ) then
		locker = Locker.start( place, Locker.plain( Locker.textOf( Locker.TID.TITLE ) ) )
		Locker.current = locker
		watchGumpShutdown()
	end
	if ( page.number ~= nil ) then
		locker.pages[ page.number ] = page
	else
		locker.loose[ #locker.loose + 1 ] = page
	end
	if ( page.pages ~= nil ) then
		locker.pageCount = page.pages
	end
	if ( page.count ~= nil ) then
		locker.count = page.count
		locker.room = page.room
	end
	Locker.confirm( locker )
	locker.window = gump.windowName
end


--[[
	Before the original GenericGump.Shutdown ( CPlusHomeRecord.onGumpShutdown ):
	if the window shutting down is the locker's while one is being gathered,
	look again JEWEL_CLOSE_WAIT later, with that window's name ( Locker.closing ),
	as bookShutdown does for a scroll book.
]]
function Locker.onShutdown()
	local locker = Locker.current
	if ( locker == nil ) then
		return
	end
	local name = SystemData.ActiveWindow.name
	if ( type( name ) ~= "string" ) then
		return
	end
	local list = GenericGump and GenericGump.GumpsList
	local listed = type( list ) == "table" and list[ name ] or nil
	local gumps = GumpData and GumpData.Gumps
	local gump = type( gumps ) == "table" and gumps[ Locker.GUMP_ID ] or nil
	if ( listed ~= Locker.GUMP_ID and not ( type( gump ) == "table" and gump.windowName == name ) ) then
		return
	end
	ClfCommon.setTimeout( "CPlusHomeRecord.lockerClosing." .. numA( locker.serial ) .. "." .. name, {
		timeout = ClfCommon.TimeSinceLogin + JEWEL_CLOSE_WAIT,
		done = function()
			isolated( "CPlusHomeRecord.lockerClosing", function()
				Locker.closing( locker, name )
			end )
		end,
	} )
end


-- JEWEL_CLOSE_WAIT after the locker's window named name shut down: it was
-- closed when no page has come since in another window, and no locker window
-- is there ( see jewelClosing for why the name decides, not the moment alone ).
function Locker.closing( locker, name )
	if ( Locker.current ~= locker or locker.window ~= name or Locker.gump() ~= nil ) then
		return
	end
	Locker.finish( locker )
end


-- The pages seen, in the order they are written: the numbered ones by number,
-- then those with no number. Each is { number, page }.
function Locker.pagesInOrder( locker )
	local numbers = {}
	for number in pairs( locker.pages ) do
		numbers[ #numbers + 1 ] = number
	end
	table.sort( numbers )
	local ordered = {}
	for i = 1, #numbers do
		ordered[ #ordered + 1 ] = { number = numbers[ i ], page = locker.pages[ numbers[ i ] ] }
	end
	for i = 1, #locker.loose do
		ordered[ #ordered + 1 ] = { number = nil, page = locker.loose[ i ] }
	end
	return ordered
end


-- A tid for the record, "-" for none ( numA ), and its text as a field, "-"
-- for none: a SOS has no 「〜の」 and no grade.
function Locker.textField( tid, text )
	if ( type( tid ) ~= "number" ) then
		return "-"
	end
	return fieldW( text )
end


--[[
	The file for one locker ( the records in the note at the top of this
	section ). Returns the line for chat: the rows read out of the maps and SOS
	the locker says it holds, and the pages seen out of its pages.

	A row of no shape writes each label's text as a field of its own: the
	texts, each through fieldW - which leaves no TAB in it - are joined by TAB
	into one piece, since the number of labels is the row's own.
]]
function Locker.write( locker )
	local body = {}
	local ordered = Locker.pagesInOrder( locker )
	local read = 0
	for i = 1, #ordered do
		read = read + #ordered[ i ].page.rows
	end

	writeHead( body, locker.box, locker )
	local confirmed = "0"
	if ( locker.confirmed ) then
		confirmed = "1"
	end
	row( body, "locker", numA( #ordered ), numA( locker.pageCount ), numA( read ), numA( locker.count ),
		numA( locker.room ), confirmed, fieldW( locker.title ) )

	for i = 1, #ordered do
		local number = numA( ordered[ i ].number )
		local rows = ordered[ i ].page.rows
		for k = 1, #rows do
			local r = rows[ k ]
			if ( r.kind == "odd" ) then
				local texts = L""
				for n = 1, r.labels do
					if ( n > 1 ) then
						texts = texts .. TAB
					end
					texts = texts .. fieldW( r.texts[ n ] )
				end
				row( body, "lockerodd", number, texts )
			else
				row( body, "lockerrow", number, r.kind, fieldW( r.coords ), numA( r.facet ), fieldW( r.facetText ),
					numA( r.prefix ), Locker.textField( r.prefix, r.prefixText ), numA( r.tier ), Locker.textField( r.tier, r.tierText ),
					numA( r.status ), fieldW( r.statusText ) )
			end
		end
	end

	row( body, "count", numA( 0 ), numA( 0 ) )
	row( body, "END" )

	Serial = Serial + 1
	ClfUtil.exportStr( joinW( body ), EXPORT_PREFIX .. numA( locker.house ),
		"_" .. numA( locker.box ) .. "_" .. numA( Serial ), EXPORT_DIR, true )

	return txt( TID_PREFIX ) .. houseW( locker.house ) .. L": " .. ( locker.title or L"-" )
		.. SEPARATOR .. txt( TID_ITEMS ) .. towstring( numA( read ) .. "/" .. numA( locker.count ) )
		.. SEPARATOR .. txt( TID_PAGES ) .. towstring( numA( #ordered ) .. "/" .. numA( locker.pageCount ) )
end


--[[
	Ends a locker: forgotten first, so that a write that fails cannot leave it
	behind, then written unless recording has been turned off meanwhile, and
	its line said. Written whether its box was confirmed or not ( the record
	says which ): the search page puts a house's locker together by the house.
]]
function Locker.finish( locker )
	if ( Locker.current == locker ) then
		Locker.current = nil
	end
	if ( not CPlusHomeRecord.Enable ) then
		return
	end
	Locker.confirm( locker )
	local ok, result = pcall( Locker.write, locker )
	if ( ok ) then
		say( result )
		return
	end
	local reason = ""
	if ( type( result ) == "string" ) then
		reason = " ( " .. result .. " )"
	end
	local okLine, line = pcall( failedLine, locker.box, reason )
	if ( not okLine ) then
		line = towstring( "CPlusHomeRecord: write failed, locker " .. numA( locker.box ) .. reason )
	end
	say( line )
end


----------------------------------------------------------------
-- Macros
----------------------------------------------------------------

--[[
** Add where you stand as a corner of house n ( script CPlusHomeRecord.corner( 1 ) )
*
*  The house's area is the rectangle round its corners. A corner is not added -
*  nothing changes, and chat says why - when the house has AREA.MAX_CORNERS
*  already, or when the area would grow past AREA.MAX_SIDE tiles a side
*  ( areaFits ). A house registered larger, or with more corners, stays as it
*  is. When the last corner leaves the area one tile wide, chat says to choose
*  opposite corners.
]]
function CPlusHomeRecord.corner( n )
	local number = houseNumber( n )
	if ( number == nil ) then
		return
	end

	local x, y, _, facet = position()
	if ( x == nil ) then
		say( txt( TID_PREFIX ) .. txt( TID_NO_POSITION ) )
		return
	end

	local house = Houses[ number ]
	if ( house and house.facet ~= facet ) then
		say( txt( TID_PREFIX ) .. houseW( number ) .. L": " .. txt( TID_FACET ) .. towstring( numA( house.facet ) )
			.. txt( TID_OTHER_FACET ) .. towstring( "script CPlusHomeRecord.clear( " .. numA( number ) .. " )" ) )
		return
	end

	local limit = CPlusHomeRecord.AREA
	if ( house and house.corners >= limit.MAX_CORNERS ) then
		say( txt( TID_PREFIX ) .. houseW( number ) .. txt( TID_AREA.FULL ) .. towstring( numA( limit.MAX_CORNERS ) )
			.. txt( TID_AREA.FULL_TAIL ) .. againW() )
		return
	end

	-- A new table, so that a corner refused leaves the house as it was.
	local grown = { corners = 1, facet = facet, minX = x, maxX = x, minY = y, maxY = y }
	if ( house ) then
		grown.corners = house.corners + 1
		grown.minX = math.min( house.minX, x )
		grown.maxX = math.max( house.maxX, x )
		grown.minY = math.min( house.minY, y )
		grown.maxY = math.max( house.maxY, y )
	end
	if ( not CPlusHomeRecord.areaFits( grown ) ) then
		say( txt( TID_PREFIX ) .. houseW( number ) .. txt( TID_AREA.WIDE ) .. towstring( numA( limit.MAX_SIDE ) )
			.. txt( TID_AREA.WIDE_TAIL ) .. houseSummaryW( house ) .. againW() )
		return
	end

	Houses[ number ] = grown
	saveHouse( number, grown )

	say( txt( TID_PREFIX ) .. houseW( number ) .. txt( TID_CORNER_ADDED ) .. SEPARATOR .. houseSummaryW( grown ) )
	if ( grown.corners == limit.MAX_CORNERS and ( grown.minX == grown.maxX or grown.minY == grown.maxY ) ) then
		say( txt( TID_PREFIX ) .. houseW( number ) .. txt( TID_AREA.LINE ) .. againW() )
	end
end


--[[
** Forget house n ( script CPlusHomeRecord.clear( 1 ) )
]]
function CPlusHomeRecord.clear( n )
	local number = houseNumber( n )
	if ( number == nil ) then
		return
	end

	Houses[ number ] = nil
	Interface.SaveNumber( houseKey( number, "Corners" ), 0 )

	say( txt( TID_PREFIX ) .. houseW( number ) .. txt( TID_CLEARED ) )
end


local function onOffW()
	if ( CPlusHomeRecord.Enable ) then
		return L"ON"
	end
	return L"OFF"
end


--[[
** Houses, where you are and which house that is ( script CPlusHomeRecord.show() )
]]
function CPlusHomeRecord.show()
	say( txt( TID_PREFIX ) .. txt( TID_RECORDING ) .. onOffW() )

	-- Registered houses only; with nine numbers, listing the empty ones
	-- would bury the ones that matter.
	local registered = 0
	for n = 1, MAX_HOUSES do
		local house = Houses[ n ]
		if ( house ) then
			registered = registered + 1
			say( txt( TID_PREFIX ) .. houseW( n ) .. L": " .. houseSummaryW( house ) )
		end
	end
	if ( registered == 0 ) then
		say( txt( TID_PREFIX ) .. txt( TID_NO_HOUSES ) )
	end

	local x, y, z, facet = position()
	if ( x == nil ) then
		say( txt( TID_PREFIX ) .. txt( TID_NO_POSITION ) )
		return
	end
	say( txt( TID_PREFIX ) .. txt( TID_NOW_AT )
		.. towstring( "x " .. numA( x ) .. " y " .. numA( y ) .. " z " .. numA( z ) .. " facet " .. numA( facet ) ) )

	local house = houseAt( x, y, facet )
	if ( house ) then
		say( txt( TID_PREFIX ) .. txt( TID_INSIDE ) .. houseW( house ) )
	else
		say( txt( TID_PREFIX ) .. txt( TID_OUTSIDE ) )
	end
end


--[[
** Recording ON / OFF ( script CPlusHomeRecord.toggle() )
]]
function CPlusHomeRecord.toggle()
	CPlusHomeRecord.Enable = not CPlusHomeRecord.Enable
	Interface.SaveBoolean( KEY_ENABLE, CPlusHomeRecord.Enable )
	say( txt( TID_PREFIX ) .. txt( TID_RECORDING ) .. onOffW() )
end


----------------------------------------------------------------
-- Pasting the areas ( CPlusHomeArea.lua )
----------------------------------------------------------------

--[[
** Register the houses of a line the search page copied, which the Paste the
*  areas window ( CPlusHomeArea.lua ) has read: list holds { n, facet, minX,
*  maxX, minY, maxY } for each house, in the order of the line. So that this
*  character's numbers are the search page's:
*
*  - each house is registered under its number, over what that number held,
*    with 2 corners: its area is the rectangle two opposite corners make;
*  - a registered number that is not in the list, and whose area shares a
*    tile with one of the list's ( on the same facet, edges included, as
*    houseAt takes a house ), is cleared as clear( n ) clears it: a house held
*    under two numbers has its boxes recorded under the smaller, and the
*    other number is never used;
*  - every other registered house is left as it is;
*  - recording is turned on.
*
*  A list with anything in it that is not a house under a number 1 to
*  MAX_HOUSES, with a number twice, or with a house wider or taller than
*  AREA.MAX_SIDE tiles ( areaFits ), is refused whole: nothing changes and
*  the answer is false. Otherwise chat has a line for each house registered
*  and for each cleared, then one for recording, and the answer is true.
]]
function CPlusHomeRecord.pasteAreas( list )
	if ( type( list ) ~= "table" or #list < 1 ) then
		return false
	end
	local inList = {}
	for i = 1, #list do
		local house = list[ i ]
		if ( type( house ) ~= "table" or type( house.n ) ~= "number" or house.n ~= math.floor( house.n )
			or house.n < 1 or house.n > MAX_HOUSES or inList[ house.n ]
			or type( house.facet ) ~= "number" or type( house.minX ) ~= "number" or type( house.maxX ) ~= "number"
			or type( house.minY ) ~= "number" or type( house.maxY ) ~= "number"
			or not CPlusHomeRecord.areaFits( house ) ) then
			return false
		end
		inList[ house.n ] = true
	end

	-- Whether two areas share a tile.
	local function overlaps( a, b )
		return a.facet == b.facet and a.minX <= b.maxX and b.minX <= a.maxX and a.minY <= b.maxY and b.minY <= a.maxY
	end

	-- The registered houses that go, each with the first house of the list it
	-- overlaps, looked for before anything is written.
	local cleared = {}
	for m = 1, MAX_HOUSES do
		local old = Houses[ m ]
		if ( old and not inList[ m ] ) then
			for i = 1, #list do
				if ( overlaps( old, list[ i ] ) ) then
					cleared[ #cleared + 1 ] = { n = m, by = list[ i ].n }
					break
				end
			end
		end
	end

	for i = 1, #list do
		local pasted = list[ i ]
		local house = { corners = 2, facet = pasted.facet, minX = pasted.minX, maxX = pasted.maxX, minY = pasted.minY, maxY = pasted.maxY }
		Houses[ pasted.n ] = house
		saveHouse( pasted.n, house )
	end
	for i = 1, #cleared do
		Houses[ cleared[ i ].n ] = nil
		Interface.SaveNumber( houseKey( cleared[ i ].n, "Corners" ), 0 )
	end
	CPlusHomeRecord.Enable = true
	Interface.SaveBoolean( KEY_ENABLE, CPlusHomeRecord.Enable )

	for i = 1, #list do
		local n = list[ i ].n
		say( txt( TID_PREFIX ) .. houseW( n ) .. txt( TID_PASTE.DONE ) .. txt( TID_OPEN ) .. houseSummaryW( Houses[ n ] ) .. txt( TID_CLOSE ) )
	end
	for i = 1, #cleared do
		say( txt( TID_PREFIX ) .. houseW( cleared[ i ].n ) .. txt( TID_PASTE.CLEARED ) .. houseW( cleared[ i ].by ) .. txt( TID_PASTE.OVERLAP ) )
	end
	say( txt( TID_PREFIX ) .. txt( TID_RECORDING ) .. onOffW() )
	return true
end


----------------------------------------------------------------
-- Hotbar menu
----------------------------------------------------------------

--[[
	The return codes of the menu items. Letters and digits only, and chosen so
	that none of them contains, or is contained in, any string that
	Hotbar.ContextMenuCallback ( Source/hotbar.lua:533-633 ) or
	HotbarSystem.ContextMenuCallback ( Source/HotbarSystem.lua:1629-1675 )
	looks for: "minitxt", "familiar", "enchant", "animalForm", "spellTrigger"
	and "polymorph" are searched for before this module sees anything, and
	"org" and "undr" after it, whatever it answered.
]]
local CODE = { CORNER = "cplushomeAdd", CLEAR = "cplushomeDel", SHOW = "cplushomeShow", ONOFF = "cplushomeOnOff", PASTE = "cplushomePaste" }


-- Is this the window of a hotbar slot, rather than a macro window's?
local function isHotbarSlot( name )
	return type( name ) == "string" and string.find( name, "^Hotbar%d+Button%d+$" ) ~= nil
end


-- One sub-menu item, in the shape Default builds its own
-- ( Source/HotbarSystem.lua:1605 ).
local function menuItem( str, returnCode, param, pressed )
	return { str = str, flags = 0, returnCode = returnCode, param = param, pressed = pressed }
end


--[[
	Add this module's items to a right-click menu being built, when the menu is
	for the Home Record icon on a hotbar - and for nothing else. The original
	has already added its own items by now.
]]
local function addMenu( call )
	if ( not isHotbarSlot( call.slotWindow ) ) then
		return
	end

	local actionType = UserActionGetType( call.hotbarId, call.itemIndex, call.subIndex )
	if ( actionType ~= SystemData.UserAction.TYPE_SPEECH_USER_COMMAND ) then
		return
	end
	if ( UserActionGetId( call.hotbarId, call.itemIndex, call.subIndex ) ~= CPlusHomeRecord.MENU_ACTION ) then
		return
	end

	-- The same shape as Default's ( Source/HotbarSystem.lua:1348 ).
	local param = {
		HotbarId = call.hotbarId,
		ItemIndex = call.itemIndex,
		SubIndex = call.subIndex,
		SlotWindow = call.slotWindow,
		ActionType = actionType,
	}

	local corners = {}
	local clears = {}
	for n = 1, MAX_HOUSES do
		local house = Houses[ n ]
		local label
		if ( house ) then
			label = houseW( n ) .. txt( TID_OPEN ) .. txt( TID_CORNERS ) .. towstring( numA( house.corners ) ) .. txt( TID_CLOSE )
			clears[ #clears + 1 ] = menuItem( houseW( n ), CODE.CLEAR .. numA( n ), param, false )
		else
			label = houseW( n ) .. txt( TID_OPEN ) .. txt( TID_UNREGISTERED ) .. txt( TID_CLOSE )
		end
		corners[ #corners + 1 ] = menuItem( label, CODE.CORNER .. numA( n ), param, false )
	end

	-- A parent item carries no return code of its own, as Default's do
	-- ( Source/HotbarSystem.lua:1609 ).
	ContextMenu.CreateLuaContextMenuItemWithString( txt( TID_MENU.CORNER ), 0, 0, "null", false, corners )
	if ( #clears > 0 ) then
		ContextMenu.CreateLuaContextMenuItemWithString( txt( TID_MENU.CLEAR ), 0, 0, "null", false, clears )
	end
	ContextMenu.CreateLuaContextMenuItemWithString( txt( TID_MENU.SHOW ), 0, CODE.SHOW, param, false )
	ContextMenu.CreateLuaContextMenuItemWithString( txt( TID_MENU.RECORDING ), 0, CODE.ONOFF, param, CPlusHomeRecord.Enable == true )
	ContextMenu.CreateLuaContextMenuItemWithString( txt( TID_MENU.PASTE ), 0, CODE.PASTE, param, false )
end


--[[
	What a return code asks for, or nil when it is not one of this module's.
	Only strings can be; a number, or the 0 a parent item carries, is not.
]]
local function menuCommand( returnCode )
	if ( type( returnCode ) ~= "string" ) then
		return nil
	end
	if ( returnCode == CODE.SHOW ) then
		return { run = "show" }
	end
	if ( returnCode == CODE.ONOFF ) then
		return { run = "toggle" }
	end
	if ( returnCode == CODE.PASTE ) then
		return { run = "paste" }
	end
	local n = string.match( returnCode, "^" .. CODE.CORNER .. "(%d+)$" )
	if ( n ) then
		return { run = "corner", house = tonumber( n ) }
	end
	n = string.match( returnCode, "^" .. CODE.CLEAR .. "(%d+)$" )
	if ( n ) then
		return { run = "clear", house = tonumber( n ) }
	end
	return nil
end


local function runMenuCommand( command )
	if ( command.run == "corner" ) then
		CPlusHomeRecord.corner( command.house )
	elseif ( command.run == "clear" ) then
		CPlusHomeRecord.clear( command.house )
	elseif ( command.run == "show" ) then
		CPlusHomeRecord.show()
	elseif ( command.run == "toggle" ) then
		CPlusHomeRecord.toggle()
	elseif ( command.run == "paste" ) then
		CPlusHomeArea.open()
	end
end


--[[
	Wraps HotbarSystem.CreateUserActionContextMenuOptions.

	Every icon's right-click menu is built through this, and so are the macro
	windows' ( Source/MacroEditWindow.lua:257, Source/MacroWindow.lua:186 ). So
	the original is called first, whatever happens, and this module's items
	are added after it, kept apart, and only for its own icon on a hotbar.

	The arguments go to the original as ... rather than by name, so that if a
	publish gives Default's original another argument, it still reaches the
	original instead of being dropped on every icon's menu.
]]
function CPlusHomeRecord.onCreateUserActionContextMenuOptions( ... )
	local results = { CPlusHomeRecord.CreateUserActionContextMenuOptions_org( ... ) }

	local hotbarId, itemIndex, subIndex, slotWindow = ...
	isolated( "CPlusHomeRecord.addMenu", addMenu, {
		hotbarId = hotbarId,
		itemIndex = itemIndex,
		subIndex = subIndex,
		slotWindow = slotWindow,
	} )

	return unpack( results )
end


--[[
	Wraps HotbarSystem.ContextMenuCallback.

	The original is called first, whatever the return code. For one of this
	module's codes it only compares and answers false ( :1630-1674 ), so
	nothing happens twice. Then, for this module's codes, the command runs
	kept apart and the answer is true, so that Hotbar.ContextMenuCallback does
	not go on to look for a hotbar item of its own; for anything else the
	original's answer is passed back unchanged.

	The arguments go to the original as ..., for the same reason as the menu
	wrapper above: an argument a publish adds is passed on, not dropped.
]]
function CPlusHomeRecord.onContextMenuCallback( ... )
	local results = { CPlusHomeRecord.ContextMenuCallback_org( ... ) }

	local returnCode = ...
	local command = menuCommand( returnCode )
	if ( command == nil ) then
		return unpack( results )
	end

	isolated( "CPlusHomeRecord.runMenuCommand", runMenuCommand, command )
	return true
end


--[[
	Reads the switch and the houses from the settings. Called by initialize,
	so that what is recorded goes by what is saved.
]]
function CPlusHomeRecord.loadSettings()
	-- On unless turned off: outside a registered house it does nothing and
	-- says nothing, so there is nothing to opt into.
	CPlusHomeRecord.Enable = Interface.LoadBoolean( KEY_ENABLE, true )

	Houses = {}
	for n = 1, MAX_HOUSES do
		Houses[ n ] = loadHouse( n )
	end
end


--[[
** Called from the .mod OnInitialize
*
*  CPlusHomeRecord.mod depends on ClfContainerMod, whose initialize wraps
*  ContainerWindow.Initialize first ( ClfContnrWin.initialize ). This
*  therefore goes round that wrapper, and the check below says so in chat if
*  it ever does not.
]]
function CPlusHomeRecord.initialize()
	CPlusHomeRecord.loadSettings()
	JewelSaid = {}

	if ( not CPlusHomeRecord.Initialize_org ) then
		if ( ClfContnrWin == nil or ContainerWindow.Initialize ~= ClfContnrWin.onWindowInitialize ) then
			pcall( Debug.PrintToChat, L"CPlusHomeRecord : ContainerWindow.Initialize was not ClfContnrWin's when wrapped" )
		end
		CPlusHomeRecord.Initialize_org = ContainerWindow.Initialize
		ContainerWindow.Initialize = CPlusHomeRecord.onInitialize
	end

	if ( not CPlusHomeRecord.Shutdown_org ) then
		CPlusHomeRecord.Shutdown_org = ContainerWindow.Shutdown
		ContainerWindow.Shutdown = CPlusHomeRecord.onShutdown
	end

	-- The hotbar icon's menu. Recording does not depend on it, so a missing
	-- HotbarSystem is said out loud and everything else still goes ahead.
	if ( HotbarSystem and HotbarSystem.CreateUserActionContextMenuOptions and HotbarSystem.ContextMenuCallback ) then
		if ( not CPlusHomeRecord.CreateUserActionContextMenuOptions_org ) then
			CPlusHomeRecord.CreateUserActionContextMenuOptions_org = HotbarSystem.CreateUserActionContextMenuOptions
			HotbarSystem.CreateUserActionContextMenuOptions = CPlusHomeRecord.onCreateUserActionContextMenuOptions
		end
		if ( not CPlusHomeRecord.ContextMenuCallback_org ) then
			CPlusHomeRecord.ContextMenuCallback_org = HotbarSystem.ContextMenuCallback
			HotbarSystem.ContextMenuCallback = CPlusHomeRecord.onContextMenuCallback
		end
	else
		pcall( Debug.PrintToChat, L"CPlusHomeRecord : HotbarSystem not found, no hotbar menu" )
	end

	-- The items used, for which block of a Davies' locker was opened ( Use.watch ).
	Use.watch()

	-- The pages of the jewel box, the scroll book and the locker. ClfjewelryBox is loaded
	-- by ClfContainerMod, which this module depends on; without it neither is
	-- recorded, and the rest goes ahead.
	if ( not CPlusHomeRecord.JewelParse_org ) then
		if ( ClfjewelryBox and type( ClfjewelryBox.gumParse ) == "function" ) then
			CPlusHomeRecord.JewelParse_org = ClfjewelryBox.gumParse
			ClfjewelryBox.gumParse = CPlusHomeRecord.onJewelParse
		else
			pcall( Debug.PrintToChat, L"CPlusHomeRecord : ClfjewelryBox.gumParse not found, jewel boxes, scroll books and lockers are not recorded" )
		end
	end

	-- The icons in the actions window ( CPlusHomeSupport.lua ).
	isolated( "CPlusHomeRecord.installActions", CPlusHomeRecord.installActions )

	pcall( Debug.PrintToChat, L"CPlusHomeRecord : initialized (" .. onOffW() .. L")" )
end
