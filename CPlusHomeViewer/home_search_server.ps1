<#
  The reader for the home record search page (CPlusHomeRecord, PC side). Windows PowerShell 5.1.

  Chrome will not let a page read logs\CPlusExport under Program Files, so this small server hands the
  page the list of records and their text, and keeps the names the page gives to houses, floors and
  boxes. Reading the records is the page's work (home_search_parse.js); this only passes them on.

  Started by double-clicking 家の記録検索.bat next to this file. It opens the page in the browser;
  if it is already running, it only opens the page. The folder this sits in can be anywhere: nothing here
  is found from where this file is.

  The records folder is the first of these:
    1. -RecordsDir, when given. Then it is the only one, and the page cannot change it.
    2. The one the page was told, kept in home_settings.json beside the names ( Read-Settings below ).
       Only a folder named CPlusExport is taken from there, as from the page.
    3. The game's usual place: Electronic Arts\Ultima Online Enhanced\logs\CPlusExport under
       %ProgramFiles(x86)%, then under %ProgramFiles%. When the game's folder is there and logs\CPlusExport
       is not, that logs\CPlusExport is the one, so that the page can say where to make it.
    4. None: the page asks where it is.
  The page tells the reader a folder with POST /api/recordsdir ( Find-RecordsCandidate below ). Only a folder
  named CPlusExport is taken ( a game folder given stands for its logs\CPlusExport ), and what is deleted
  from it is only the files in it named as records are. Where a junction of that name leads is not looked at.

    -Port         where to listen: http://localhost:<Port>/
    -RecordsDir   the folder of the records ( see above ). Only read, apart from deleting records.
    -NamesDir     where the names are kept (home_names.json); by default %LOCALAPPDATA%\CPlusHomeSearch,
                  made when the names are first saved. Not the records folder: under Program Files only
                  administrators may write there (the game writes it elevated; this runs unelevated).
    -UserDataDir  the game's User Data folder, which holds a folder per account, a folder per shard in
                  it and a file per character in that; by default the one found under Documents\EA Games
                  (see Get-UserDataCandidates). Only read - nothing is ever written there.
    -NoBrowser    open no browser, and say a failure to start on stderr, not in a message box
    -IdleMinutes  stop after this long without a request. The page asks every 5 seconds while it is
                  shown, so this runs out once the page is closed (or hidden) for that long.

  Deleting: POST /api/delete takes { "names": [...] } and deletes those records from the records folder.
  It is the one thing here that destroys anything, so it is written to be unable to touch anything else:
  every name must look like a record's name, hold no separator and no "..", and be a file really sitting
  directly in that folder. **Which** records are worth deleting is not decided here - the page decides
  that, because the page is what knows how records are laid over one another, and a copy of that rule
  here would be a second place to keep right. A name that could not be deleted is answered with the
  reason, never counted as done.

  Kept to this PC and to reading: only requests from this PC through localhost:<Port>, only GET apart
  from saving the names, telling the records folder and deleting records, and only the page's own files and
  the records directly in the records folder. No CORS headers, so no other site's page can read the answers. Nothing is written into the
  records folder, and record contents are never written anywhere, logs included.

  All the records at once: GET /api/bundle hands over every record in the folder in one answer, for the
  page's first load ( Send-Bundle below says how it is shaped and why ). GET /api/file?name=<name> still
  hands over one, which is what the page asks with every five seconds and whenever the bundle fails.
#>
param(
    # Chosen for this reader and measured free and listenable without administrator rights;
    # below 49152, so Windows does not hand it out as a temporary port.
    [int]$Port = 47651,
    [string]$RecordsDir = '',
    [string]$NamesDir = '',
    [string]$UserDataDir = '',
    [switch]$NoBrowser,
    [double]$IdleMinutes = 10
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$AppName = 'CPlusHomeSearch'
# 3: /api/chars. 4: /api/bundle. 5: /api/delete. 6: /api/recordsdir. A page newer than a reader still
# running from before gets that reader's 404 not found, which is why every one of these is something the
# page can do without.
$ApiVersion = 6
# The page's own files, by the path they are asked for. Nothing else in this folder is served.
$PageFiles = @{
    '/'                      = @('home_search.html', 'text/html; charset=utf-8')
    '/home_search.html'      = @('home_search.html', 'text/html; charset=utf-8')
    '/home_search.js'        = @('home_search.js', 'text/javascript; charset=utf-8')
    '/home_search_parse.js'  = @('home_search_parse.js', 'text/javascript; charset=utf-8')
    '/home_search_groups.js' = @('home_search_groups.js', 'text/javascript; charset=utf-8')
}
# A record's file name (CPlusHomeRecord writes home<house>_[<clock>]_<box id>_<serial>.txt). Other
# files written to the same folder do not match. \z, not $: $ also matches before a newline at the end.
$RecordName = '^home\d+_[^\\/]+\.txt\z'
$NamesFile = 'home_names.json'
$EmptyNames = '{"version":1,"houses":{},"floors":{},"boxes":{}}'
# A names file is a few hundred bytes per named box; 1 MB is thousands of boxes. A delete request is held
# to the same size ( a name is about 40 bytes, so 1 MB is far more names than $MaxDeleteNames allows ).
$MaxNamesBytes = 1MB
# How many records one delete request may name. The whole folder is about a thousand records, so this is
# enough to tidy in one or two goes and is still a number rather than "as many as you like".
$MaxDeleteNames = 500
# How often the idle time is looked at while no request comes.
$WaitStepMs = 1000
# How long a request's body may keep this waiting for its next bytes (http.sys's own default is 120 s).
# Requests are answered one at a time, so a POST that names a length and sends nothing held every other
# request for two minutes. The bodies are small - a delete is 500 names at most (about 20 KB), the names
# a few hundred bytes a box - and come from the page on this PC, so the next bytes come at once; 5 s is
# far beyond that. http.sys looks at this timer only every 5 s or so, so such a POST holds the reader
# longer than this: with 5 s set, 8.5 to 13.6 s in 14 tries (measured).
$BodyWaitSeconds = 5
# How long a request's whole body may take. The wait above starts again with every byte, so a POST that
# sends one byte a second held the reader for as long as it kept sending. The largest body taken is 1 MB
# ( $MaxNamesBytes ), sent at once by the page on this PC: it takes milliseconds, and 10 s leaves room
# for a PC busy with the game.
$BodyTotalSeconds = 10
# Where the game puts itself under Program Files, and its records folder inside it.
$GameUnderPrograms = 'Electronic Arts\Ultima Online Enhanced'
$RecordsFolderName = 'CPlusExport'
$RecordsUnderGame = 'logs\' + $RecordsFolderName
# The records folder the page remembers, beside the names: the viewer's own folder may be replaced
# when a new version is put in its place.
$SettingsFile = 'home_settings.json'
# The longest folder taken from the page or the settings, in characters: Windows' MAX_PATH. The game's
# records folder is about 70 ( C:\Program Files (x86)\Electronic Arts\Ultima Online Enhanced\logs\CPlusExport ),
# and the .NET of Windows PowerShell 5.1 refuses longer paths unless long paths are turned on for the PC.
$MaxFolderChars = 260

# Every folder in its full form with \ between the names, however it was given ( C:/Users/…, a relative
# path ): the paths built from these and shown on the screen are then all in that form, which is the form
# Hide-UserFolder finds the user's own folders in. A short 8.3 name ( C:\Users\NAME~1 ) stays as it was
# given: the .bat passes no folder, and the defaults are all long names.
# A folder that cannot be made whole ( a name Windows does not allow ) is kept as the reason the start failed:
# it is shown, and the reader ends with 1, once Show-Failure is defined below.
# %LOCALAPPDATA% not set at all is such a failure too ( Join-Path refuses an empty path ).
$StartFailure = ''
try {
    if (-not $NamesDir) { $NamesDir = Join-Path $env:LOCALAPPDATA 'CPlusHomeSearch' }
    if ($RecordsDir) { $RecordsDir = [IO.Path]::GetFullPath($RecordsDir) }
    $NamesDir = [IO.Path]::GetFullPath($NamesDir)
    if ($UserDataDir) { $UserDataDir = [IO.Path]::GetFullPath($UserDataDir) }
    $NamesPath = Join-Path $NamesDir $NamesFile
    $SettingsPath = Join-Path $NamesDir $SettingsFile
} catch [ArgumentException], [NotSupportedException], [IO.PathTooLongException], [Security.SecurityException],
    [Management.Automation.ParameterBindingException] {
    $StartFailure = '起動のときのフォルダの場所を決められません: ' + $_.Exception.Message
}


# The status to refuse a request with, or 0 to go on.
function Get-RefusalStatus {
    param([bool]$IsLocal, [string]$HostHeader, [string]$Method, [string]$Path, [string]$Origin,
        [string]$ContentType, [int]$ListenPort, [string]$FetchSite = '')
    if (-not $IsLocal) { return 403 }
    # Also keeps out a page on another site that has pointed its own name at this PC.
    if ($HostHeader -ne "localhost:$ListenPort") { return 403 }
    # A browser says where a request comes from ( Sec-Fetch-Site ): one from another site ( cross-site,
    # same-site ) is refused before anything is looked at, so that no other page can learn that the reader
    # is there, nor keep it running. The page's own requests are same-origin; one typed into the address bar
    # is none; a program that is not a browser sends none at all, and is held to the rules below.
    if ($FetchSite -and $FetchSite -ne 'same-origin' -and $FetchSite -ne 'none') { return 403 }
    if ($Method -eq 'GET') { return 0 }
    if ($Method -ne 'POST' -or ($Path -ne '/api/names' -and $Path -ne '/api/delete' -and $Path -ne '/api/recordsdir')) { return 405 }
    if ($Origin -and $Origin -ne "http://localhost:$ListenPort") { return 403 }
    if (-not $ContentType -or ($ContentType -split ';')[0].Trim() -ne 'application/json') { return 415 }
    return 0
}

# The records directly in the folder (none when the folder is not there).
function Get-RecordFiles {
    param([string]$Dir)
    if (-not [IO.Directory]::Exists($Dir)) { return @() }
    return @((New-Object IO.DirectoryInfo $Dir).GetFiles() | Where-Object { $_.Name -match $RecordName })
}

# The full path of the record asked for, or the status to refuse it with: 400 for a name that is not a
# record's, 404 for one that is not directly in the folder. The name is looked up in the folder's own
# list, so nothing like .. or a stream name can reach outside it.
function Resolve-Record {
    param([string]$Name, [string]$Dir)
    if (-not $Name -or $Name -notmatch $RecordName) { return 400 }
    foreach ($file in @(Get-RecordFiles $Dir)) {
        # Ordinal: the page asks only for names this listing gave it, so the name must be the same to the letter.
        # -eq compares as text is read, and would take a name with a soft hyphen in it for another.
        if ([string]::Equals($file.Name, $Name, [StringComparison]::Ordinal)) { return $file.FullName }
    }
    return 404
}

# One value of a query string (as the browser sent it, decoded as UTF-8), or $null.
function Get-QueryValue {
    param([string]$RawUrl, [string]$Key)
    $at = $RawUrl.IndexOf('?')
    if ($at -lt 0) { return $null }
    foreach ($pair in $RawUrl.Substring($at + 1).Split('&')) {
        $kv = $pair.Split('=', 2)
        if ($kv.Count -eq 2 -and [Uri]::UnescapeDataString($kv[0]) -ceq $Key) {
            return [Uri]::UnescapeDataString($kv[1].Replace('+', ' '))
        }
    }
    return $null
}

# The names as they are kept, or $null when the JSON is not an object whose houses, floors and boxes are
# objects of text.
function ConvertTo-NamesJson {
    param([string]$Json)
    # ArgumentException: not JSON. InvalidOperationException: two keys that differ only in case.
    try {
        $data = ConvertFrom-Json -InputObject $Json
    } catch [ArgumentException], [InvalidOperationException] {
        return $null
    }
    if ($data -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $out = [ordered]@{ version = 1 }
    foreach ($kind in 'houses', 'floors', 'boxes') {
        $part = $data.PSObject.Properties[$kind]
        if ($null -eq $part -or $part.Value -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        $map = [ordered]@{}
        foreach ($p in $part.Value.PSObject.Properties) {
            if ($p.Value -isnot [string]) { return $null }
            $map[$p.Name] = $p.Value
        }
        $out[$kind] = $map
    }
    # chars and view: which character a record's number belongs to, and which account and shard
    # the page is looking at. The same shape as the names - a map of text to text - so it is checked
    # just as strictly; an account, a shard and a character are joined by a newline, which no folder name
    # can hold. **Taken only when they are there**: a names file written before they existed still saves,
    # and comes back exactly as it was sent. areas, the page's table of the houses of each account
    # and shard ("<account>\n<shard>\n<n>" -> "<facet> <minX> <maxX> <minY> <maxY>"), is kept the same way.
    foreach ($kind in 'chars', 'view', 'areas') {
        $part = $data.PSObject.Properties[$kind]
        if ($null -eq $part) { continue }
        if ($part.Value -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        $map = [ordered]@{}
        foreach ($p in $part.Value.PSObject.Properties) {
            if ($p.Value -isnot [string]) { return $null }
            $map[$p.Name] = $p.Value
        }
        $out[$kind] = $map
    }
    return (ConvertTo-Json -InputObject $out -Depth 3 -Compress)
}

# Written to a file beside it first and then put in its place, so the names ( and the settings ) are never
# half written. The folder is made when it is not there yet.
function Save-File {
    param([string]$Path, [string]$Json)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $temp = $Path + '.tmp'
    [IO.File]::WriteAllText($temp, $Json, (New-Object Text.UTF8Encoding $false))
    if ([IO.File]::Exists($Path)) {
        # No backup. [NullString]: PowerShell passes a plain $null to a string parameter as "", which
        # Replace refuses.
        [IO.File]::Replace($temp, $Path, [NullString]::Value)
    } else {
        [IO.File]::Move($temp, $Path)
    }
}

# ---- the records folder ( the top of this file says in which order it is decided )

# '' when a folder is written the way one is taken from the page or the settings - a drive letter and the
# whole path ( C:\… ), no longer than $MaxFolderChars - or what is wrong with it. A network place
# ( \\server\… ) is not taken: the records are the game's, on this PC.
function Test-FolderForm {
    param([string]$Path)
    if ($Path.Length -gt $MaxFolderChars) { return ('フォルダの場所が長すぎます（' + $MaxFolderChars + ' 文字まで）') }
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) { return 'ネットワークの場所（\\…）は使えません。このパソコンのフォルダの場所を貼ってください' }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { return 'ドライブ文字から始まるフォルダの場所（C:\… の形）を貼ってください' }
    return ''
}

# Whether a folder is named CPlusExport ( in any case ), the one name a records folder may have, whether it
# comes from the page or the settings. Only the name is looked at: where a junction of that name leads is not.
# A \ at the end does not count.
function Test-RecordsFolderName {
    param([string]$Path)
    # Ordinal: -ieq compares as text is read, and would take a name with a soft hyphen in it for the same name.
    return [string]::Equals([IO.Path]::GetFileName($Path.TrimEnd('\', '/')), $RecordsFolderName, [StringComparison]::OrdinalIgnoreCase)
}

<#
  The records folder kept in home_settings.json: @{ dir; error }. No file is dir '' and error '' ( nothing
  told yet ). A file that cannot be read, or is not { "version": 1, "recordsDir": "C:\…\CPlusExport" }, is
  dir '' and error with the reason: the page says so, rather than looking as if nothing had been told.
  A folder not named CPlusExport is of the wrong shape too ( the file may have been written by hand ). The
  folder in it is not looked for here: one that has gone since is answered as a records folder that is
  not there.
#>
function Read-Settings {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return @{ dir = ''; error = '' } }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    } catch [UnauthorizedAccessException], [IO.IOException] {
        return @{ dir = ''; error = ($Path + ' を読めません: ' + $_.Exception.Message) }
    }
    $wrong = @{ dir = ''; error = ($Path + ' の中身が、記録のフォルダの設定の形ではありません') }
    # ArgumentException: not JSON. InvalidOperationException: two keys that differ only in case.
    try {
        $data = ConvertFrom-Json -InputObject $text
    } catch [ArgumentException], [InvalidOperationException] {
        return $wrong
    }
    if ($data -isnot [System.Management.Automation.PSCustomObject]) { return $wrong }
    $dir = $data.PSObject.Properties['recordsDir']
    if ($null -eq $dir -or $dir.Value -isnot [string] -or (Test-FolderForm $dir.Value) -ne '') { return $wrong }
    try {
        $full = [IO.Path]::GetFullPath($dir.Value)
    } catch [ArgumentException], [NotSupportedException], [IO.PathTooLongException] {
        return $wrong
    }
    if (-not (Test-RecordsFolderName $full)) { return $wrong }
    return @{ dir = $full.TrimEnd('\'); error = '' }
}

<#
  The records folder at the game's usual place, or '' when the game is under neither Program Files.
  A records folder that is there comes first; then a game folder without one, whose logs\CPlusExport is
  answered so that the page can say where to make it. %ProgramFiles(x86)% before %ProgramFiles%: the game
  is a 32-bit program, which Windows puts there.
#>
function Find-StandardRecords {
    $games = New-Object System.Collections.Generic.List[string]
    foreach ($top in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not [string]::IsNullOrEmpty($top)) { $games.Add((Join-Path $top $GameUnderPrograms)) }
    }
    foreach ($game in $games) {
        $dir = Join-Path $game $RecordsUnderGame
        if ([IO.Directory]::Exists($dir)) { return $dir }
    }
    foreach ($game in $games) {
        if ([IO.Directory]::Exists($game)) { return (Join-Path $game $RecordsUnderGame) }
    }
    return ''
}

# Which records folder is read, and how that was decided: @{ dir; from; settingsError }. from is given,
# saved, standard or none, and dir is '' with none. With -RecordsDir the settings are not read at all.
function Resolve-RecordsDir {
    param([string]$Given, [string]$SettingsAt)
    if ($Given) { return @{ dir = $Given; from = 'given'; settingsError = '' } }
    $saved = Read-Settings $SettingsAt
    if ($saved.dir) { return @{ dir = $saved.dir; from = 'saved'; settingsError = '' } }
    $standard = Find-StandardRecords
    if ($standard) { return @{ dir = $standard; from = 'standard'; settingsError = $saved.error } }
    return @{ dir = ''; from = 'none'; settingsError = $saved.error }
}

<#
  The records folder a path from the page stands for, or why it is refused: @{ dir } or @{ detail }.

  A folder named CPlusExport ( in any case ) is itself; any other folder stands for its logs\CPlusExport, so the
  game's folder can be given as it is. Taken only when that folder is there: records are deleted from the
  records folder, so the page cannot point it at a folder that is not one. Spaces round the path, and quotes
  round the whole of it ( Explorer's "copy as path" adds them ), are taken off first.
#>
function Find-RecordsCandidate {
    param($Path)
    if ($Path -isnot [string]) { return @{ detail = 'フォルダの場所が文字ではありません' } }
    $text = $Path.Trim()
    if ($text.Length -ge 2 -and $text.StartsWith('"') -and $text.EndsWith('"')) { $text = $text.Substring(1, $text.Length - 2).Trim() }
    if ($text -eq '') { return @{ detail = 'フォルダの場所が空です' } }
    $wrong = Test-FolderForm $text
    if ($wrong) { return @{ detail = $wrong } }
    try {
        $full = [IO.Path]::GetFullPath($text).TrimEnd('\')
    } catch [ArgumentException], [NotSupportedException], [IO.PathTooLongException] {
        return @{ detail = ('フォルダの場所として読めません: ' + $_.Exception.Message) }
    }
    if (Test-RecordsFolderName $full) { $dir = $full } else { $dir = Join-Path $full $RecordsUnderGame }
    if (-not [IO.Directory]::Exists($dir)) {
        return @{ detail = ('記録のフォルダ（' + $RecordsFolderName + '）が見つかりません。探した場所: ' + $dir +
            '。ゲームのフォルダか、その中の ' + $RecordsUnderGame + ' の場所を貼ってください') }
    }
    return @{ dir = $dir }
}

# The list of records, with where they were looked for, how that place was decided, why the settings could
# not be read ( '' when they could ), and where the names are kept: the page shows all of these.
function Get-FileList {
    param($Records, [string]$NamesAt)
    $dir = $Records.dir
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-RecordFiles $dir)) {
        $files.Add([ordered]@{
            name  = $f.Name
            size  = $f.Length
            mtime = ([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        })
    }
    return [ordered]@{ recordsDir = $dir; found = ($dir -ne '' -and [IO.Directory]::Exists($dir)); recordsFrom = $Records.from
        settingsError = $Records.settingsError; namesFile = $NamesAt; files = $files }
}

# Up to $MaxNamesBytes of the request body as UTF-8, or the status to refuse it with: 413 when it is
# longer, 408 when it has not all come within $BodyTotalSeconds. Each read is waited for only as long as
# is left of that; a read still waiting then is left to fail when the connection is closed.
function Read-Body {
    param($Request)
    if ($Request.ContentLength64 -gt $MaxNamesBytes) { return 413 }
    $buffer = New-Object byte[] ($MaxNamesBytes + 1)
    $total = 0
    $deadline = [DateTime]::UtcNow.AddSeconds($BodyTotalSeconds)
    while ($total -lt $buffer.Length) {
        $left = $deadline - [DateTime]::UtcNow
        if ($left -le [TimeSpan]::Zero) { return 408 }
        $reading = $Request.InputStream.ReadAsync($buffer, $total, $buffer.Length - $total)
        if (-not $reading.Wait($left)) { return 408 }
        $n = $reading.Result
        if ($n -le 0) { break }
        $total += $n
    }
    if ($total -gt $MaxNamesBytes) { return 413 }
    return [Text.Encoding]::UTF8.GetString($buffer, 0, $total)
}

# ---- the characters on this PC (the folders under User Data, read only)

<#
  Where the game keeps what belongs to one character:

      Documents\EA Games\<the game's name>\User Data\<account>\<shard>\<character>

  The game's folder is named in the language it was installed in, so no name is spelled out here: every
  folder under 「EA Games」 that holds a 「User Data」 is a candidate. Documents itself is asked of Windows
  (GetFolderPath), since it can be moved or redirected, with %USERPROFILE%\Documents as the fallback.

  -UserDataDir passes all of that by and uses the folder it is given.

  $DocumentsDir is the same door one step earlier: given, the search runs under that folder instead of
  the real Documents. Windows answers GetFolderPath from the registry, so no environment variable can
  point the search elsewhere - and the search is where several installs on one PC meet each other.
#>
function Get-UserDataCandidates {
    param([string]$Given, [string]$DocumentsDir = '')
    # Every way out hands back one array, whole: "return ," keeps PowerShell from unrolling it into its
    # entries ( nothing at all when there are none, the entry itself when there is one ).
    if ($Given -ne '') { return ,@($Given) }
    $docs = $DocumentsDir
    if ($docs -eq '') { $docs = [Environment]::GetFolderPath('MyDocuments') }
    if ([string]::IsNullOrEmpty($docs)) { $docs = Join-Path $env:USERPROFILE 'Documents' }
    $ea = Join-Path $docs 'EA Games'
    $found = New-Object System.Collections.Generic.List[string]
    if (-not [IO.Directory]::Exists($ea)) { return @() }
    foreach ($game in @([IO.Directory]::GetDirectories($ea))) {
        $candidate = Join-Path $game 'User Data'
        if ([IO.Directory]::Exists($candidate)) { $found.Add($candidate) }
    }
    return ,$found.ToArray()
}

<#
  Whether a folder directly under User Data is an account's.

  By its shape, not by its name: an account holds a folder for each shard, and a shard's folder holds a
  file for each character. A module's folder is also directly under User Data and holds a file
  (ModSettings.xml) and no folder at all, so "holds a folder that has a file in it" leaves the modules
  out without this having to know any module's name.
#>
function Test-AccountDir {
    param([string]$Dir)
    foreach ($shard in @([IO.Directory]::GetDirectories($Dir))) {
        if (@([IO.Directory]::GetFiles($shard)).Count -gt 0) { return $true }
    }
    return $false
}

<#
  Whether a name looks like a spare rather than a character: one with an extension (Alice.bak) or one of
  the suffixes Windows gives a copy (「Alice - コピー」, "Alice - Copy", with or without a number).

  It is a mark, not a judgement: the spares are answered along with the rest, with this beside them, so
  that the page can hide them and nothing here has to decide what is rubbish. Nothing is ever removed.
#>
function Test-SpareName {
    param([string]$Name)
    if ($Name -match '\.[A-Za-z0-9]{1,8}$') { return $true }
    return ($Name -match '\s-\s(?:コピー|Copy)(\s*\(\d+\))?$')
}

# The accounts under one User Data folder, each with its shards and their characters. A folder that
# cannot be read is answered with readable = false and the reason, never as an empty one.
function Get-Accounts {
    param([string]$Dir)
    $accounts = New-Object System.Collections.Generic.List[object]
    foreach ($accDir in @([IO.Directory]::GetDirectories($Dir))) {
        $accName = [IO.Path]::GetFileName($accDir)
        $shards = New-Object System.Collections.Generic.List[object]
        $readable = $true
        $why = ''
        try {
            if (-not (Test-AccountDir $accDir)) { continue }
            foreach ($shardDir in @([IO.Directory]::GetDirectories($accDir))) {
                $chars = New-Object System.Collections.Generic.List[object]
                foreach ($file in @([IO.Directory]::GetFiles($shardDir))) {
                    $info = New-Object IO.FileInfo $file
                    $chars.Add([ordered]@{
                        name  = $info.Name
                        spare = [bool](Test-SpareName $info.Name)
                        size  = $info.Length
                        mtime = ([DateTimeOffset]$info.LastWriteTimeUtc).ToUnixTimeMilliseconds()
                    })
                }
                $shardName = [IO.Path]::GetFileName($shardDir)
                $shards.Add([ordered]@{
                    name       = $shardName
                    spare      = [bool](Test-SpareName $shardName)
                    characters = $chars
                })
            }
        } catch [UnauthorizedAccessException], [IO.IOException] {
            $readable = $false
            $why = $_.Exception.Message
        }
        $accounts.Add([ordered]@{
            name     = $accName
            spare    = [bool](Test-SpareName $accName)
            readable = $readable
            detail   = $why
            shards   = $shards
        })
    }
    return ,$accounts
}

<#
  The answer for /api/chars: which User Data folder was read, what else was in the running, and the
  accounts in it.

  More than one candidate (two installs, or one in another language) is not guessed at quietly: the one
  with the most accounts is read, ties going to the one written most recently, and every candidate is
  answered as well so that the page can say which was taken. None at all is found = false with the
  places looked in, not an empty list that reads like "no accounts".
#>
function Get-CharTree {
    param([string]$Given, [string]$DocumentsDir = '')
    # The call is kept whole in a variable and the @( ) goes round the variable. Round the call it would
    # collect what the call emitted - one array, because of the "return ," - and make that array a single
    # entry, which then walks into GetDirectories as one path of three names joined by spaces.
    $found = Get-UserDataCandidates $Given $DocumentsDir
    $candidates = @($found)
    # A place that is not there is not read. -UserDataDir may name one that does not exist ( a folder
    # moved, a path mistyped ), and reading it would throw out of the whole request: the page would get a
    # 500 and show no characters at all, with nothing to say what was wrong. Answering found = false
    # with the places looked in says it in the shape the page already knows.
    $there = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        if ([IO.Directory]::Exists($candidate)) { $there.Add($candidate) }
    }
    if ($there.Count -eq 0) {
        $why = 'Documents\EA Games の下に User Data のフォルダが見つかりません'
        if ($candidates.Count -ne 0) { $why = 'User Data のフォルダがありません: ' + ($candidates -join ' / ') }
        return [ordered]@{ userDataDir = ''; found = $false; candidates = @($candidates); accounts = @()
            detail = $why }
    }
    $candidates = @($there.ToArray())
    $best = $null
    # A list from the start, so that .Count is the number of accounts at every step. ( Unrolled, a list of
    # one would be the account itself, whose .Count is its five keys, and would win against a candidate
    # that really has two accounts. )
    $bestAccounts = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidates) {
        $accounts = Get-Accounts $candidate
        $when = [DateTime]::MinValue
        try { $when = [IO.Directory]::GetLastWriteTimeUtc($candidate) } catch [IO.IOException] { }
        if ($null -eq $best -or $accounts.Count -gt $bestAccounts.Count -or
            ($accounts.Count -eq $bestAccounts.Count -and $when -gt $best.When)) {
            $best = [ordered]@{ Dir = $candidate; When = $when }
            $bestAccounts = $accounts
        }
    }
    return [ordered]@{
        userDataDir = $best.Dir
        found       = $true
        candidates  = @($candidates)
        accounts    = $bestAccounts
    }
}

<#
  The records named in a delete request, and why each of the others was refused.

  Everything about a name is checked here, and nothing about it is trusted: it must look like a record's
  name ( $RecordName ), hold no path separator and no "..", and name a file that is really directly in
  the records folder ( Resolve-Record walks the folder's own listing rather than joining strings ). A name
  that fails any of those is answered with its reason and nothing is done about it.

  Deleted with -LiteralPath: a record's name holds [ and ], which Remove-Item would otherwise read as a
  set of characters to match - the file would stay and the answer would say it had gone.
#>
function Remove-Records {
    # $Names is taken as it came from the request: typing it as [string[]] would quietly turn a number or
    # a list into text, and what is wanted here is to refuse anything that is not a name.
    param($Names, [string]$Dir)
    $deleted = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($Names)) {
        $why = ''
        if ($name -isnot [string] -or $name -eq '') {
            $why = '名前がありません'
        } elseif ($name.Contains('\') -or $name.Contains('/') -or $name.Contains('..')) {
            $why = 'フォルダの区切りを含む名前は消しません'
        } elseif ($name -notmatch $RecordName) {
            $why = '記録のファイル名の形ではありません'
        }
        if ($why -ne '') {
            $failed.Add([ordered]@{ name = [string]$name; detail = $why })
            continue
        }
        $found = Resolve-Record $name $Dir
        if ($found -is [int]) {
            $failed.Add([ordered]@{ name = $name; detail = ('記録のフォルダに見つかりません (' + $found + ')') })
            continue
        }
        try {
            Remove-Item -LiteralPath $found -Force -ErrorAction Stop
        } catch {
            # Whatever it was ( no permission, the file in use, something unforeseen ), the name is
            # answered with the reason. Catching everything is on purpose here: this is the one place
            # where the failure is the answer, and letting it out would lose the names that did work and
            # turn the whole request into "internal error".
            $failed.Add([ordered]@{ name = $name; detail = ('消せません: ' + $_.Exception.Message) })
            continue
        }
        if ([IO.File]::Exists($found)) {
            # Gone from the answer but still on disk would be the worst of both: said so instead.
            $failed.Add([ordered]@{ name = $name; detail = '消したはずのファイルがまだあります' })
            continue
        }
        $deleted.Add($name)
    }
    return [ordered]@{ deleted = @($deleted.ToArray()); failed = @($failed.ToArray()) }
}

<#
  Every record in one answer: GET /api/bundle, for the page's first load.

  The reader answers one request at a time, so asking for a thousand records one at a time is a thousand turns
  of ask and wait, which makes opening the page slow as the records pile up. This is one turn.

  The shape ( UTF-8, no BOM ):

      CPLUS_HOME_BUNDLE<TAB>1<LF>
      <how many characters><TAB><the record's file name><LF>
      <the record's text>
      <how many characters><TAB><name><LF>
      <text>
      ...

  How many characters is in UTF-16 code units - what .NET's String.Length counts and what JavaScript's
  string length counts, the same number - so the page cuts each record out by counting instead of
  looking for a mark, and a record holding tabs and newlines cannot be read as the start of the next
  one. The name is last on its line, so a name could not break the line either.

  Written as it goes ( chunked, one record held at a time ): the folder runs to megabytes, and building the whole
  answer in memory and then encoding it would hold it twice and make this the new slow part.

  A record that cannot be read at this moment - the game writing it, most likely - is left out rather
  than failing the answer: the page asks for whatever it did not get one at a time.
#>
function Send-Bundle {
    param($Context, [string]$Dir)
    $response = $Context.Response
    Set-AnswerHead $response 200 'text/plain; charset=utf-8'
    # Chunked: how long the answer is cannot be known without reading every record first.
    $response.SendChunked = $true
    $writer = New-Object IO.StreamWriter($response.OutputStream, (New-Object Text.UTF8Encoding($false)))
    try {
        $writer.Write("CPLUS_HOME_BUNDLE`t1`n")
        foreach ($file in @(Get-RecordFiles $Dir)) {
            $text = ''
            try {
                $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::Unicode)
            } catch [IO.IOException] {
                continue
            } catch [UnauthorizedAccessException] {
                continue
            }
            $writer.Write([string]$text.Length)
            $writer.Write("`t")
            $writer.Write($file.Name)
            $writer.Write("`n")
            $writer.Write($text)
        }
        $writer.Flush()
    } finally {
        $writer.Dispose()
    }
}

<#
  Text for the screen with the user's own folders written %LOCALAPPDATA%\… and %USERPROFILE%\…, so that
  the Windows user name is not on the screen (a screenshot of the page shown to someone else). The page
  only shows these paths; it never uses one to ask for anything. A folder elsewhere ( Program Files ) is
  left as it is.

  Replaced wherever it stands in the text, so a path inside a failure's own message goes too. Only a whole
  folder name: C:\Users\name2 is not C:\Users\name. %LOCALAPPDATA% first, since it lies inside
  %USERPROFILE%. -InJson: the text is JSON, where each \ is written \\.
#>
function Hide-UserFolder {
    param([string]$Text, [switch]$InJson)
    foreach ($name in 'LOCALAPPDATA', 'USERPROFILE') {
        $root = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrEmpty($root)) { continue }
        $root = $root.TrimEnd('\')
        if ($InJson) { $root = (ConvertTo-Json -InputObject $root -Compress).Trim('"') }
        $Text = [regex]::Replace($Text, [regex]::Escape($root) + '(?![\w.-])', "%$name%",
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $Text
}

# What every answer says about itself: never kept by the browser, never guessed at by type, never shown
# inside another page's frame, and what it is. One place for all of them - an answer written another way
# ( the bundle streams, so it cannot say how long it is ) would otherwise lose them quietly.
# The frame: a page on another site could otherwise hold this page in an invisible frame and have the
# viewer press 整理削除 and 消す through it. frame-ancestors is the only rule the policy sets, so the page's
# own scripts, styles and pictures are not held to anything new.
function Set-AnswerHead {
    param($Response, [int]$Status, [string]$ContentType)
    $Response.StatusCode = $Status
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['X-Frame-Options'] = 'DENY'
    $Response.Headers['Content-Security-Policy'] = "frame-ancestors 'none'"
    # Not to be read by a page of another site, even as a picture or a script ( which no CORS rule stops ).
    $Response.Headers['Cross-Origin-Resource-Policy'] = 'same-origin'
    $Response.ContentType = $ContentType
}

# A HEAD request is answered with the head alone: its answer may not carry a body, and writing one throws.
function Send-Bytes {
    param($Context, [int]$Status, [string]$ContentType, [byte[]]$Body)
    $response = $Context.Response
    Set-AnswerHead $response $Status $ContentType
    if ($Context.Request.HttpMethod -ne 'HEAD') {
        $response.ContentLength64 = $Body.Length
        $response.OutputStream.Write($Body, 0, $Body.Length)
    }
    $response.Close()
}

function Send-Text {
    param($Context, [int]$Status, [string]$ContentType, [string]$Text)
    Send-Bytes $Context $Status $ContentType ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Send-Json {
    # Depth: how far ConvertTo-Json goes before it writes a type name instead of the thing. The tree of
    # accounts is four levels below the root, so it says so rather than losing its characters.
    # Every JSON answer - the list, the characters, every refusal's reason - carries its folders the way
    # Hide-UserFolder writes them.
    param($Context, [int]$Status, $Value, [int]$Depth = 5)
    $json = ConvertTo-Json -InputObject $Value -Depth $Depth -Compress
    Send-Text $Context $Status 'application/json; charset=utf-8' (Hide-UserFolder $json -InJson)
}

function Send-Refusal {
    param($Context, [int]$Status, [string]$Detail)
    Send-Json $Context $Status ([ordered]@{ detail = $Detail })
}

function Invoke-Request {
    param($Context)
    $request = $Context.Request
    $path = $request.Url.AbsolutePath
    $refusal = Get-RefusalStatus -IsLocal $request.IsLocal -HostHeader $request.Headers['Host'] `
        -Method $request.HttpMethod -Path $path -Origin $request.Headers['Origin'] `
        -ContentType $request.ContentType -ListenPort $Port -FetchSite $request.Headers['Sec-Fetch-Site']
    if ($refusal -eq 405) {
        if ($path -eq '/api/names') { $Context.Response.Headers['Allow'] = 'GET, POST' }
        elseif ($path -eq '/api/delete' -or $path -eq '/api/recordsdir') { $Context.Response.Headers['Allow'] = 'POST' }
        else { $Context.Response.Headers['Allow'] = 'GET' }
    }
    if ($refusal -ne 0) { Send-Refusal $Context $refusal 'refused'; return }
    # Only a request that is not refused keeps the reader running: another site asking again and again
    # does not.
    $script:lastRequest = [DateTime]::UtcNow

    if ($PageFiles.ContainsKey($path)) {
        $page = $PageFiles[$path]
        $file = Join-Path $PSScriptRoot $page[0]
        if (-not [IO.File]::Exists($file)) { Send-Refusal $Context 404 'page file missing'; return }
        Send-Bytes $Context 200 $page[1] ([IO.File]::ReadAllBytes($file))
    } elseif ($path -eq '/api/ping') {
        Send-Json $Context 200 ([ordered]@{ app = $AppName; version = $ApiVersion })
    } elseif ($path -eq '/api/files') {
        Send-Json $Context 200 (Get-FileList $script:Records $NamesPath)
    } elseif ($path -eq '/api/bundle') {
        Send-Bundle $Context $script:Records.dir
    } elseif ($path -eq '/api/file') {
        $found = Resolve-Record (Get-QueryValue $request.RawUrl 'name') $script:Records.dir
        if ($found -is [int]) { Send-Refusal $Context $found 'no such record'; return }
        try {
            $text = [IO.File]::ReadAllText($found, [Text.Encoding]::Unicode)
        } catch [IO.IOException] {
            # Being written by the game at this moment: the page asks again on its next round.
            Send-Refusal $Context 503 'record busy'; return
        }
        Send-Text $Context 200 'text/plain; charset=utf-8' $text
    } elseif ($path -eq '/api/chars') {
        Send-Json $Context 200 (Get-CharTree $UserDataDir) -Depth 8
    } elseif ($path -eq '/api/names' -and $request.HttpMethod -eq 'GET') {
        $text = $EmptyNames
        try {
            if ([IO.File]::Exists($NamesPath)) { $text = [IO.File]::ReadAllText($NamesPath, [Text.Encoding]::UTF8) }
        } catch [UnauthorizedAccessException], [IO.IOException] {
            Send-Refusal $Context 500 ('名前のファイル ' + $NamesPath + ' を読めません: ' + $_.Exception.Message); return
        }
        Send-Text $Context 200 'application/json; charset=utf-8' $text
    } elseif ($path -eq '/api/delete') {
        # GET is allowed through the refusal rules for every path; this one has nothing to answer to it.
        if ($request.HttpMethod -ne 'POST') {
            $Context.Response.Headers['Allow'] = 'POST'
            Send-Refusal $Context 405 'refused'
            return
        }
        $body = Read-Body $request
        if ($body -is [int]) {
            if ($body -eq 408) { Send-Refusal $Context 408 'body too slow' } else { Send-Refusal $Context 413 'too large' }
            return
        }
        try {
            $asked = ConvertFrom-Json -InputObject $body
        } catch [ArgumentException], [InvalidOperationException] {
            Send-Refusal $Context 400 'not a list of names'; return
        }
        if ($null -eq $asked -or $null -eq $asked.PSObject.Properties['names']) { Send-Refusal $Context 400 'not a list of names'; return }
        $names = @($asked.names)
        if ($names.Count -eq 0) { Send-Refusal $Context 400 'no names'; return }
        if ($names.Count -gt $MaxDeleteNames) { Send-Refusal $Context 413 ('一度に消せるのは ' + $MaxDeleteNames + ' 本までです'); return }
        Send-Json $Context 200 (Remove-Records $names $script:Records.dir) -Depth 4
    } elseif ($path -eq '/api/recordsdir') {
        # GET is allowed through the refusal rules for every path; this one has nothing to answer to it.
        if ($request.HttpMethod -ne 'POST') {
            $Context.Response.Headers['Allow'] = 'POST'
            Send-Refusal $Context 405 'refused'
            return
        }
        # Given at the start by whoever started the reader: the page does not move it.
        if ($script:Records.from -eq 'given') { Send-Refusal $Context 409 '起動時に -RecordsDir で指定されているので変えられません'; return }
        $body = Read-Body $request
        if ($body -is [int]) {
            if ($body -eq 408) { Send-Refusal $Context 408 'body too slow' } else { Send-Refusal $Context 413 'too large' }
            return
        }
        try {
            $asked = ConvertFrom-Json -InputObject $body
        } catch [ArgumentException], [InvalidOperationException] {
            Send-Refusal $Context 400 'not a path'; return
        }
        if ($null -eq $asked -or $asked -isnot [System.Management.Automation.PSCustomObject] -or
            $null -eq $asked.PSObject.Properties['path']) { Send-Refusal $Context 400 'not a path'; return }
        $chosen = Find-RecordsCandidate $asked.path
        if ($chosen.ContainsKey('detail')) { Send-Refusal $Context 400 $chosen.detail; return }
        $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; recordsDir = $chosen.dir }) -Compress
        try {
            Save-File $SettingsPath $json
        } catch [UnauthorizedAccessException], [IO.IOException], [Security.SecurityException] {
            Send-Refusal $Context 500 ('設定のファイル ' + $SettingsPath + ' に書けません: ' + $_.Exception.Message); return
        }
        $script:Records = @{ dir = $chosen.dir; from = 'saved'; settingsError = '' }
        Send-Json $Context 200 ([ordered]@{ ok = $true; recordsDir = $chosen.dir })
    } elseif ($path -eq '/api/names') {
        $body = Read-Body $request
        if ($body -is [int]) {
            if ($body -eq 408) { Send-Refusal $Context 408 'body too slow' } else { Send-Refusal $Context 413 'names too large' }
            return
        }
        $json = ConvertTo-NamesJson $body
        if ($null -eq $json) { Send-Refusal $Context 400 'not names'; return }
        try {
            Save-File $NamesPath $json
        } catch [UnauthorizedAccessException], [IO.IOException], [Security.SecurityException] {
            # Which file and why, for the page to show: trying again later would not mend this by itself.
            Send-Refusal $Context 500 ('名前のファイル ' + $NamesPath + ' に書けません: ' + $_.Exception.Message); return
        }
        Send-Json $Context 200 ([ordered]@{ ok = $true })
    } else {
        Send-Refusal $Context 404 'not found'
    }
}

# Whether this reader already answers on the port.
function Test-Running {
    param([int]$ListenPort)
    try {
        $req = [Net.HttpWebRequest]::Create("http://localhost:$ListenPort/api/ping")
        $req.Timeout = 2000
        $res = $req.GetResponse()
        try {
            $body = (New-Object IO.StreamReader $res.GetResponseStream()).ReadToEnd()
        } finally {
            $res.Close()
        }
        return ((ConvertFrom-Json -InputObject $body).app -eq $AppName)
    } catch {
        # Nothing there, or something that is not this reader. Either way the listening below is tried,
        # and it says out loud when the port is taken.
        return $false
    }
}

function Show-Failure {
    param([string]$Message)
    $Message = Hide-UserFolder $Message
    if ($NoBrowser) { [Console]::Error.WriteLine($Message); return }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Message, '家の記録検索', 'OK', 'Error')
}

function Open-Page {
    if ($NoBrowser) { return }
    try {
        Start-Process "http://localhost:$Port/"
    } catch {
        Show-Failure ("ブラウザを開けませんでした。ブラウザで http://localhost:$Port/ を開いてください。`n" + $_.Exception.Message)
    }
}


# Dot-sourced ( to use the functions above without starting the reader ): stop here.
if ($MyInvocation.InvocationName -eq '.') { return }

# A failure on the way to listening is shown and ends the reader with 1, never left to close the minimized
# window without a word.
if ($StartFailure) { Show-Failure ("家の記録検索を始められませんでした。`n`n" + $StartFailure); exit 1 }
try {
    if (Test-Running $Port) { Open-Page; exit 0 }

    # Decided once here, and again only when the page tells another ( /api/recordsdir ).
    $script:Records = Resolve-RecordsDir $RecordsDir $SettingsPath

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    try {
        $listener.Start()
    } catch {
        Show-Failure ("家の記録検索を始められませんでした。`nhttp://localhost:$Port/ で待ち受けられません。ほかのプログラムがこの番号を使っているかもしれません。`n`n" + $_.Exception.Message)
        exit 1
    }
    # Not a reason to stop: without it a body that never comes is still cut off by $BodyTotalSeconds in
    # Read-Body. Said in the window, with the reason.
    try {
        $listener.TimeoutManager.EntityBody = [TimeSpan]::FromSeconds($BodyWaitSeconds)
    } catch [Net.HttpListenerException], [PlatformNotSupportedException], [ArgumentOutOfRangeException] {
        Write-Warning (Hide-UserFolder ('本文の待ち時間を設定できませんでした（本文全体の締め切り ' + $BodyTotalSeconds + ' 秒は効きます）: ' + $_.Exception.Message))
    }

    # The window this runs in is left on the taskbar ( the .bat starts it minimized ): it says what it is, and
    # closing it is a way to stop it.
    $Host.UI.RawUI.WindowTitle = '家の記録 検索（閉じると検索ページが止まります）'
    Write-Host ('検索ページのための読み出し役です。ページを閉じて ' + $IdleMinutes + ' 分で自動で終わります。')
} catch {
    # Anything at all: this is not where a failure is handled, only where it is shown before the reader ends.
    Show-Failure ("家の記録検索を始められませんでした。`n`n" + $_.Exception.Message)
    exit 1
}

Open-Page
$idleLimit = [TimeSpan]::FromMinutes($IdleMinutes)
$lastRequest = [DateTime]::UtcNow
try {
    $pending = $listener.GetContextAsync()
    while ($true) {
        # Looked at on every turn, a request come or not: requests that are refused, coming more often than
        # $WaitStepMs, would otherwise keep this from ever being looked at.
        if (([DateTime]::UtcNow - $lastRequest) -gt $idleLimit) { break }
        if (-not $pending.Wait($WaitStepMs)) { continue }
        $context = $pending.Result
        $pending = $listener.GetContextAsync()
        $turnStart = [DateTime]::UtcNow
        try {
            Invoke-Request $context
        } catch {
            # Said in the reader's own window. Only the request's path: record contents are never written out.
            Write-Warning (Hide-UserFolder ("request failed: " + $context.Request.Url.AbsolutePath + ": " + $_.Exception.Message))
            try {
                Send-Refusal $context 500 'internal error'
            } catch {
                # Not even the refusal could be written ( the answer was already half sent, or the other end
                # has gone ): the connection is dropped rather than left open until the other end gives up.
                Write-Warning (Hide-UserFolder ("could not answer: " + $_.Exception.Message))
                $context.Response.Abort()
            }
        }
        # A request that was not refused ( Invoke-Request moved $lastRequest ) counts from when it was answered: one that
        # held the reader a while ( a body slow to come ) does not use up the idle time of the requests behind it.
        if ($lastRequest -ge $turnStart) { $lastRequest = [DateTime]::UtcNow }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
