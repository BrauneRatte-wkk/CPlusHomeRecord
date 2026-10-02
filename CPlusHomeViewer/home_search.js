// The search page's behaviour (home_search.html). The page is served by the reader, home_search_server.ps1,
// and gets the records from it: read with home_search_parse.js, kept up to date while the page is shown.
// The dropdowns hold home_search_groups.js.
/* global CPlusHomeParse, SEARCH_GROUPS, MISC_GROUP */
(function () {
  "use strict";

  // Look for new records every 5 seconds while the page is shown, and at once when the viewer comes back.
  const POLL_MS = 5000;
  // Names are saved once typing has paused this long, all of them in one request.
  const SAVE_DELAY_MS = 800;
  // Records asked for side by side. The reader answers one request at a time; a few in flight keep it
  // busy while the page reads what has arrived.
  const FETCH_AT_ONCE = 4;
  const PAGE_SIZE = 100;
  // How long "更新: 記録 +N 本" stays up.
  const NOTICE_MS = 8000;
  // A record read without its END this many times in a row is reported. The first time it is most
  // likely being written; it is asked for again on the next round either way.
  const PARTIAL_REPORT_AFTER = 2;
  // How many unreadable records are named in the warning (the count is always complete).
  const UNREADABLE_NAMED = 3;

  const API_FILES = "/api/files";
  const API_FILE = "/api/file?name=";
  // Every record in one answer, for the first load. The reader takes one request at a time, so
  // asking for a thousand records one by one is a thousand turns of ask and wait, which grows as the
  // records pile up. Everything after the first load still asks one at a time: only what changed is
  // wanted then, which is a handful.
  const API_BUNDLE = "/api/bundle";
  // The first line of a bundle (home_search_server.ps1 Send-Bundle). Anything else is not one.
  const BUNDLE_HEAD = "CPLUS_HOME_BUNDLE\t1";
  const API_NAMES = "/api/names";
  const API_CHARS = "/api/chars";
  const API_DELETE = "/api/delete";
  // Telling the reader where the records folder is ( { path } ). It takes only a CPlusExport folder, or a folder
  // holding logs\CPlusExport, and says why it refuses anything else.
  const API_RECORDSDIR = "/api/recordsdir";
  // A record written in the last minute is never tidied away: the game writes one as the player
  // closes a box, and one that is still being written is not yet what it will be.
  const WRITING_MS = 60 * 1000;
  // How many records one request may name. The reader refuses more than this ( home_search_server.ps1
  // $MaxDeleteNames ), so a press deletes the oldest this many and the next press the next ( tidySplit ).
  const DELETE_AT_ONCE = 500;
  const READER_LOST = "読み出し役に届きません。『家の記録検索.bat』から開き直してください";

  const $ = id => document.getElementById(id);
  const collator = new Intl.Collator("ja");
  const el = (tag, className, text) => {
    const e = document.createElement(tag);
    if (className) e.className = className;
    if (text !== undefined) e.textContent = text;
    return e;
  };

  // ---- what has been read: name -> { size, mtime, parsed, misses }
  const files = new Map();
  // Records the reader did not hand over (an answer other than 200) on their latest tries: name -> { times, status }.
  const refusals = new Map();
  let loadedOnce = false;
  let boxes = [], items = [], floors = new Map(), boxById = new Map();
  let entries = new Map(), groups = [];
  // One item among all that are read: its box's key (the world and the box's number) and its own number. The
  // number alone is one world's - under 全部を見る two shards can hold the same one.
  const itemKey = it => it.boxKey + "\u0000" + it.id;

  // ---- pairs: an account and a shard together
  //
  // The records of one account on one shard are one world: the same house numbers, the same boxes. Two accounts on one
  // shard, or one account on two shards, are different worlds and must not be shown together. The game cannot tell the
  // page which world it is in (the client holds no account or shard name: looked for in game), so the page is told: a record
  // carries the character's own number, and the number is matched to a character under Documents\EA Games\<game>\User
  // Data\<account>\<shard>\<character> (/api/chars).
  //
  // A pair is written as "<account>\n<shard>", and an assignment as "<account>\n<shard>\n<character>".
  // A newline is a character no folder name can hold, so the parts can always be told apart again; and it
  // keeps the names file a map of text to text.
  const PAIR_ALL = "all";                 // 「全部を見る」: every record, whatever its pair
  const PAIR_SEP = "\n";
  const PAIR_UNASSIGNED = "\u0000none";   // a record whose number nobody has assigned yet

  // ---- names: { houses: { "<pair>\n1": ... }, floors: { "<pair>\n1:2": ... }, boxes: { "<pair>\n<box id>": ... },
  //              chars: { "<character number>": "<account>\n<shard>\n<character>" },
  //              view:  { pair: "<account>\n<shard>" | "all", legacy: "<account>\n<shard>" },
  //              areas: { "<pair>\n1": "<facet> <minX> <maxX> <minY> <maxY>" } }   (the houses of a pair)
  // A box's name is keyed by its pair and its number, a number being one shard's; one kept by the
  // number alone is from before that, and is moved (migrateBoxNames). Under 全部を見る a box its own pair has
  // not named is called by the name another pair of the same shard gave it (sharedBoxName).
  const names = { houses: {}, floors: {}, boxes: {}, chars: {}, view: {}, areas: {} };
  let namesLoaded = false;
  let savePending = false;
  let saveTimer = 0;

  // cabinet: which kind of cabinet's items the results show (its button pressed), or null for everything
  // else. A kind is the tid of the name in the cabinet's gump title, as its record gives it.
  const state = { q: "", lineq: [], houses: new Set(), floors: new Set(), conds: [], sort: "name", limit: PAGE_SIZE, open: new Set(), cabinet: null,
    // Which pair is being looked at. Kept in the names file (view.pair), so the page opens where it was
    // left; PAIR_ALL until the names have been read.
    pair: PAIR_ALL,
    // The Davies' locker's filter (drawFramedFilter): the kind ("map" or "sos"), and the tids of the facet, the
    // 「〜の」, the grade and the status; null where nothing of that row is chosen. Kept while the page is open
    // only - not in the names file - and let go by 設定の解除 and 条件の消去.
    locker: { kind: null, facet: null, prefix: null, tier: null, status: null },
    // The filters of the armour refinement cabinet, the power scroll book and the transcendence scroll book
    // (FRAMED_FILTERS), kept the same way: the refinement's grade, bonus and armour as their words; the power scroll's
    // grade as its number (105-120); a scroll's skill as its tid. null where nothing of that row is chosen.
    // And the group of the skills window a scroll's skill is in, as the group's name (SKILL_TABS).
    refine: { rank: null, bonus: null, armor: null },
    power: { rank: null, group: null, skill: null },
    trans: { group: null, skill: null } };
  // What /api/chars answered: the accounts on this PC with their shards and characters.
  let charTree = { accounts: [] };
  // The character numbers the records carry, id -> { name, records, last }: filled at every rebuild.
  let charsSeen = new Map();
  // The characters whose older numbers are open in 名前の設定, by their assignment. Kept only while the
  // page is open, so that a redraw does not shut them under the player.
  const olderOpen = new Set();
  // The kind of cabinet a box is - a scroll book counts as one: its scrolls are in a gump too,
  // and its kind is the tid of the name in that gump's title - and so does a Davies' locker.
  // null when it is an ordinary box.
  // A Davies' locker's kind: the tid of its gump's title, 「デイビーズのロッカー」 (1153552), the record's
  // own first label - written here, since the record does not carry it: there is one kind of locker.
  const LOCKER_KIND = 1153552;
  const LOCKER_BUTTON_TITLE = "デイビーズのロッカーの地図と SOS だけを出します。もう一度押すと、ふだんの一覧に戻ります";
  // The other kinds by name, for where their buttons stand (KIND_GRID) and for their filters: the tids of their
  // gumps' titles, as the records give them.
  const REFINE_KIND = 1165086;   // 防具強化材キャビネット
  const POWER_KIND = 1155689;    // パワースクロールブック
  const TRANS_KIND = 1151675;    // 超越のスクロールブック
  const DYE_KIND = 1164139;      // 染色キャビネット
  const JEWEL_KIND = 1157694;    // 宝石箱
  const cabinetKind = b => b.jewel ? b.jewel.kind : (b.book ? b.book.kind : (b.locker ? LOCKER_KIND : null));
  // Whether an item belongs to the results being shown: one kind of cabinet's, or everything else.
  const inView = it => cabinetKind(it.boxRef) === state.cabinet;
  // A jewel box the records do not cover to the end, judged on the records laid over each other rather than
  // on the newest alone: one opening can be written as several records (a page that arrives late while it
  // is open can make several records of one opening), and together they can still hold everything.
  // Enough means as many items as the box said it holds, seen on every one of its pages. A number that
  // could not be read ("-") is not enough: such a box is listed as well, rather than passed as complete.
  const jewelShort = b => !!b.jewel && !(b.jewel.items !== null && b.jewel.stacked >= b.jewel.items
    && b.jewel.pages !== null && b.jewel.covered >= b.jewel.pages);
  // A scroll book whose records laid over each other do not read every skill it holds (decided in one place,
  // CPlusHomeParse.stackedBook): what it holds beyond the skills read is not known, so the page says so rather
  // than letting a part of a book look like the whole of it.
  const bookShort = b => !!b.book && !b.book.done;
  // How much of a book its records read: 「読み込んだ技能 N / 全 M」, M 「不明」 where the records could not
  // count the skills the book holds.
  const bookCoverage = book => "読み込んだ技能 " + book.stacked + " / 全 " + (book.total === null ? "不明" : book.total);
  // A Davies' locker not read to the end, decided in one place too: CPlusHomeParse.lockerComplete.
  const lockerShort = b => !!b.locker && !CPlusHomeParse.lockerComplete(b.locker);
  // A number as the page shows it, "-" where the record could not read one.
  const dash = n => (n === null || n === undefined ? "-" : String(n));

  // ---- talking to the reader

  // The reader's answer, or { lost: true } thrown when it cannot be reached at all.
  async function ask(url, options) {
    try {
      return await fetch(url, Object.assign({ cache: "no-store" }, options));
    } catch (e) {
      throw { lost: true, detail: String(e && e.message || e) };
    }
  }

  // The records of one bundle: { got: Map(name -> text), whole }.
  //
  // Each record is announced by how many characters it holds, so the text is cut out by counting and a
  // record holding tabs and newlines cannot be read as the start of the next one. Counting is in UTF-16
  // code units, which is what a JavaScript string length is and what the reader's String.Length is.
  //
  // null when the answer is not a bundle at all ( an older reader, or anything unexpected ). whole is
  // false when it stops in the middle: what was complete before that point is still handed back, since
  // half the records now and the rest asked for one at a time beats an empty screen.
  function parseBundle(text) {
    if (!text.startsWith(BUNDLE_HEAD + "\n")) return null;
    const got = new Map();
    let at = BUNDLE_HEAD.length + 1;
    while (at < text.length) {
      const eol = text.indexOf("\n", at);
      if (eol < 0) return { got, whole: false };
      const tab = text.indexOf("\t", at);
      if (tab < 0 || tab > eol) return { got, whole: false };
      const count = Number(text.slice(at, tab));
      const name = text.slice(tab + 1, eol);
      if (!Number.isInteger(count) || count < 0 || !name) return { got, whole: false };
      const end = eol + 1 + count;
      if (end > text.length) return { got, whole: false };
      got.set(name, text.slice(eol + 1, end));
      at = end;
    }
    return { got, whole: true };
  }

  // The records in one answer, or null to ask for them one at a time instead. Null covers every way this
  // can fail: a reader from before /api/bundle ( 404 ), an answer that is not a bundle, one that stopped
  // halfway with nothing whole in it, an answer too large for this browser to hold, and the reader being
  // away - the asking one at a time that follows meets the same reader and says so properly.
  async function loadBundle() {
    try {
      const res = await ask(API_BUNDLE);
      if (!res.ok) return null;
      const bundle = parseBundle(await res.text());
      if (!bundle) return null;
      // An empty bundle is not told apart from a failed one: both leave every record to be asked for
      // below, and the words on the screen are already written by then.
      return bundle.got;
    } catch (e) {
      return null;
    }
  }

  // Runs work over list with at most `at` running at once. After a failure nothing new starts; once the
  // ones running have finished, the first failure is thrown.
  async function eachAtOnce(list, at, work) {
    let next = 0;
    let failure = null;
    const worker = async () => {
      while (!failure && next < list.length) {
        const item = list[next++];
        try { await work(item); } catch (e) { failure = failure || e; }
      }
    };
    await Promise.all(Array.from({ length: Math.min(at, list.length) }, worker));
    if (failure) throw failure;
  }

  // ---- messages at the top

  function measureHeader() {
    const h = $("top").offsetHeight;
    if (h) document.documentElement.style.setProperty("--head", h + "px");
  }
  // 一番上へ／一番下へ sit in the bottom left, in the column of the search conditions: the panel of
  // conditions ends above them (.builderpanel takes --jump off its height), so they never cover its last entries.
  function measureJump() {
    const h = $("jump").offsetHeight;
    if (h) document.documentElement.style.setProperty("--jump", h + "px");
  }
  function showAlert(text, where) {
    const a = $("alert");
    a.replaceChildren(text);
    if (where) a.appendChild(el("span", "where", where));
    a.hidden = false;
    measureHeader();
  }
  function hideAlert() { $("alert").hidden = true; measureHeader(); }
  function showBar(id, text) { $(id).textContent = text; $(id).hidden = !text; measureHeader(); }

  let noticeTimer = 0;
  function notice(text, lasting) {
    clearTimeout(noticeTimer);
    $("notice").textContent = text;
    if (!lasting) noticeTimer = setTimeout(() => { $("notice").textContent = ""; }, NOTICE_MS);
  }

  // The last part of a folder's path, with either separator ("C:\EC\logs\CPlusExport" -> "CPlusExport").
  function folderName(dir) {
    const parts = String(dir).split(/[\\/]/).filter(Boolean);
    return parts.length ? parts[parts.length - 1] : String(dir);
  }

  // ---- where the records folder is

  // The form for telling it is open while the page has to ask ( asked: no place to look, or the settings that
  // keep it could not be read ) or once 変える was pressed ( opened ). moved: another folder was taken, and the
  // next round reads it from the start.
  let folderAsked = false, folderOpened = false, folderMoved = false;
  function drawFolderForm() {
    $("folderForm").hidden = !(folderAsked || folderOpened);
    measureHeader();
  }

  // What the list says about the records folder ( home_search_server.ps1 Get-FileList ): where it was looked for
  // ( "" when there was nowhere to look ), whether it is there, and why the settings that keep it could not be
  // read ( "" when they could ). Each way it can be is said its own way, so that "not there", "not known" and "the
  // settings would not read" never look alike.
  function drawFolderState(list) {
    const dir = list.recordsDir || "";
    if (list.settingsError) {
      showAlert("記録のフォルダの設定を読めませんでした（" + list.settingsError + "）。下の欄に記録のフォルダの場所を貼って［決める］を押すと、設定を書き直します。",
        dir ? "いま見ている場所: " + dir : "");
      folderAsked = true;
    } else if (!dir) {
      showAlert("記録のフォルダの場所を教えてください。ゲームのフォルダが、いつもの場所に見つかりませんでした。下の欄にゲームのフォルダの場所を貼って［決める］を押してください。");
      folderAsked = true;
    } else if (!list.found) {
      showAlert("記録のフォルダが見つかりません。ゲームのフォルダの logs の中に CPlusExport フォルダを作ってください。ゲームは自動では作らないので、無い間の記録は書き出されていません。ゲームを別の場所に入れているときは、［変える］からその場所を教えてください。", "探した場所: " + dir);
      folderAsked = false;
    } else {
      hideAlert();
      folderAsked = false;
    }
    // The folder's own name only, so the header stays on two lines in half of a 1920px screen; the whole
    // path is in its title.
    $("source").textContent = dir ? folderName(dir) + "（" + list.files.length + " 本）" : "記録のフォルダ: 未設定";
    $("source").title = dir ? "記録のフォルダ: " + dir : "";
    drawFolderForm();
  }

  // ［決める］: the reader checks the place and keeps it. Taken, the records are read again from the new folder; refused,
  // the reader's reason is shown as it was given.
  async function setFolder() {
    const said = $("folderMsg");
    const path = $("folderPath").value.trim();
    if (!path) { said.textContent = "場所を貼ってください。"; return; }
    said.textContent = "確かめています…";
    let res;
    try {
      res = await ask(API_RECORDSDIR, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ path }) });
    } catch (e) {
      if (!(e && e.lost)) throw e;
      said.textContent = "読み出し役に届かないので、変えられませんでした。『家の記録検索.bat』から開き直してください。";
      return;
    }
    if (res.status === 409) { said.textContent = "起動時に指定されているので変えられません。"; return; }
    if (!res.ok) {
      const detail = await detailOf(res);
      said.textContent = detail || "読み出し役が受け付けませんでした（HTTP " + res.status + "）。";
      return;
    }
    $("folderPath").value = "";
    said.textContent = "";
    folderOpened = false;
    folderMoved = true;
    // A plan of 整理削除 made from the folder before names that folder's records: dropped, so that 消す cannot send them
    // to the new one. 整理削除 is pressed again.
    tidyPlan = null;
    showBar("tidyBar", "");
    drawFolderForm();
    refresh();
  }

  // ---- reading the records

  // One round at a time. A call while a round runs is dropped (focus and visibilitychange come together
  // when the viewer comes back): the round running asks for the list itself, and the next one is 5 s away.
  let refreshing = false;
  async function refresh() {
    if (refreshing) return;
    refreshing = true;
    try {
      await refreshOnce();
    } catch (e) {
      // Not the reader being away (refreshOnce says that itself): something this page did not expect.
      showAlert("記録を読む途中で問題が起きました。", String(e && e.message || e));
    } finally {
      refreshing = false;
    }
  }

  async function refreshOnce() {
    // Another records folder was taken: read it as the first load is read ( all at once ), keeping nothing of the
    // folder before.
    if (folderMoved) {
      folderMoved = false;
      files.clear();
      refusals.clear();
      loadedOnce = false;
    }
    let list;
    try {
      const res = await ask(API_FILES);
      if (!res.ok) { showAlert("読み出し役から記録の一覧を受け取れませんでした（HTTP " + res.status + "）。『家の記録検索.bat』から開き直してください"); return; }
      list = await res.json();
    } catch (e) {
      if (e && e.lost) { showAlert(READER_LOST, loadedOnce ? "下の表示は最後に読めたときのままです。" : ""); drawNotLoaded(); return; }
      throw e;
    }
    drawFolderState(list);
    $("namesFile").textContent = list.namesFile;
    // Names read after the first reading change what the records are: the pair each belongs to,
    // the pair being looked at, and the table of houses. Everything is built again from them.
    if (!namesLoaded && await loadNames() && loadedOnce) rebuild();
    if (savePending) saveNames();

    const listed = new Map(list.files.map(f => [f.name, f]));
    const wanted = list.files.filter(f => {
      const known = files.get(f.name);
      return !known || known.mtime !== f.mtime || known.size !== f.size || known.parsed.status === "partial";
    });
    let added = 0, reread = 0, removed = 0, changed = false, done = 0;
    // What a record's text does to what is known, whichever way it arrived.
    const takeRecord = (f, text) => {
      refusals.delete(f.name);
      const parsed = CPlusHomeParse.parseRecord(text);
      // The house number a record carries is its character's own, not the page's. It is kept as
      // recordHouse and house is taken away, so that whatever reads a record's house without asking houseOf
      // gets nothing rather than a number that is quietly wrong.
      if (parsed.status === "ok") {
        parsed.box.recordHouse = parsed.box.house;
        delete parsed.box.house;
      }
      const known = files.get(f.name);
      const wasOk = known && known.parsed.status === "ok";
      const misses = parsed.status === "partial" ? (known && known.parsed.status === "partial" ? known.misses + 1 : 1) : 0;
      files.set(f.name, { size: f.size, mtime: f.mtime, parsed, misses });
      if (parsed.status === "ok") { if (wasOk) reread++; else added++; changed = true; }
      else if (wasOk) { removed++; changed = true; }
    };
    for (const name of [...files.keys()]) {
      if (listed.has(name)) continue;
      if (files.get(name).parsed.status === "ok") { removed++; changed = true; }
      files.delete(name);
    }
    for (const name of [...refusals.keys()]) if (!listed.has(name)) refusals.delete(name);
    const first = !loadedOnce;
    // The first load asks for everything in one answer; anything it did not bring is asked for
    // one at a time below, which is also the whole of the road when the bundle does not work at all.
    let rest = wanted;
    if (first && wanted.length) {
      notice("記録を読み込み中… まとめて受け取っています（" + wanted.length + " 本）", true);
      const bundled = await loadBundle();
      if (bundled) {
        for (const f of wanted) {
          const text = bundled.get(f.name);
          if (text === undefined) continue;   // not in it: asked for on its own below
          takeRecord(f, text);
          done++;
        }
        rest = wanted.filter(f => !bundled.has(f.name));
      }
    }
    if (first && rest.length) notice("記録を読み込み中… " + done + " / " + wanted.length, true);
    let lost = false;
    try {
      await eachAtOnce(rest, FETCH_AT_ONCE, async f => {
        const res = await ask(API_FILE + encodeURIComponent(f.name));
        done++;
        if (first) notice("記録を読み込み中… " + done + " / " + wanted.length, true);
        if (!res.ok) {
          // Gone or busy since the list was made: the next round asks again. Counted, so that one the
          // reader keeps refusing is reported rather than missing without a word.
          const before = refusals.get(f.name);
          refusals.set(f.name, { times: before ? before.times + 1 : 1, status: res.status });
          return;
        }
        takeRecord(f, await res.text());
      });
    } catch (e) {
      if (!(e && e.lost)) throw e;
      lost = true;
    }

    if (changed || first) rebuild();
    loadedOnce = true;
    drawUnreadable();
    if (lost) { showAlert(READER_LOST, "下の表示は最後に読めたときのままです。"); return; }
    if (first) notice("");
    else if (added || reread || removed) {
      const parts = [];
      if (added) parts.push("+" + added + " 本");
      if (removed) parts.push("−" + removed + " 本");
      if (reread) parts.push(reread + " 本を読み直し");
      notice("更新: 記録 " + parts.join("・"));
    }
  }

  // 箱・アイテム・記録の本数と、そのうち古い記録の本数。The number of older records is the one
  // thing here the player can act on, so it is the one thing in colour ( --warn: --hit already means
  // 「これだけ当たった」 and 「この条件で絞っている」 ). At 0 it is not coloured and the button is
  // dead: there is nothing to do.
  function drawSummary() {
    const records = [...files].filter(([, f]) => f.parsed.status === "ok").length;
    const older = olderRecords(Date.now());
    const summary = $("summary");
    summary.replaceChildren("箱 " + boxes.length + " ・ アイテム " + items.length.toLocaleString() +
      " ・ 記録 " + records.toLocaleString() + " 本（古い記録 ");
    summary.append(el("span", older.length ? "warn" : "", older.length.toLocaleString()), " 本）");
    $("tidy").disabled = !older.length || !namesLoaded;
    $("tidy").title = !namesLoaded ? TIDY_WAIT_TITLE : older.length ? TIDY_TITLE : TIDY_NONE_TITLE;
  }

  // 整理削除: work out what is old **now** ( not what the header said, which may be seconds out of date ),
  // check that deleting it would change nothing, and only then ask.
  // Not before the names file is read: until then no record's pair is known, and a record of
  // another account's can look like an older record of the same box. The button is closed
  // (drawSummary), and both presses ask again - deleting cannot be undone.
  const TIDY_TITLE = $("tidy").title;
  const TIDY_WAIT_TITLE = "名前のファイルを読めてから押せます（読めるまで、どの記録が同じアカウントのものか分かりません）";
  const TIDY_NONE_TITLE = "古い記録がないので押せません";
  // Said wherever older records are kept because the page still uses them.
  const TIDY_USED_WHY = "（読みかけのスクロールブック・宝石箱の前の記録など）";
  const TIDY_WAIT_TEXT = "名前のファイルをまだ読めていないので、何も消していません。どの記録が同じアカウントのものか分からないためです。" +
    "読めてから、もう一度［整理削除］を押してください。";
  let tidyPlan = null;
  // What one press offers: of the older records, the ones whose deleting changes nothing on the page, and the ones kept
  // because the page still uses them ( a scroll book's earlier readings laid under the newest, a jewel box's earlier
  // pages, an old record that splits a house's area ... ). Decided box by box ( olderRecords' groups: a box's older
  // records go together or stay together ), by halving: the groups that can go all together are taken as they are;
  // a set that changes something is split in two and each half looked at again, down to the one box that does. Two
  // halves that are each fine but change something together keep the larger. So whatever is offered has been
  // checked as the whole set it is, never only box by box.
  // { drop: the records to delete now ( the oldest DELETE_AT_ONCE of the free ones, whole boxes ), used: the records
  // kept as used, more: how many free records are left for the next press }. Oldest first is the closing time, then
  // the file's own time, then the name, the other way round from CPlusHomeParse.newer. Both presses make it the same
  // way, so the second compares like with like: comparing all of them (501) with the plan (500) would say
  // 「変わった」 every time, and nothing would ever be deleted.
  function tidySplit(older) {
    if (!older.length) return { drop: [], used: [], more: 0 };
    const check = tidyChecker();
    const groups = new Map();
    for (const r of older) {
      if (!groups.has(r.group)) groups.set(r.group, []);
      groups.get(r.group).push(r);
    }
    const oldestFirst = (a, b) => (CPlusHomeParse.newer(a, b) ? 1 : CPlusHomeParse.newer(b, a) ? -1 : 0);
    const ordered = [...groups.values()].map(recs => recs.slice().sort(oldestFirst)).sort((a, b) => oldestFirst(a[0], b[0]));
    const namesOf = gs => new Set(gs.flatMap(g => g.map(r => r.name)));
    const free = gs => {
      if (!gs.length || !check(namesOf(gs))) return gs;
      if (gs.length === 1) return [];
      const half = Math.ceil(gs.length / 2);
      const a = free(gs.slice(0, half)), b = free(gs.slice(half));
      const both = a.concat(b);
      if (!check(namesOf(both))) return both;
      return a.length >= b.length ? a : b;
    };
    let freed = free(ordered);
    const used = ordered.filter(g => !freed.includes(g)).flat();
    // At most DELETE_AT_ONCE ( the reader takes no more in one request ), whole boxes, oldest first: a box cut in two
    // would be a set nobody checked. A box with more than that alone is cut, and checked below.
    let batch = [], count = 0;
    for (const g of freed) {
      if (count + g.length > DELETE_AT_ONCE) {
        if (!batch.length) batch = [g.slice(0, DELETE_AT_ONCE)];
        break;
      }
      batch.push(g);
      count += g.length;
    }
    if (batch.length && check(namesOf(batch))) batch = free(batch);
    const drop = batch.flat();
    return { drop, used, more: freed.flat().length - drop.length };
  }
  function tidyAsk() {
    tidyPlan = null;
    if (!namesLoaded) { showBar("tidyBar", TIDY_WAIT_TEXT); return; }
    const older = olderRecords(Date.now());
    if (!older.length) { showBar("tidyBar", "古い記録はありません。"); return; }
    const split = tidySplit(older);
    if (!split.drop.length) {
      showBar("tidyBar", "消せる古い記録はありません。古い記録 " + split.used.length + " 本は今の表示で使われています" + TIDY_USED_WHY +
        "。本を最後まで読むと、その前の記録は使われなくなります。");
      return;
    }
    const batch = split.drop;
    tidyPlan = { names: batch.map(r => r.name), bytes: batch.reduce((sum, r) => sum + (r.size || 0), 0) };
    const bar = $("tidyBar");
    const size = (tidyPlan.bytes / 1048576).toFixed(1) + " MB";
    const usedNote = split.used.length ? "（うち " + split.used.length + " 本は今の表示で使われているので残します）" : "";
    bar.replaceChildren(split.more
      ? "古い記録 " + older.length + " 本" + usedNote + "のうち、古いものから " + batch.length + " 本・" + size +
        " を消します。元に戻せません。残りは、消したあとにもう一度［整理削除］を押すと消せます。 "
      : split.used.length
        ? "古い記録 " + older.length + " 本" + usedNote + "のうち、" + batch.length + " 本・" + size + " を消します。元に戻せません。 "
        : "古い記録 " + batch.length + " 本・" + size + " を消します。元に戻せません。 ");
    const go = el("button", "", "消す");
    go.addEventListener("click", () => tidyDelete());
    const stop = el("button", "", "やめる");
    stop.addEventListener("click", () => { tidyPlan = null; showBar("tidyBar", ""); });
    bar.append(go, " ", stop);
    bar.hidden = false;
    measureHeader();
  }

  // The second press. The records are read again every five seconds, so what was checked a
  // moment ago may not be what is there now: the split ( and the check inside it ) is made again here, and
  // anything that has moved means nothing is deleted and the player is told to look again.
  async function tidyDelete() {
    if (!tidyPlan) return;
    const planned = tidyPlan.names;
    tidyPlan = null;
    if (!namesLoaded) { showBar("tidyBar", TIDY_WAIT_TEXT); return; }
    const older = olderRecords(Date.now());
    const split = tidySplit(older);
    const names = split.drop.map(r => r.name);
    if (names.length !== planned.length || !names.every(name => planned.includes(name))) {
      showBar("tidyBar", "そのあいだに記録が変わったので、何も消していません。もう一度［整理削除］を押してください" +
        "（いまの古い記録は " + older.length + " 本です）。");
      return;
    }
    showBar("tidyBar", "消しています…");
    let res;
    try {
      res = await ask(API_DELETE, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ names }) });
    } catch (e) {
      if (!(e && e.lost)) throw e;
      showBar("tidyBar", "読み出し役に届かないので、何も消せませんでした。『家の記録検索.bat』から開き直してください。");
      return;
    }
    if (!res.ok) {
      const detail = await detailOf(res);
      showBar("tidyBar", "読み出し役が消せませんでした（HTTP " + res.status + (detail ? ": " + detail : "") + "）。");
      return;
    }
    const got = await res.json();
    for (const name of got.deleted || []) files.delete(name);
    const failed = got.failed || [];
    const done = (got.deleted || []).length;
    // When not one of them went, the reasons above are the whole answer - so say where to look
    // next rather than leaving the player with a list. The reason itself is not guessed at here: a record
    // can be open in another program, or the folder can be one this reader may not write.
    const nextStep = (done === 0 && failed.length)
      ? "1 本も消せていません。上の理由をお読みください（ゲームやほかのソフトがその記録を開いているとき、" +
        "記録のフォルダに書けないときに出ます）。『家の記録検索.bat』から開き直すと直ることもあります。"
      : "";
    showBar("tidyBar", "古い記録 " + done + " 本を消しました。" +
      (split.used.length ? split.used.length + " 本は今の表示で使われているので残しました" + TIDY_USED_WHY + "。" : "") +
      (failed.length ? "消せなかったものが " + failed.length + " 本あります: " +
        failed.slice(0, 3).map(f => f.name + "（" + f.detail + "）").join("、") + (failed.length > 3 ? " ほか" : "") : "") +
      nextStep);
    rebuild();
  }

  function drawUnreadable() {
    const bad = [...files]
      .filter(([name, f]) => !refusals.has(name) && (f.parsed.status === "unreadable" || (f.parsed.status === "partial" && f.misses >= PARTIAL_REPORT_AFTER)))
      .map(([name, f]) => name + "（" + f.parsed.reason + "）");
    for (const [name, r] of refusals) if (r.times >= PARTIAL_REPORT_AFTER) bad.push(name + "（読み出し役の返事が HTTP " + r.status + "）");
    if (!bad.length) { showBar("unreadable", ""); return; }
    showBar("unreadable", "読めない記録が " + bad.length + " 本あります: " + bad.slice(0, UNREADABLE_NAMED).join("、") + (bad.length > UNREADABLE_NAMED ? " ほか" : ""));
  }

  // ---- names, kept by the reader in a file of this PC's user (the records folder is not writable
  // without administrator rights); /api/files says which file

  // Whether the names could be read. Until they are, the name boxes stay closed: saving before reading
  // would replace the file with only what was typed here.
  // Asked again every round until read. The message tells the reader being away (read once it answers)
  // from the reader answering that it cannot read them (its reason is shown).
  async function loadNames() {
    let res;
    try {
      res = await ask(API_NAMES);
    } catch (e) {
      if (!(e && e.lost)) throw e;
      $("namesState").textContent = "名前をまだ読めていません（読み出し役に届きません）。読み出し役に届けば読みます";
      return false;
    }
    if (!res.ok) {
      const detail = await detailOf(res);
      $("namesState").textContent = "読み出し役が名前を読めませんでした（HTTP " + res.status + (detail ? ": " + detail : "") + "）。読めるまで名前の欄は閉じています";
      return false;
    }
    let got;
    try {
      got = await res.json();
    } catch (e) {
      // A names file that is not JSON: said here, and the records are still read.
      $("namesState").textContent = "名前のファイルの中身を読めませんでした（" + String(e && e.message || e) + "）。読めるまで名前の欄は閉じています";
      return false;
    }
    for (const kind of ["houses", "floors", "boxes", "chars", "view", "areas"]) names[kind] = Object.assign({}, got && got[kind] || {});
    migrateNames();
    if (names.view.pair) state.pair = names.view.pair;
    namesLoaded = true;
    $("namesState").textContent = "";
    return true;
  }

  // Saving is put off a moment, so that typing a name does not send one request a letter. Before the names
  // are read nothing is saved (saveNames), so nothing is said to be waiting either: the line keeps saying
  // why the names are not read.
  function saveNamesSoon() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(saveNames, SAVE_DELAY_MS);
    if (namesLoaded) $("namesState").textContent = "保存待ち…";
  }

  function changeName(kind, key, value) {
    if (value.trim()) names[kind][key] = value;
    else delete names[kind][key];
    saveNamesSoon();
  }

  // Two failures, told apart. The reader could not be reached (stopped, say): saved again once it answers.
  // The reader answered that it could not save: its reason is shown, and nothing is tried again by itself,
  // since waiting does not mend that; the bar offers to try again. Either way the names stay on the page,
  // and the bar says they are not saved yet.
  // **Nothing is saved before the names file has been read.** What this page holds then is only
  // what was changed here, and saving it would put that in place of the whole file - the names, the
  // assignments and the table of houses gone at once. This is the one door every save goes through (the
  // timer, the saving again once the reader answers, the button), so it is shut here.
  async function saveNames() {
    if (!namesLoaded) return;
    savePending = false;
    const body = JSON.stringify({ version: 1, houses: names.houses, floors: names.floors, boxes: names.boxes,
      chars: names.chars, view: names.view, areas: names.areas });
    let res;
    try {
      res = await ask(API_NAMES, { method: "POST", headers: { "Content-Type": "application/json" }, body });
    } catch (e) {
      if (!(e && e.lost)) throw e;
      savePending = true;
      showSaveError("読み出し役に届かないので、名前をまだ保存できていません。付けた名前はこの画面にだけあります（閉じると消えます）。読み出し役に届けば保存し直します。", false);
      $("namesState").textContent = "保存できていません（読み出し役に届きません）";
      return;
    }
    if (!res.ok) {
      const detail = await detailOf(res);
      showSaveError("読み出し役が名前を保存できませんでした（HTTP " + res.status + (detail ? ": " + detail : "") + "）。付けた名前はこの画面にだけあり、まだ保存されていません（閉じると消えます）。", true);
      $("namesState").textContent = "保存できていません";
      return;
    }
    showSaveError("", false);
    $("namesState").textContent = "保存しました";
  }
  // The reason the reader gives with a refusal ({ detail }), or "" when the answer carries none.
  async function detailOf(res) {
    try {
      const got = await res.json();
      return got && typeof got.detail === "string" ? got.detail : "";
    } catch (e) {
      return ""; // not JSON: the HTTP status shown beside it is all there is to say
    }
  }
  function showSaveError(text, offerRetry) {
    const bar = $("saveError");
    bar.replaceChildren(text);
    if (offerRetry) {
      const again = el("button", "", "もう一度保存する");
      again.addEventListener("click", () => saveNames());
      bar.append(" ", again);
    }
    bar.hidden = !text;
    measureHeader();
  }

  // Where the records that carry no number belong - null until it is chosen in 名前の設定, and they are then
  // treated as unassigned records are - and the pair a number was assigned to.
  const legacyPair = () => names.view.legacy || null;
  const pairOfAssignment = value => String(value || "").split(PAIR_SEP).slice(0, 2).join(PAIR_SEP);
  const assignedPair = id => (names.chars[String(id)] ? pairOfAssignment(names.chars[String(id)]) : null);
  // The pair a record belongs to: the one its number was assigned to, the legacy pair when it carries no
  // number at all, and null while nobody has said - which is what keeps an unassigned record out of every
  // pair but 全部を見る.
  const pairOfBox = box => (box && box.char ? assignedPair(box.char.id) : legacyPair());
  // What its names are kept under. An unassigned record still gets a place of its own, so that naming a
  // house does not write into a pair it may not belong to.
  const namesPairOf = box => pairOfBox(box) || PAIR_UNASSIGNED;
  const nameKey = (pair, rest) => pair + PAIR_SEP + rest;
  // The world the records are put together in (CPlusHomeParse.combine): the pair while a pair is looked
  // at, and under 全部を見る the pair's shard. A box's number is one shard's, so two accounts' records of
  // one box on one shard are records of that one box, and 全部を見る shows it once, from the newest of them. A
  // record nobody has placed yet stays in a world of its own: its shard is not known. A box's names are still
  // its pair's - the pair of the record it is shown from (namesPairOf) - never its world's.
  // Asked with the way of looking - all: 全部を見る - rather than with the one the page is in: the page
  // reads the way it is looking (rebuild) and the tidying check reads both ways (tidyChecker), and one function
  // for both means the two can never put a record in different worlds.
  const shardOf = pair => pair.split(PAIR_SEP)[1];
  const worldFor = all => rec => {
    const pair = namesPairOf(rec.parsed.box);
    return all && pair !== PAIR_UNASSIGNED ? shardOf(pair) : pair;
  };
  // Whose names a house's label comes from: the pair of a box standing in that house. Under 全部を見る
  // two pairs can have a house of the same number; the first box decides the label, and the names
  // themselves are still kept apart, one key a pair.
  // The pair of the box standing on the floor (box.top), whose pair gave the house its number: under
  // 全部を見る a box inside it can be shown from another account's record, and that account's house of this
  // number is another house.
  const houseBox = h => boxes.find(b => b.top.house === h);
  const housePair = h => {
    const box = houseBox(h);
    return box ? namesPairOf(box.top) : (state.pair === PAIR_ALL ? legacyPair() || PAIR_UNASSIGNED : state.pair);
  };
  // A house's floors, as the reading counted them: in the world of that same box. Under 全部を見る that
  // is the shard, so one shard's house of one number is counted as one house whichever account's boxes stand in
  // it; the floors' names are still housePair's.
  const houseFloors = h => {
    const box = houseBox(h);
    return (box && floors.get(CPlusHomeParse.floorKey(box.top.world, h))) || [];
  };
  // A house's name. The pair is given where it is known which pair's house is meant (the line for the game);
  // the labels on the page go by housePair.
  const houseName = (h, pair = housePair(h)) => names.houses[nameKey(pair, h)] || ("家" + h);
  const floorName = (h, n) => names.floors[nameKey(housePair(h), h + ":" + n)] || (n ? n + "階" : "階不明");

  // The houses of a pair: which number stands for which house.
  //
  // The house number in a record is a character's own: the game keeps the houses registered on each
  // character, numbered as the player numbered them there. Two characters of one pair can give one house two
  // numbers, and a page going by those numbers would show one house as two - under whichever number the
  // character who last opened a box had given it. So the page keeps a table of its own for each pair,
  // names.areas ("<pair>\n<n>" -> "<facet> <minX> <maxX> <minY> <maxY>", kept in the names file), and a
  // record's house is decided from it (houseOf). The table is learned from the area line a record carries
  // (learnHouses) and only ever added to: a number, once given, keeps its house whatever records are tidied
  // away, and so do the names written for it.
  const areaText = a => [a.facet, a.minX, a.maxX, a.minY, a.maxY].join(" ");
  // The houses the table holds for a pair: [{ n, facet, minX, maxX, minY, maxY }]. A value that does not read
  // as an area is no house here, but it still holds its number: learnHouses never writes over it.
  function tableHouses(pair) {
    const head = pair + PAIR_SEP;
    const houses = [];
    for (const [key, value] of Object.entries(names.areas)) {
      const n = key.startsWith(head) ? key.slice(head.length) : "";
      if (!/^[1-9]\d*$/.test(n)) continue;
      const area = CPlusHomeParse.readArea(String(value).split(" "));
      if (area) houses.push(Object.assign({ n: Number(n) }, area));
    }
    return houses;
  }
  // Whether two areas share a tile, and whether the place a record was made at is in an area: edges
  // included and on one facet, as CPlusHomeRecord.lua's houseAt takes a house.
  const overlaps = (a, b) => a.facet === b.facet && a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY;
  const holds = (a, box) => box.facet === a.facet && box.x !== null && box.y !== null &&
    box.x >= a.minX && box.x <= a.maxX && box.y >= a.minY && box.y <= a.maxY;

  // Which house a record's box is in: **the one place that says**, so that no list, count or check can go by
  // a character's number where the page shows the table's. The first of these that decides:
  //   1. the record's area line, when exactly one house of its pair's table overlaps it and the area is not
  //      split (an area over two houses overlaps the one of them the table has, and would carry
  //      every box recorded with it into that house);
  //   2. where the player stood - every record has it, those from before the area line too - when exactly
  //      one house of the table holds it;
  //   3. the number the record carries (recordHouse): what the page went by before the table, so that nothing
  //      leaves the screen when neither of the others can say.
  // { n, area }: the number, and the house of the table it was found in - null when the record's own number
  // decided, since then nothing says where that house is (the line for the game carries no area for it:
  // another building may stand in the table under the same number).
  function houseOf(box) {
    const pair = namesPairOf(box);
    const houses = tableHouses(pair);
    if (box.area) {
      const same = houses.filter(h => overlaps(h, box.area));
      if (same.length === 1 && !isSplit(pair, box.area)) return { n: same[0].n, area: same[0] };
    }
    const around = houses.filter(h => holds(h, box));
    if (around.length === 1) return { n: around[0].n, area: around[0] };
    return { n: box.recordHouse, area: null };
  }

  // The table learns from the records of characters assigned to a pair, oldest first. For each area line:
  //   - split (splitNumbers): which house it is cannot be said, and nothing is added. Asked before
  //     anything else: an area over two houses overlaps the one of them the table already has, and is no
  //     more that house for it;
  //   - one house of the pair overlaps it: it is that house, and nothing changes;
  //   - none does: a new house, under the number newHouseNumber gives it;
  //   - two or more do: which one cannot be said, and nothing is added.
  // Nothing is learned before the names file has been read: the table would start empty, and saving it
  // would write that over the file.
  function learnHouses() {
    if (!namesLoaded) return;
    withSplitMemo(() => {
      let added = 0;
      for (const [, f] of learningRecords()) {
        const box = f.parsed.box;
        const pair = assignedPair(box.char.id);
        if (pair === null || isSplit(pair, box.area)) continue;
        if (tableHouses(pair).some(h => overlaps(h, box.area))) continue;
        names.areas[nameKey(pair, newHouseNumber(pair, box.area))] = areaText(box.area);
        splitMemo = new Map();   // a house added can change the numbers the records are shown under
        added++;
      }
      if (added) saveNamesSoon();
    });
  }

  // The records houses are decided from: those read - or, while the tidying check asks what the page would show
  // after a deletion (asIfDeleted), those that would be left.
  let recordsLeft = null;
  const recordsNow = () => recordsLeft || files;

  // The records the table learns from, oldest first: those with an area line and a character's number.
  function learningRecords() {
    return [...recordsNow()].filter(([, f]) => f.parsed.status === "ok" && f.parsed.box.area && f.parsed.box.char)
      .sort(([an, a], [bn, b]) => (a.parsed.box.closed < b.parsed.box.closed ? -1 : a.parsed.box.closed > b.parsed.box.closed ? 1 : 0) ||
        (a.mtime - b.mtime) || (an < bn ? -1 : an > bn ? 1 : 0));
  }

  // The boxes of a pair's records: all that the numbering of its houses looks at. Another pair's records do not
  // come into it, wherever they stand.
  const boxesOfPair = pair => [...recordsNow().values()].filter(f => f.parsed.status === "ok" && namesPairOf(f.parsed.box) === pair)
    .map(f => f.parsed.box);

  // The numbers the records of a pair from before the area line (none of them carries one) that
  // stand in an area are shown under now (houseOf), smallest first. Two or more, and the area is **split**:
  // either it is two houses in one registration (a corner taken in the wrong house) or its old records gave one
  // house two numbers, and nothing here can tell which. The table is only ever added to, so a wrong guess could
  // not be taken back: a split area is not learned and decides no record's house, which
  // stay under the numbers they have, and the bar at the top says so (drawUnlearned). Counted before any
  // number in the table is set aside, and whatever the area overlaps. Only a number a house can have counts -
  // a broken record's box line gives none, or 0, which the game never writes.
  function splitNumbers(pair, area) {
    const key = nameKey(pair, areaText(area));
    if (splitMemo && splitMemo.has(key)) return splitMemo.get(key);
    const numbers = new Set();
    for (const box of boxesOfPair(pair)) {
      if (box.area || !holds(area, box)) continue;
      const n = houseOf(box).n;
      if (Number.isInteger(n) && n >= 1) numbers.add(n);
    }
    const sorted = [...numbers].sort((a, b) => a - b);
    if (splitMemo) splitMemo.set(key, sorted);
    return sorted;
  }
  const isSplit = (pair, area) => splitNumbers(pair, area).length >= 2;
  // The numbers are counted once for each area of a pair while neither the records nor the table can change:
  // through one learning (which starts again whenever it adds a house), one reading of the records and one
  // drawing of the bar. Outside those every question is counted afresh.
  let splitMemo = null;
  function withSplitMemo(fn) {
    splitMemo = new Map();
    try {
      return fn();
    } finally {
      splitMemo = null;
    }
  }

  // The number a new house of a pair takes: **the number the page shows for it now**, so that
  // learning a house never moves one that is already on the screen - whichever character records it first,
  // and whatever number that character gave it (otherwise the order in which two characters record a house
  // could renumber it, and the table, only ever added to, would keep that).
  //   1. The number the records from before the area line that stand in the new area are shown under
  //      (splitNumbers - one at most: a split area is not learned), when it is not in the table.
  //   2. When there is none, or it is in the table (another building, since the area overlaps none there): the
  //      number of the character that wrote it when that is free, else the smallest free from 1. Free: not in
  //      the table (a value that does not read as an area still holds its number) and not shown now for a
  //      record of the pair standing elsewhere.
  // Step 1 does not ask whether the number is shown elsewhere as well: when one number stood for two
  // buildings, the one learned first keeps it and the other moves on - rather than both moving and a name
  // written for that number being left with neither.
  function newHouseNumber(pair, area) {
    const inTable = n => nameKey(pair, n) in names.areas;
    const [shown] = splitNumbers(pair, area);
    if (shown !== undefined && !inTable(shown)) return shown;
    const elsewhere = new Set(boxesOfPair(pair).filter(box => !holds(area, box)).map(box => houseOf(box).n));
    const free = n => !inTable(n) && !elsewhere.has(n);
    if (free(area.n)) return area.n;
    let n = 1;
    while (!free(n)) n++;
    return n;
  }

  // The names were kept by house number alone before pairs existed, which would have put two
  // shards' house 1 under one name. Every key without a pair in it is moved into the legacy pair, once:
  // a key that has been moved holds a separator, so running this again does nothing. Nothing is dropped
  // and nothing is overwritten - a key that is already there wins, since it was written on purpose.
  function migrateNames() {
    let moved = 0;
    if (!legacyPair()) return moved;  // kept as they are until the legacy pair is chosen
    for (const kind of ["houses", "floors"]) {
      for (const key of Object.keys(names[kind])) {
        if (key.includes(PAIR_SEP)) continue;
        const to = nameKey(legacyPair(), key);
        if (!(to in names[kind])) names[kind][to] = names[kind][key];
        delete names[kind][key];
        moved++;
      }
    }
    if (moved) saveNamesSoon();
    return moved;
  }

  // The houses and the boxes the records that carry no number stand in. Read straight from the
  // records rather than from what is on screen: this is housekeeping, not the view, and the records of the
  // pair in question may well be the ones the view is leaving out.
  function legacyPlaces() {
    const houses = new Set(), boxIds = new Set();
    for (const [, f] of files) {
      if (f.parsed.status !== "ok" || f.parsed.box.char) continue;
      const house = houseOf(f.parsed.box).n;
      if (house !== null) houses.add(house);
      boxIds.add(f.parsed.box.id);
    }
    return { houses, boxIds };
  }
  // Whether there is any such record at all: where there is none, which pair they belong to is not asked.
  const hasLegacyRecords = () => [...files.values()].some(f => f.parsed.status === "ok" && !f.parsed.box.char);

  // Saying which pair the records that carry no number came from moves those records into it -
  // so the names written for their houses, floors and boxes are carried across with them. Without this the
  // keys stay under the pair that was named before and every one of those names vanishes from the screen
  // (a house goes back to 「家1」), which is the sort of loss that looks like a bug in the saving.
  //
  // Only the places those records stand in are touched, never the whole of the old pair: a house of the old
  // pair may also hold records that carry a number, and they stay where they are. The name is copied, not
  // moved, for that same reason - the old key may still be the right one for such a record - and a name
  // already written under the new pair wins, since someone wrote it there on purpose. Copying only ever
  // adds, so doing this again, or back again, changes nothing.
  function movePlaceNames(from, to) {
    if (!from || !to || from === to) return 0;
    const { houses, boxIds } = legacyPlaces();
    const head = key => from + PAIR_SEP + key;
    const wanted = { houses: [], floors: [], boxes: [] };
    for (const h of houses) {
      wanted.houses.push(head(String(h)));
      for (const key of Object.keys(names.floors)) if (key.startsWith(head(h + ":"))) wanted.floors.push(key);
    }
    for (const id of boxIds) wanted.boxes.push(head(id));
    let moved = 0;
    for (const kind of ["houses", "floors", "boxes"]) {
      for (const key of wanted[kind]) {
        if (!(key in names[kind])) continue;
        const dest = to + PAIR_SEP + key.slice((from + PAIR_SEP).length);
        if (dest in names[kind]) continue;
        names[kind][dest] = names[kind][key];
        moved++;
      }
    }
    if (moved) saveNamesSoon();
    return moved;
  }
  // A box's number is one shard's. Two shards may each have a box numbered 1101 and nothing
  // here can tell them apart by number alone, so a box is asked for by its world and its number together
  // (the world: worldFor).
  const boxKeyOf = CPlusHomeParse.boxKey;
  // Box names were kept by the number alone, which is one shard's: written under two pairs'
  // box 1101 they would be one name. The key now carries the pair as a house's does. An older name is
  // still read (below) until the box it was written for is in front of us, and then moved (migrateBoxNames).
  // The pair is the box's own (the pair of the record it is shown from), not its world: under
  // 全部を見る the world is the shard, and a name is written and read under a pair.
  const boxNameKey = b => nameKey(namesPairOf(b), b.id);
  // A Davies' locker is its title: its records are one house's whatever block was opened, so a name kept by
  // the block's number would come and go with the block, and it is not in 名前の設定's list of boxes either.
  const boxName = b => b.locker ? b.name : names.boxes[boxNameKey(b)] || names.boxes[b.id] || sharedBoxName(b)
    || (b.engraving ? b.name + "［" + b.engraving + "］" : b.name + " #" + b.id.slice(-4));
  // Under 全部を見る, when the box's own pair has no name for it: the name another pair of the same
  // shard gave that number - the same box - the first in the order of the pairs' names (the order the pairs are
  // offered in). sharedNameKeys: b.key -> those pairs' keys in names.boxes, made at every rebuild and empty while
  // a pair is looked at on its own, where a box is called by its own pair's name only. The names are read as
  // they are now, so one cleared since is passed over.
  let sharedNameKeys = new Map();
  function learnSharedNames() {
    sharedNameKeys = new Map();
    if (state.pair !== PAIR_ALL) return;
    const found = [];
    for (const key of Object.keys(names.boxes)) {
      const [account, shard, id, more] = key.split(PAIR_SEP);
      if (id === undefined || more !== undefined) continue;
      const b = boxById.get(boxKeyOf(shard, id));
      if (b && key !== boxNameKey(b)) found.push({ b, pair: nameKey(account, shard), key });
    }
    found.sort((x, y) => collator.compare(x.pair, y.pair));
    for (const { b, key } of found) {
      if (!sharedNameKeys.has(b.key)) sharedNameKeys.set(b.key, []);
      sharedNameKeys.get(b.key).push(key);
    }
  }
  const sharedBoxKey = b => (sharedNameKeys.get(b.key) || []).find(k => names.boxes[k]);
  const sharedBoxName = b => {
    const key = sharedBoxKey(b);
    return key ? names.boxes[key] : "";
  };
  // The old name of a box, moved to the pair of the box that actually carries that number -
  // the records say which, so nothing is guessed - and only while that box is in view. Two pairs holding
  // the same number both get the old name (a wrong guess would be worse than a name shown twice, and
  // either can be renamed). Nothing is overwritten, a name already written for the pair wins, and the old
  // key is dropped only after every box had its turn, so running this again moves nothing.
  // Under 全部を見る one shard's box of a number is one box, so there the old name goes to the pair
  // it is shown from; two shards' boxes of that number are still two, and both get it.
  function migrateBoxNames() {
    const done = new Set();
    for (const b of boxes) {
      if (!(b.id in names.boxes)) continue;
      const to = boxNameKey(b);
      if (!(to in names.boxes)) names.boxes[to] = names.boxes[b.id];
      done.add(b.id);
    }
    for (const id of done) delete names.boxes[id];
    if (done.size) saveNamesSoon();
    return done.size;
  }
  // The boxes from the one standing on the floor down to b.
  function boxChain(b) {
    const chain = [];
    const seen = new Set();
    // The parent is a number of the same world, so it is looked up with that world in front of it.
    for (let cur = b; cur && !seen.has(cur.key); cur = cur === cur.top ? null : boxById.get(boxKeyOf(cur.world, cur.parent))) {
      seen.add(cur.key);
      chain.unshift(cur);
    }
    return chain;
  }
  // House, floor, then each box from the one standing on the floor down to b.
  function path(b) {
    return [houseName(b.top.house), floorName(b.top.house, b.floor), ...boxChain(b).map(boxName)];
  }

  // ---- 「ゲームで案内」: the line the game's Home Search window reads (CPlusHomeGuide.lua parseGuide):
  //
  //   CPLUSHOME2 <area> <ids...> [<mark>] | <house name> | <what the game shows>
  //
  // the tag; the house's area from the pair's table of houses (its facet, then x from and to, then y
  // from and to), or GUIDE_NO_AREA when the table has none for it; the ids from the box on the floor down to
  // the item; then the house's name, and what the game shows. The game tells from the area whether the
  // player is in the house, and names the house by the name. A character's house number is not in the line:
  // another character may have given the same house another. The numbers here and in CPlusHomeGuide.lua must
  // agree.
  const GUIDE_TAG = "CPLUSHOME2";
  const GUIDE_NO_AREA = "-";          // CPlusHomeGuide.lua NO_AREA
  // The largest facet and coordinates the game reads an area with (CPlusHomeGuide.lua MAX_FACET, MAX_X and
  // MAX_Y, where the sizes of the maps are written).
  const GUIDE_MAX_FACET = 5;
  const GUIDE_MAX_X = 7167;
  const GUIDE_MAX_Y = 4095;
  // A house's name is cut to this many characters, ending in … (CPlusHomeGuide.lua NAME_MAX: the game puts it
  // in front of 「に入ると矢印が出ます」 on a state line of its own size). "|" in it becomes 「｜」, since the
  // game splits the line at "|".
  const GUIDE_NAME_MAX = 20;
  const GUIDE_MAX_IDS = 10;           // CPlusHomeGuide.lua MAX_IDS (the fewest, a box and the item, is its MIN_IDS)
  const GUIDE_MAX_ID = 2147483647;    // CPlusHomeGuide.lua MAX_ID
  // An item in a jewel box: one word more in front of " | " - the mark and the pages the record saw the item
  // on, joined by ".". A jewel box holds its items in a gump, fifty to a page, and has no slot that can be
  // lit, so the page is what the game's window gives instead. The mark on its own says the record has no page.
  const GUIDE_JEWEL_MARK = "J";       // CPlusHomeGuide.lua JEWEL_MARK
  // A scroll book's row: its scrolls have no object id, so the way ends at the book itself - one id where
  // the book stands on the floor, which is fewer than any other line carries. The mark says so, and
  // CPlusHomeGuide.lua takes one id only on a line that has it (BOOK_MARK / MIN_IDS_BOOK).
  const GUIDE_BOOK_MARK = "B";        // CPlusHomeGuide.lua BOOK_MARK
  // A map or a SOS in a Davies' locker - the way ends at the locker's block, as a book's at the book, and the
  // game says to open the locker rather than the book (CPlusHomeGuide.lua LOCKER_MARK).
  const GUIDE_LOCKER_MARK = "L";      // CPlusHomeGuide.lua LOCKER_MARK
  const GUIDE_MAX_PAGE = 9999;        // CPlusHomeGuide.lua MAX_PAGE
  const GUIDE_MAX_PAGES = 3;          // CPlusHomeGuide.lua MAX_PAGES
  // An id as the game takes it: a whole number, as long as GUIDE_MAX_ID at most (CPlusHomeGuide.lua works its
  // MAX_DIGITS out from MAX_ID the same way), and no larger.
  const GUIDE_ID = new RegExp("^[1-9]\\d{0," + (String(GUIDE_MAX_ID).length - 1) + "}$");
  // What the game shows is cut to this many characters. Its field in the game window (CPlusHomeGuide.xml
  // $parentTarget) is 412 wide and 3 lines high: at about 14 px a character, about 29 a line, 87 in all - room
  // for its prefix 「案内先: 」 and 80 (the character width is not measured).
  const GUIDE_TEXT_MAX = 80;
  // The whole line fits the box it is pasted into (CPlusHomeGuide.xml $parentInput maxchars): where what comes
  // before what the game shows leaves less than GUIDE_TEXT_MAX, what it shows is cut shorter.
  const GUIDE_LINE_MAX = 256;
  const GUIDE_COPIED = "コピーしました。ゲームの『家検索』で貼り付けてください";

  // The pages to show for an item, in order and without repeats: the ones the game takes, at most
  // GUIDE_MAX_PAGES of them. Empty for an item that is not in a jewel box, and for one whose record has no
  // page for it (records of older versions, and a page the gump did not give).
  const guidePages = it => !it.boxRef.jewel ? []
    : [...new Set(it.pages)].filter(p => Number.isInteger(p) && p >= 1 && p <= GUIDE_MAX_PAGE)
      .sort((a, b) => a - b).slice(0, GUIDE_MAX_PAGES);

  // Text no longer than max, cut to it with … at the end when it is longer.
  const clip = (text, max) => (text.length > max ? text.slice(0, max - 1) + "…" : text);

  // What the game shows for a row inside a book: the way to the book, then what to look for in it. The
  // player has to find it by hand - the game's window cannot light a row of a book's gump - so what to look
  // for is kept whole the longest, and the way to the book is dropped before it is.
  function inBookShown(it, tail, max) {
    const whole = [...path(it.boxRef), tail].join(" → ");
    if (whole.length <= max) return whole;
    const short = [boxName(it.boxRef), tail].join(" → ");
    if (short.length <= max) return short;
    return tail.slice(0, max - 1) + "…";
  }
  // A scroll's row: the skill, the grade and how many.
  function bookShown(it, max) {
    return inBookShown(it, "本を開いて『" + it.name + "』" + it.book.tier + " " + it.book.count + "本 を探す", max);
  }
  // A locker's row: the page it is on, then what it is and where it points.
  const LOCKER_NO_BLOCK = "ロッカーのどのブロックを開いたか記録に無いので、案内できません。ロッカーを開き直して閉じると記録します";
  function lockerShown(it, max) {
    const l = it.locker;
    const open = l.page !== null ? "ロッカーを開いて " + l.page + " ページ目の" : "ロッカーを開いて";
    return inBookShown(it, open + "『" + it.name + "』" + [l.facet, l.status, l.coords].filter(Boolean).join(" ") + " を探す", max);
  }

  // { text } to paste in the game, or { error } saying why there is none.
  function guideLine(it) {
    const chain = boxChain(it.boxRef);
    // A locker's row is guided to the block the record confirmed as opened; a record that could not say
    // which (box 0) has no way to it.
    if (it.locker && !it.boxRef.locker.confirmed) return { error: LOCKER_NO_BLOCK };
    // A scroll and a locker's map or SOS have no object id: the way ends at their book or locker.
    const inBook = !!(it.book || it.locker);
    const ids = chain.map(b => b.id).concat(inBook ? [] : [it.id]);
    if (ids.length > GUIDE_MAX_IDS) return { error: "道筋が長すぎて案内できません（入れ物が " + (ids.length - 1) + " 段）" };
    const badId = ids.find(id => !GUIDE_ID.test(id) || Number(id) > GUIDE_MAX_ID);
    if (badId !== undefined) return { error: "番号 " + badId + " は案内の文字にできません" };
    // The house as the box on the floor stands in it: the area of the house of the table it was found in
    // (houseOf) - none when the record's own number decided, since another building may stand in the table
    // under that number - and its name under that box's own pair.
    const top = chain[0];
    const area = top.houseArea;
    if (area && (area.facet > GUIDE_MAX_FACET || area.maxX > GUIDE_MAX_X || area.maxY > GUIDE_MAX_Y)) {
      return { error: "家の範囲（" + areaText(area) + "）は案内の文字にできません" };
    }
    const name = clip(houseName(top.house, namesPairOf(top)).replace(/\|/g, "｜").trim(), GUIDE_NAME_MAX);
    const mark = it.locker ? [GUIDE_LOCKER_MARK] : inBook ? [GUIDE_BOOK_MARK] : it.boxRef.jewel ? [GUIDE_JEWEL_MARK + guidePages(it).join(".")] : [];
    const head = [GUIDE_TAG, area ? areaText(area) : GUIDE_NO_AREA, ...ids, ...mark].join(" ") + " | " + name + " | ";
    const max = Math.min(GUIDE_TEXT_MAX, GUIDE_LINE_MAX - head.length);
    const shown = it.book ? bookShown(it, max) : it.locker ? lockerShown(it, max)
      : clip([...path(it.boxRef), it.name].join(" → "), max);
    return { text: head + shown };
  }

  // Copies the line; when that cannot be done, shows it where it can be selected and copied by hand.
  async function copyGuide(it) {
    const line = guideLine(it);
    if (line.error) { showGuideBar(line.error, null); return; }
    try {
      if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") throw new Error("クリップボードを使えません");
      await navigator.clipboard.writeText(line.text);
    } catch (e) {
      showGuideBar("コピーできませんでした（" + (e && e.message || e) + "）。下の文字を選んでコピーし、ゲームの『家検索』で貼り付けてください", line.text);
      return;
    }
    showGuideBar("", null);
    notice(GUIDE_COPIED);
  }
  function showGuideBar(message, text) {
    const bar = $("guideCopy");
    bar.replaceChildren(message);
    if (text) {
      const field = el("input");
      field.type = "text";
      field.readOnly = true;
      field.value = text;
      field.addEventListener("focus", () => field.select());
      bar.append(" ", field);
    }
    bar.hidden = !message;
    measureHeader();
  }

  // 「範囲をゲームへコピー」: the line the game's Paste the areas window reads (CPlusHomeArea.lua parseAreas):
  //
  //   CPLUSAREA1 <n> <facet> <minX> <maxX> <minY> <maxY> ...
  //
  // the tag, then six numbers for each house of a pair's table: its number, then its area as the table holds it,
  // smallest number first. Pasted on a character, each becomes that character's house under the page's own number
  // (CPlusHomeRecord.pasteAreas): a new character need not add corners again, and its numbers are the page's. The
  // numbers here and in CPlusHomeArea.lua must agree with each other, with CPlusHomeRecord.lua's MAX_HOUSES and, for
  // the largest facet and coordinates, with CPlusHomeGuide.lua's, which GUIDE_MAX_* are.
  const AREA_TAG = "CPLUSAREA1";
  const AREA_MAX_HOUSES = 9;          // CPlusHomeArea.lua MAX_HOUSES: the houses a character can register
  const AREA_PASTE = "ゲームで家の記録アイコンを右クリック →『範囲を貼る』に貼ってください";

  // House numbers as the page says them: a run of three or more as 「1〜4」, the rest one by one - 「1〜3・5」.
  function numbersText(ns) {
    const parts = [];
    for (let i = 0; i < ns.length;) {
      let j = i;
      while (j + 1 < ns.length && ns[j + 1] === ns[j] + 1) j++;
      if (j - i >= 2) parts.push(ns[i] + "〜" + ns[j]);
      else for (let k = i; k <= j; k++) parts.push(String(ns[k]));
      i = j + 1;
    }
    return parts.join("・");
  }

  // { text, houses, left } for a pair - the line, the numbers in it, and what was left out of it and why ("" for
  // nothing) - or { error } when no house of the pair can go into it. Left out, and said rather than dropped: a
  // number past the houses a character can register, and an area past what the game reads.
  function areaLine(pair) {
    const houses = tableHouses(pair).sort((a, b) => a.n - b.n);
    const numberPast = houses.filter(h => h.n > AREA_MAX_HOUSES);
    const areaPast = houses.filter(h => h.n <= AREA_MAX_HOUSES && (h.facet > GUIDE_MAX_FACET || h.maxX > GUIDE_MAX_X || h.maxY > GUIDE_MAX_Y));
    const kept = houses.filter(h => !numberPast.includes(h) && !areaPast.includes(h));
    const left = [];
    if (numberPast.length) left.push("家 " + numbersText(numberPast.map(h => h.n)) + " は入れていません（ゲームは 1 キャラクター " + AREA_MAX_HOUSES + " 軒まで）");
    if (areaPast.length) left.push("家 " + numbersText(areaPast.map(h => h.n)) + " は範囲がゲームの上限を超えるので入れていません（" + areaPast.map(areaText).join("・") + "）");
    if (!kept.length) return { error: assignmentLabel(pair) + " にはゲームへ渡せる家がありません。" + left.join("。") };
    return { text: [AREA_TAG, ...kept.map(h => h.n + " " + areaText(h))].join(" "), houses: kept.map(h => h.n), left: left.join("。") };
  }

  // Copies a pair's line; when that cannot be done, shows it where it can be selected and copied by hand, as the
  // guide's line is. What was left out of the line is said in the same bar.
  async function copyAreas(pair) {
    const line = areaLine(pair);
    if (line.error) { showGuideBar(line.error, null); return; }
    try {
      if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") throw new Error("クリップボードを使えません");
      await navigator.clipboard.writeText(line.text);
    } catch (e) {
      showGuideBar("コピーできませんでした（" + (e && e.message || e) + "）。下の文字を選んでコピーし、" + AREA_PASTE + (line.left ? "。" + line.left : ""), line.text);
      return;
    }
    showGuideBar(line.left, null);
    notice("家 " + numbersText(line.houses) + " の範囲をコピーしました。" + AREA_PASTE);
  }

  // ---- kinds and parts, read from the base name (and the name)
  // リング only at the end: リング チュニック is armor, not a ring.
  const JEWEL = /指輪|ブレスレット|イヤリング|ネックレス|アンクレット|リング$/;
  const SHIELD = /シールド|バックラー|カイト/;
  // Parts follow the slot list of the vendor search's 装備 dropdown. The first match wins: リング チュニック
  // is 胴 before 指輪 is tried, イヤリング before 指輪. No チェスト: ウッドチェスト and メタルチェスト are boxes.
  const PARTS = [
    ["頭", /ヘルム|ヘルメット|マスク|キャップ|ハット|帽子|フード|クラウン|サークレット|バンダナ|トリコルヌ|兜/],
    ["首", /ネック|ゴルゲット|首当て/],
    ["胴", /チュニック|アーマー|ブレストプレート|シャツ|胸当て|ダブレット|サーコート/],
    ["腕", /アーム|スリーブ|広袖/],
    ["手", /グローブ|ガントレット|手袋|手甲/],
    ["脚", /レッグ|レギンス|キルト|スカート|パンツ|袴/],
    ["足", /ブーツ|靴|サンダル|足袋/],
    ["腰", /ベルト|エプロン|サッシュ/],
    ["背中", /クローク|マント|矢筒/],
    ["ローブ", /ローブ|ドレス|シュラウド/],
    ["盾", SHIELD],
    ["イヤリング", /イヤリング/],
    ["指輪", /指輪|リング$/],
    ["ブレスレット", /ブレスレット/],
    ["タリスマン", /タリスマン/],
  ];
  const TID_WEAPON_DAMAGE = 1061168; // weapon damage: only weapons carry it
  const TID_PHYSICAL_RESIST = 1060448; // armor carries it
  const EQUIP = [
    { value: "武器", test: it => it.kind === "武器" },
    { value: "防具（全部）", test: it => it.kind === "防具" || it.kind === "盾" },
    { value: "装飾品（全部）", test: it => it.kind === "装飾品" },
    ...PARTS.map(([name]) => ({ value: name, test: it => it.part === name })),
  ];
  const EQUIP_BY_VALUE = new Map(EQUIP.map(e => [e.value, e]));

  function kindOf(it) {
    const has = tid => it.props.some(p => p.t === tid);
    if (JEWEL.test(it.base) || JEWEL.test(it.name)) return "装飾品";
    if (has(TID_WEAPON_DAMAGE)) return "武器";
    if (SHIELD.test(it.base) || SHIELD.test(it.name)) return "盾";
    if (has(TID_PHYSICAL_RESIST)) return "防具";
    return "その他";
  }

  // ---- search entries: one per vendor search entry (by item-line tids) or per recorded wording (特効, スキル,
  // キラー, プロテクト). Every line except the item's name line counts. Numbers in a wording become ○.
  const keyOf = x => x.replace(/\d+/g, "○");
  const labelOf = key => key.replace(/^(追加効果|特効|スキル|必要スキル)[:：] ?/, "").replace(/\s*[:：]?\s*[+-]?○(\.○)?.*$/, "").trim();

  function buildEntries() {
    entries = new Map();
    const byTid = new Map();
    const wordingSections = [];
    const addEntry = (key, section) => {
      const e = { key, group: section.group, label: "", words: new Map(), valued: false, count: 0 };
      entries.set(key, e);
      section.entries.push(e);
      return e;
    };
    // A group is one dropdown; its sections become headings inside it (only その他 has more than one).
    groups = [MISC_GROUP, ...SEARCH_GROUPS].map(g => ({
      name: g.name,
      sections: (g.sections || [g]).map(src => {
        const section = { group: g.name, label: g.sections ? src.label : "", wording: src.wording || null, entries: [] };
        for (const tids of src.tids || []) {
          const e = addEntry("t:" + tids.join("+"), section);
          for (const t of tids) byTid.set(t, e);
        }
        if (section.wording) wordingSections.push(section);
        return section;
      }),
    }));
    for (const it of items) {
      it.hits = new Map();
      it.props.forEach((p, i) => {
        if (i === 0) return; // the name line names the item; it is not one of its properties
        const key = keyOf(p.x);
        let e = byTid.get(p.t);
        if (!e) {
          const section = wordingSections.find(s => s.wording.test(key));
          if (!section) return;
          e = entries.get("w:" + key) || addEntry("w:" + key, section);
        }
        if (!it.hits.has(e.key)) { it.hits.set(e.key, []); e.count++; }
        it.hits.get(e.key).push(p);
        e.words.set(key, (e.words.get(key) || 0) + 1);
        if (p.v.length) e.valued = true;
      });
    }
    for (const e of entries.values()) {
      const top = [...e.words].sort((a, b) => b[1] - a[1])[0];
      e.label = top ? labelOf(top[0]) : "";
    }
    for (const s of wordingSections) s.entries.sort((a, b) => b.count - a.count);
  }

  // Items shown under the same name in the same box - its key, as two worlds can each have a box of one
  // number - cannot be told apart on their cards. Each of them gets
  // twin = { k, n }: its place among them by item id, and how many there are. By item id, so that the
  // numbers stay put when records come and go. Ids are digit strings without leading zeros, so the shorter
  // one is the smaller, and the same length compares as text (no Number: nothing is lost to precision).
  const byItemId = (a, b) => (a.id.length - b.id.length) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  function numberTwins() {
    const sameName = new Map();
    for (const it of items) {
      // A scroll's row says its grade and how many on the card, so two rows of one skill are told apart; a
      // locker's row has no id to number it by, and its facet, status, coordinates and page are on its card.
      if (it.book || it.locker) continue;
      const key = it.boxKey + "\n" + it.name;
      if (!sameName.has(key)) sameName.set(key, []);
      sameName.get(key).push(it);
    }
    for (const group of sameName.values()) {
      if (group.length < 2) continue;
      group.sort(byItemId);
      group.forEach((it, i) => { it.twin = { k: i + 1, n: group.length }; });
    }
  }

  // 古い記録: another recording of a box that has been recorded again since.
  //
  // Grouped the way a pair's reading groups them - the pair and the box's number - and ordered the
  // way the reading orders them: the closing time, then the file's own time, then its name. So "the
  // newest" here is the one that pair's view is showing. Everything else in the group is a candidate.
  // (全部を見る groups by the shard and shows the newest of every account's records. What is offered
  // is still each pair's own: another account's record of the box is not an older record of it - deleting it
  // would take the box from that pair's view - and tidyChecker reads both ways.)
  //
  // Being a candidate is not permission to delete: a jewel box is read from several of its records at
  // once, so an older one can still be holding items the newest does not mention. What decides
  // is tidyChecker below, which reads everything a second time without them and compares ( tidySplit asks it ).
  // A Davies' locker is shown from the record CPlusHomeParse.lockerChosen picks, which is not always the
  // newest (a reading to the end, when nothing has changed since): what is kept is that one, and every other
  // record of the locker is a candidate - the newer ones that changed nothing among them.
  // A record whose number is not assigned to a pair is never a candidate: whose account it is cannot be
  // known, and the records of every such number fall into one group, so another account's record of the box would
  // look like an older one of it. It can be tidied once it is assigned. A record
  // with no number at all belongs to the pair chosen for such records in 名前の設定, and is grouped with it;
  // until one is chosen it is unassigned, as above.
  function olderRecords(now) {
    const byBox = new Map();
    for (const [name, f] of files) {
      if (f.parsed.status !== "ok") continue;
      const pair = namesPairOf(f.parsed.box);
      if (pair === PAIR_UNASSIGNED) continue;
      // A Davies' locker's records are grouped by their house, as the reading groups them (CPlusHomeParse.lockerKey,
      // with the box housedBox gives the reading too): an older record of the house's locker is a candidate
      // whichever block it was opened from.
      const key = f.parsed.box.locker ? CPlusHomeParse.lockerKey(pair, housedBox(f.parsed.box)) : CPlusHomeParse.boxKey(pair, f.parsed.box.id);
      if (!byBox.has(key)) byBox.set(key, []);
      byBox.get(key).push({ name, mtime: f.mtime, size: f.size, closed: f.parsed.box.closed, parsed: f.parsed, group: key });
    }
    const older = [];
    for (const recs of byBox.values()) {
      if (recs.length < 2) continue;
      recs.sort((a, b) => (a.closed < b.closed ? 1 : a.closed > b.closed ? -1 : 0) ||
        (b.mtime - a.mtime) || (a.name < b.name ? 1 : a.name > b.name ? -1 : 0));
      const kept = CPlusHomeParse.chosenOf(recs);
      for (const r of recs) if (r !== kept && now - r.mtime >= WRITING_MS) older.push(r);
    }
    return older;
  }

  // Everything the reading gives the page, line by line, as text. A box's top is written as its key
  // ( boxes point at each other, and what matters is which box it points at ).
  // **What is compared is what can be found, never how many records it took to find it.**
  //
  // Every deletion takes a record away, so any tally of records always moves. Counting those as a change
  // would make the check stop everything: the only line that differs can be one character's tally
  // ( 9 -> 8 ), with the name, the boxes, the items and the floors identical - and the answer would be
  // 「何も消していません」, every time, for ever. A tally going down is the purpose of the
  // operation, not a loss.
  //
  // So two things are left out here: a character's records ( and the closed time that named it, which is
  // not on the screen at all ) and a book's records ( how many of its readings were laid over each
  // other ). Everything that can be found stays in: the name of a character not yet assigned, every box,
  // every item, the floors, the skills of a book and all the counts of THINGS - 品の数 ( jewel.stacked ),
  // 頁 ( covered ), 直下 ( direct ) - which are not tallies of records and must still stop the deletion if
  // they move.
  function readingLines(combined, records, unlearned) {
    const lines = [];
    // The assignment table is on the screen too, and what it says a number is called comes from
    // the newest record carrying that number - so deleting an older one can change it without changing a
    // single box or item. Only the number and the name: see above for why not the tally.
    // Only the numbers not assigned to a pair. An assigned number's row may change or go with its
    // records and nothing is lost: the assignment is kept in the names file, not in the records, and the row
    // is back the next time that character opens a box. Comparing it would stop the tidying for good
    // where every record of one character has become an older one. An unassigned number's
    // row is the only thing the player can assign it from, so losing that still stops everything. Until the
    // names are read no number is assigned (names.chars is empty), and every number is compared.
    for (const [id, seen] of [...charsFrom(records)].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
      if (assignedPair(id) !== null) continue;
      lines.push("番号 " + id + "\t" + JSON.stringify({ id: seen.id, name: seen.name }));
    }
    const keyOf = b => b.key;
    for (const b of [...combined.boxes].sort((a, b) => (keyOf(a) < keyOf(b) ? -1 : keyOf(a) > keyOf(b) ? 1 : 0))) {
      const shown = Object.assign({}, b, { top: b.top ? b.top.key : null });
      // A book's records is the other tally of records ( CPlusHomeParse stackedBook ). Its skills, grades,
      // counts and whether it was read to the end are all still compared.
      if (shown.book) shown.book = Object.assign({}, shown.book, { records: undefined });
      lines.push("箱 " + boxName(b) + "\t" + JSON.stringify(shown));
    }
    for (const it of [...combined.items].sort((a, b) => (itemKey(a) < itemKey(b) ? -1 : itemKey(a) > itemKey(b) ? 1 : 0))) {
      lines.push("品 " + it.name + "\t" + JSON.stringify(it));
    }
    for (const [key, floors] of [...combined.floors].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
      lines.push("階 " + key.split(CPlusHomeParse.NOT_HERE).pop() + "\t" + JSON.stringify(floors));
    }
    // The bar that says which areas were not learned is on the screen as well.
    for (const line of unlearned) lines.push("家の範囲の帯\t" + line);
    return lines;
  }

  // The check: read every record again without the ones to be deleted, and compare
  // what the page would draw. Anything at all that differs - a box, an item, a number, a floor - and
  // nothing is deleted. Returns null when the two readings are the same, or what first differed.
  //
  // Both readings are made here, from the same records, rather than comparing with what is on screen:
  // deleting has to be safe for every way of looking, not only the one on screen.
  //
  // Every way of looking is two readings: each pair's (the records put together by their pair) and
  // 全部を見る's (by their shard: worldFor), which is not the pairs' readings added up - a jewel box's
  // older records are laid under the newest across the accounts, so an older record of one pair can be where that
  // stops, and deleting it lays another account's still older record under it with no pair's reading changing.
  // What is offered is still one pair's older records (olderRecords); both readings are compared,
  // and a change in either stops everything.
  //
  // Each reading decides every house again from its own records (asIfDeleted): a record's
  // house can hang on other records - whether its area is split is counted from the old records
  // standing in it - so houses decided once, from everything, and then carried over to what is left would
  // not show what deleting does (tidying away the old record that split an area can move a box into the other
  // house).
  //
  // tidyChecker reads the page as it is once, and returns the check for any number of sets to delete ( tidySplit asks
  // it of many ); deleting nothing changes nothing.
  function tidyChecker() {
    const now = asIfDeleted(new Set());
    const ways = [false, true].map(all => {
      const world = worldFor(all);
      return { world, before: readingLines(CPlusHomeParse.combine(now.readable, world), now.readable, now.unlearned) };
    });
    return drop => {
      if (!drop.size) return null;
      const left = asIfDeleted(drop);
      for (const { world, before } of ways) {
        const after = readingLines(CPlusHomeParse.combine(left.readable, world), left.readable, left.unlearned);
        if (before.length === after.length && before.every((line, i) => line === after[i])) continue;
        for (let i = 0; i < Math.max(before.length, after.length); i++) {
          if (before[i] === after[i]) continue;
          const which = (before[i] || after[i] || "").split("\t")[0];
          return { at: which, gone: after[i] === undefined || !after.includes(before[i]) };
        }
        return { at: "（どこが違うのか分かりませんでした）", gone: true };
      }
      return null;
    };
  }

  // The character numbers the records carry, with the newest name for each: the table in
  // 名前の設定. Asked as a question about a set of records, so that the tidying check can ask it of the
  // records without the ones it would delete - the name in that table comes from whichever record is the
  // newest, so deleting an older one can change what it says.
  function charsFrom(records) {
    const seenBy = new Map();
    for (const rec of records) {
      const who = rec.parsed.box.char;
      if (!who) continue;
      const seen = seenBy.get(who.id) || { id: who.id, name: "", records: 0, last: "" };
      seen.records++;
      // The newest record of the number, named or not - which of a character's numbers is its own now.
      if ((rec.parsed.box.closed || "") > seen.last) seen.last = rec.parsed.box.closed;
      // The newest name wins, and a record with only a number does not blank one that has a name.
      if (who.name && (!seen.name || rec.parsed.box.closed > (seen.closed || ""))) {
        seen.name = who.name;
        seen.closed = rec.parsed.box.closed;
      }
      seenBy.set(who.id, seen);
    }
    return seenBy;
  }

  // ---- everything that follows from the records

  // The records that could be read, each with its house as houseOf decides it: what the page is
  // built from and what the tidying check reads, so that neither can see a record's own number where the
  // other sees the table's. houseArea is the house of the table it was found in, or null.
  function readableRecords() {
    return withSplitMemo(() => [...recordsNow()].filter(([, f]) => f.parsed.status === "ok").map(([name, f]) => ({ name, mtime: f.mtime,
      parsed: Object.assign({}, f.parsed, { box: housedBox(f.parsed.box) }) })));
  }
  // A record's box with its house as houseOf decides it: house, and houseArea, the house of the table it was found in
  // (or null). What the reading is made of, and what 整理削除 keys a locker by (CPlusHomeParse.lockerKey), so that
  // the two cannot put a locker's records together differently.
  function housedBox(box) {
    const at = houseOf(box);
    return Object.assign({}, box, { house: at.n, houseArea: at.area });
  }

  // What the page would show were the records in drop deleted: the records that would be left,
  // each house decided again from them (whether an area is split is counted from them too), and the bar of the
  // areas not learned. drop empty: what it shows now, made the same way. The table is taken as it is.
  function asIfDeleted(drop) {
    recordsLeft = new Map([...files].filter(([name]) => !drop.has(name)));
    try {
      const readable = readableRecords();
      return { readable, unlearned: unlearnedLines(readable) };
    } finally {
      recordsLeft = null;
    }
  }

  function rebuild() {
    learnHouses();
    const readable = readableRecords();
    // Which records this view is made of. Everything below - the list, the search, the counts
    // in the dropdowns, the houses and floors, the two tables of what is not recorded to the end, the
    // line for the game - is built from these, so one place decides what a pair shows and nothing can
    // leak in behind it.
    charsSeen = charsFrom(readable);
    const records = state.pair === PAIR_ALL ? readable
      : readable.filter(rec => pairOfBox(rec.parsed.box) === state.pair);
    // Which world each record belongs to, handed to the parser: without it two shards' box of
    // the same number would be put together and the older one's contents would vanish from 全部を見る
    // without a word. An unassigned record is its own world (PAIR_UNASSIGNED), not everyone's.
    // The world is the pair while a pair is looked at, and the shard under 全部を見る (worldFor):
    // there two accounts' records of one shard's box are that one box, shown from the newest of them.
    const combined = CPlusHomeParse.combine(records, worldFor(state.pair === PAIR_ALL));
    boxes = combined.boxes;
    floors = combined.floors;
    boxById = new Map(boxes.map(b => [b.key, b]));
    migrateBoxNames();
    learnSharedNames();
    items = combined.items;
    for (const b of boxes) if (b.book) items = items.concat(bookRows(b));
    settleSkillGroups(items.filter(it => it.book));
    for (const b of boxes) if (b.locker) items = items.concat(lockerRows(b));
    for (const it of items) {
      it.boxRef = boxById.get(it.boxKey);
      // A scroll's row has no property lines: what it is comes from the book's own record. It is searched
      // by the skill, the grade and how many, so 「棍術」「Legendary」「+5.0」 all find it.
      if (it.book) {
        it.kind = "";
        it.part = "";
        it.search = (it.name + " " + it.book.tier + " " + it.book.count + "本").toLowerCase();
        it.lineText = "";
        continue;
      }
      // A locker's row neither. It is searched by the words on its card, so 「匠の」「トランメル」「未解読」
      // 「25N」「SOS」 all find it.
      if (it.locker) {
        it.kind = "";
        it.part = "";
        it.search = lockerWords(it).join(" ").toLowerCase();
        it.lineText = "";
        continue;
      }
      // What the armour refinement cabinet's filter goes by.
      it.refine = refineWords(it);
      it.kind = kindOf(it);
      const part = it.kind !== "武器" && it.base ? PARTS.find(([, re]) => re.test(it.base)) : null;
      it.part = part ? part[0] : "";
      it.search = (it.name + " " + it.base).toLowerCase();
      it.lineText = it.props.slice(1).map(p => p.x).join("\n").toLowerCase();
    }
    numberTwins();
    buildEntries();

    const y = window.scrollY || 0;
    drawSummary();
    drawPairs();
    drawUnassigned();
    drawUnlearned(readable);
    drawAssign();
    drawPlaces();
    drawKinds();
    drawPickers();
    drawConds();
    run();
    drawTodo();
    drawNames();
    if ((window.scrollY || 0) !== y) window.scrollTo(0, y);
  }

  // ---- who the records belong to

  // The accounts, shards and characters of this PC. Read once at the start and again whenever the
  // 名前の設定 tab is opened, so that a character made since is there without the page being reloaded.
  async function loadChars() {
    let res;
    try {
      res = await ask(API_CHARS);
    } catch (e) {
      if (!(e && e.lost)) throw e;
      return false;
    }
    if (!res.ok) return false;
    try {
      charTree = await res.json();
    } catch (e) {
      return false;
    }
    return true;
  }

  // Every pair this PC has, in the order /api/chars gives them.
  function pcPairs() {
    const out = [];
    for (const account of charTree.accounts || []) {
      if (account.spare) continue;
      for (const shard of account.shards || []) {
        if (shard.spare) continue;
        out.push(pairOfAssignment(account.name + PAIR_SEP + shard.name));
      }
    }
    return out;
  }

  // Which characters could be the one a record names.
  //
  // A record's name carries the character's titles, and they come before the name and after it
  // (「The Glorious Lady Alice」), so the match is on the words: a character is a candidate when its own
  // name stands in the record's name as a word, or as a run of words for a name that has a space in it.
  // The longest match is offered first - a shard with both 「Ali」 and 「Alice」 would otherwise answer
  // for either - and **a spare is never a candidate**: 「Alice - コピー」 and 「Bob.bak」 are copies of a
  // character's file, not characters.
  function candidatesFor(recordName) {
    const words = String(recordName || "").toLowerCase().split(/\s+/).filter(Boolean);
    const found = [];
    for (const account of charTree.accounts || []) {
      if (account.spare) continue;
      for (const shard of account.shards || []) {
        if (shard.spare) continue;
        for (const character of shard.characters || []) {
          if (character.spare) continue;
          const own = String(character.name || "").toLowerCase().split(/\s+/).filter(Boolean);
          if (!own.length) continue;
          let at = -1;
          for (let i = 0; i + own.length <= words.length && at < 0; i++) {
            if (own.every((w, k) => words[i + k] === w)) at = i;
          }
          if (at < 0) continue;
          found.push({ account: account.name, shard: shard.name, character: character.name });
        }
      }
    }
    return found.sort((a, b) => b.character.length - a.character.length ||
      collator.compare(a.account + a.shard, b.account + b.shard));
  }

  // The value kept for an assignment, and the pair it names.
  const assignmentValue = c => [c.account, c.shard, c.character].join(PAIR_SEP);
  const assignmentLabel = value => value.split(PAIR_SEP).join(" ／ ");

  // ---- the scrolls in a scroll book, and the armour refinement cabinet's agents
  // A book's scrolls are shown in a gump of their own and have no object id, so the record has no item
  // line for them: each is a row of the page's own (bookRows).
  // What the armour refinement cabinet's filter goes by, as the gump writes it (measured on the record
  // of a whole cabinet): the grade in the brackets that end the name line
  // (「ハードワックス (究極)」: tid 1153966), and the words after the colon of the bonus line (1154124 「ボーナス種別: 抵抗強化」) and of
  // the armour line (1154002 「防具種別: プレート」). Each is null where the item has no such line; an item with none of the
  // three is no refining agent, and has null (the filter offers values from the agents alone - its own).
  const REFINE_NAME_TID = 1153966;
  const REFINE_BONUS_TID = 1154124;
  const REFINE_ARMOR_TID = 1154002;
  const afterColon = p => { const at = p ? p.x.search(/[:：]/) : -1; return at < 0 ? null : p.x.slice(at + 1).trim() || null; };
  function refineWords(it) {
    const name = it.props[0];
    const grade = name && name.t === REFINE_NAME_TID ? /[(（]\s*([^()（）]+?)\s*[)）]\s*$/.exec(name.x) : null;
    const words = { rank: grade ? grade[1] : null,
      bonus: afterColon(it.props.find(p => p.t === REFINE_BONUS_TID)),
      armor: afterColon(it.props.find(p => p.t === REFINE_ARMOR_TID)) };
    return words.rank === null && words.bonus === null && words.armor === null ? null : words;
  }

  // A grade as the page shows it: the record keeps the gump's own word, which ends in ":" in the
  // transcendence book (「+5.0:」) and is padded in the power book (「Exalted   (110)」, spaces already
  // squeezed by the parser). Searching still finds either, since the search text holds this.
  const tierText = t => String(t && t.text || "").replace(/\s*[:：]\s*$/, "");
  // One row for each skill and grade the book holds at least one of. A grade it holds none of is not a
  // row: the record writes a count for every grade, 0 included, and 0 of something is not something the
  // player owns. A count that could not be read ("-", null here) is not a row either.
  function bookRows(b) {
    const rows = [];
    for (const s of b.book.skills) {
      b.book.tiers.forEach((tier, i) => {
        const count = s.counts[i];
        if (typeof count !== "number" || count < 1) return;
        rows.push({
          id: b.id + "/" + s.tid + "/" + i,     // the page's own key: these scrolls have no id of their own
          qty: count,
          name: s.text, base: "", props: [], pages: [],
          box: b.id, boxKey: b.key, house: b.top.house, floor: b.floor,
          // From an older record of the book: the newest reading never reached this skill.
          from: s.from || null,
          book: { kind: b.book.kind, skill: s.tid, tier: tierText(tier), tierTid: tier.tid, count, group: s.group || null },
        });
      });
    }
    return rows;
  }
  // One skill, one group: every scroll row of a skill takes the group the first row with one carries. The module
  // writes the same group for a skill in every book, but a record of an older version has none, and without this
  // a skill's scrolls in such a book would stand under 分類なし while the same skill's button is under its group.
  function settleSkillGroups(rows) {
    const groupOf = new Map();
    for (const it of rows) if (it.book.group && !groupOf.has(it.book.skill)) groupOf.set(it.book.skill, it.book.group);
    for (const it of rows) it.book.group = groupOf.get(it.book.skill) || null;
  }
  // A power scroll's grade as its number, from the words of its grade (「Legendary (120)」): null for a scroll
  // whose grade has no number in brackets (a transcendence scroll's 「+5.0」).
  const powerRank = it => { const m = /\((\d+)\)\s*$/.exec(it.book.tier); return m ? Number(m[1]) : null; };

  // ---- the maps and SOS in a Davies' locker
  // A map or a SOS in a locker has no object id, so the record has no item line for it: it is a row of the page's own,
  // one a row of the locker's gump. The name on its card is what it is - a map's 「〜の」 and grade (「匠の 貯蔵品」), a
  // SOS's 「SOS」 - and the facet, the status and the coordinates stand beside it. A row the Lua could not read as
  // either is shown by the words of its labels, marked as such.
  const LOCKER_ODD = "形の分からない行";
  const LOCKER_KIND_TEXT = new Map([["map", "地図"], ["sos", "SOS"]]);
  function lockerRows(b) {
    return b.locker.rows.map((r, i) => ({
      id: "locker/" + i,   // the page's own key (with the locker's own key: itemKey): a row has no id of its own
      qty: 1,
      name: r.kind === "odd" ? r.texts.filter(Boolean).join(" / ") : r.kind === "sos" ? "SOS" : [r.prefix, r.tier].filter(Boolean).join(" "),
      base: "", props: [], pages: [],
      box: b.id, boxKey: b.key, house: b.top.house, floor: b.floor,
      from: null,
      locker: r,
    }));
  }
  // The words on a locker row's card, and what it is found by: its name, its facet, status and coordinates (a row of no
  // shape: its labels' words), and the locker's title.
  const lockerWords = it => [it.name, it.locker.facet, it.locker.status, it.locker.coords, ...(it.locker.texts || []), it.boxRef.name]
    .filter(Boolean);
  // The order the filter's buttons stand in, by their words as the game's gump writes them: a value the records hold
  // that is not here - the grade 埋蔵品's tid is not measured, nor a decoded map's status - stands after these, in the
  // order of its tid. By the words rather than the tids, so that one whose tid is not known yet still goes in its
  // place.
  const LOCKER_ORDER = {
    facet: ["トランメル", "フェルッカ", "イルシェナー", "マラス", "徳之諸島", "テルマー", "T / F"],
    prefix: ["匠の", "暗殺者の", "メイジの", "戦士の", "レンジャーの"],
    tier: ["へそくり", "配給品", "貯蔵品", "埋蔵品"],
    status: ["未解読", "未開封", "開封済"],
  };
  // The values a row of the filter offers, from the rows given: [tid, words], in LOCKER_ORDER's order.
  function lockerValues(rows, key) {
    const found = new Map();
    for (const it of rows) {
      const tid = it.locker[key + "Tid"];
      if (tid !== null && tid !== undefined && !found.has(tid)) found.set(tid, it.locker[key]);
    }
    const place = words => { const at = LOCKER_ORDER[key].indexOf(words); return at < 0 ? LOCKER_ORDER[key].length : at; };
    return [...found].sort((a, b) => place(a[1]) - place(b[1]) || a[0] - b[0]);
  }

  // ---- controls: which pair is being looked at

  // The pairs offered: 全部を見る, every pair the records come to, and the one being looked at even when
  // nothing of it is there yet (a pair chosen on purpose does not disappear under the player). A pair of
  // this PC with no records at all is left out - the list would otherwise be twenty shards long for an
  // account that plays on one.
  function pairsWithRecords() {
    const found = new Map();
    for (const [, f] of files) {
      if (f.parsed.status !== "ok") continue;
      const pair = pairOfBox(f.parsed.box);
      if (pair === null) continue;
      found.set(pair, (found.get(pair) || 0) + 1);
    }
    return found;
  }

  function drawPairs() {
    const found = pairsWithRecords();
    const keys = [...found.keys()].sort(collator.compare);
    if (state.pair !== PAIR_ALL && !found.has(state.pair)) keys.push(state.pair);
    const select = $("pair");
    select.replaceChildren();
    const add = (value, label) => {
      const option = el("option", "", label);
      option.value = value;
      select.appendChild(option);
    };
    add(PAIR_ALL, "全部を見る");
    for (const key of keys) add(key, key.split(PAIR_SEP).join(" ／ ") + "（" + (found.get(key) || 0) + "）");
    select.value = state.pair;
  }

  // What is not assigned yet is said, never quietly dropped: while a pair is being looked at, those
  // records are out of sight, so the bar says how many numbers are waiting and where to settle them.
  function drawUnassigned() {
    const waiting = [...charsSeen.values()].filter(c => assignedPair(c.id) === null);
    const bar = $("unassigned");
    bar.replaceChildren();
    if (!waiting.length) { bar.hidden = true; measureHeader(); return; }
    const records = waiting.reduce((sum, c) => sum + c.records, 0);
    bar.append("まだどのキャラクターか決めていない番号が " + waiting.length + " 件（記録 " + records + " 本）あります。" +
      (state.pair === PAIR_ALL ? "「全部を見る」なので出ています。" : "選んだ組には出ていません。") + " ");
    const go = el("button", "", "割り当てる");
    go.addEventListener("click", () => showTab("names", () => $("charAssign").scrollIntoView({ block: "center" })));
    bar.appendChild(go);
    bar.hidden = false;
    measureHeader();
  }

  // The names of the records each pair's view shows its boxes from: of the records given (readableRecords'), the
  // newest of each box's (its pair and its number), chosen as the reading chooses it (CPlusHomeParse.newer).
  // (全部を見る shows the newest of every account's records. The bar this is for says what a pair's table
  // of houses did not learn, so it goes by the pair's newest, as the tidying does.)
  function newestRecords(records) {
    const newest = new Map();
    for (const rec of records) {
      const key = CPlusHomeParse.boxKey(namesPairOf(rec.parsed.box), rec.parsed.box.id);
      if (!newest.has(key) || CPlusHomeParse.newer(rec, newest.get(key))) newest.set(key, rec);
    }
    return new Set([...newest.values()].map(rec => rec.name));
  }

  // An area the table did not learn for being split (splitNumbers) is said, one line each, rather
  // than left out of sight: the house it would have been stays under its records' own numbers, and only the
  // player can look at the registration in the game. Only while a record carrying it is the one its box is
  // shown from (newestRecords): once that box is recorded again with its area put right, the new record is
  // learned and the line goes, with nothing to tidy away. An area several such
  // records carry is one line, under the character and the number of the oldest. Built again with everything
  // else. Nothing while the names are unread: nothing is learned then. The lines are also what the tidying
  // check compares (asIfDeleted): a deletion that would take one away is a change on the screen.
  function unlearnedLines(readable) {
    const lines = [];
    const said = new Set();
    if (namesLoaded) withSplitMemo(() => {
      const shown = newestRecords(readable);
      for (const [name, f] of learningRecords()) {
        if (!shown.has(name)) continue;
        const box = f.parsed.box;
        const pair = assignedPair(box.char.id);
        if (pair === null || said.has(nameKey(pair, areaText(box.area))) || !isSplit(pair, box.area)) continue;
        said.add(nameKey(pair, areaText(box.area)));
        const a = box.area;
        const numbers = splitNumbers(pair, a);
        const houses = numbers.map(n => "家 " + n);
        lines.push("家の範囲を 1 つ覚えませんでした: " + (box.char.name || box.char.id) + " の家 " + a.n +
          "（facet " + a.facet + "・x " + a.minX + "〜" + a.maxX + "・y " + a.minY + "〜" + a.maxY + "）の中に、" +
          houses.slice(0, -1).join("・") + " と" + houses[houses.length - 1] + " の古い記録があります。範囲が " + numbers.length +
          " 軒にまたがっているか、同じ家に別々の番号を付けた古い記録があるかのどちらかです。範囲が " + numbers.length +
          " 軒にまたがっていないか、ゲームで確かめてください");
      }
    });
    return lines;
  }
  function drawUnlearned(readable) {
    const bar = $("unlearned");
    bar.replaceChildren(...unlearnedLines(readable).map(line => el("div", "", line)));
    bar.hidden = !bar.children.length;
    measureHeader();
  }

  // The table in 名前の設定, with what the records call each number, what it is assigned to, and the characters it
  // could be. **Nothing is assigned by the page itself** - a wrong pair would hide a record without a word - so a
  // candidate is only ever offered or chosen beforehand, and the player presses 決定.
  //
  // A character moved to another shard and back comes back under a new number. The numbers not assigned are
  // one row each, at the top. The numbers assigned are one row a character: the number of its newest record
  // (currentNumber), with the others folded under 「以前の番号 N 個（記録 M 本）」. That is all it is - how the table
  // is shown: the names file still keeps one assignment a number, and the tidying check does not compare it
  // (readingLines: a character's older number going with its records would otherwise stop the tidying for good).
  function drawAssign() {
    const table = $("charAssign");
    const head = el("tr");
    for (const h of ["番号", "記録の名前", "記録", "いまの割り当て", "候補"]) head.appendChild(el("th", "", h));
    table.replaceChildren(head);
    const byName = (a, b) => collator.compare(a.name || String(a.id), b.name || String(b.id));
    const waiting = [];
    const byChar = new Map();
    for (const seen of charsSeen.values()) {
      const now = names.chars[String(seen.id)];
      if (!now) { waiting.push(seen); continue; }
      if (!byChar.has(now)) byChar.set(now, []);
      byChar.get(now).push(seen);
    }
    for (const seen of waiting.sort(byName)) table.appendChild(assignRow(seen, sameName(seen)));
    const groups = [...byChar].map(([value, seens]) => {
      const current = currentNumber(seens);
      const older = seens.filter(s => s !== current).sort((a, b) => (a.last > b.last ? -1 : a.last < b.last ? 1 : a.id < b.id ? -1 : 1));
      return { value, current, older };
    }).sort((a, b) => byName(a.current, b.current));
    for (const { value, current, older } of groups) {
      if (!older.length) { table.appendChild(assignRow(current)); continue; }
      const rows = older.map(olderRow);
      const fold = el("button");
      const label = () => (olderOpen.has(value) ? "▾ " : "▸ ") + "以前の番号 " + older.length + " 個（記録 " +
        older.reduce((sum, s) => sum + s.records, 0) + " 本）";
      const show = () => {
        fold.textContent = label();
        for (const tr of rows) tr.hidden = !olderOpen.has(value);
      };
      fold.addEventListener("click", () => {
        if (olderOpen.has(value)) olderOpen.delete(value); else olderOpen.add(value);
        show();
      });
      show();
      table.appendChild(assignRow(current, { more: fold }));
      for (const tr of rows) table.appendChild(tr);
    }
    drawLegacyPair();
  }

  // Which of a character's numbers is its own now: the one with the newest record. Of two as new, the one
  // with more records, and of those the smaller number - a rule that always gives the same one.
  function currentNumber(seens) {
    return seens.reduce((a, b) => (b.last > a.last || (b.last === a.last &&
      (b.records > a.records || (b.records === a.records && b.id < a.id))) ? b : a));
  }

  // An unassigned number whose records go by exactly the name of numbers already assigned: what a character
  // moved to another shard and back looks like. Where those numbers are all one character's, it is chosen beforehand
  // ( pick - still nothing until 決定 ); where they are several characters', none is, and the note says so. A name that
  // differs at all - a title changed - is left to the candidates. The note calls a number whose newest record is
  // newer than this number's 「新しい番号」 and the rest 「以前の番号」: an older number whose assignment was taken away
  // comes back here too, and the number it now goes with is the newer one.
  function sameName(seen) {
    if (!seen.name) return {};
    const same = [...charsSeen.values()].filter(o => o.id !== seen.id && o.name === seen.name && names.chars[String(o.id)])
      .sort((a, b) => (a.id < b.id ? -1 : 1));
    if (!same.length) return {};
    const ids = same.map(o => String(o.id)).join("・");
    const values = new Set(same.map(o => names.chars[String(o.id)]));
    if (values.size > 1) return { note: "同じ名前の番号 " + ids + " が別々のキャラクターに割り当てられているので、どれも選んでいません" };
    const which = [["以前の番号 ", same.filter(o => !(o.last > seen.last))], ["新しい番号 ", same.filter(o => o.last > seen.last)]]
      .filter(([, list]) => list.length).map(([word, list]) => word + list.map(o => String(o.id)).join("・"));
    return { pick: [...values][0], note: which.join("・") + " と同じ名前です（シャードの移動で番号が変わった可能性）" };
  }

  // One number's row: the number, what its records call it, how many there are, what it is assigned to, and the choice
  // with 決定 ( and 解除 once assigned ). pick is chosen beforehand, note stands under the choice, and more goes after
  // the assignment.
  function assignRow(seen, { pick = "", note = "", more = null } = {}) {
    const tr = el("tr");
    tr.appendChild(el("td", "", String(seen.id)));
    tr.appendChild(el("td", "", seen.name || "（名前なし）"));
    tr.appendChild(el("td", "", String(seen.records)));
    const now = names.chars[String(seen.id)];
    const at = el("td", now ? "" : "warn", now ? assignmentLabel(now) : "未割り当て");
    if (more) at.append(" ", more);
    tr.appendChild(at);
    const cell = el("td");
    const select = el("select");
    const offer = candidatesFor(seen.name);
    const others = [];
    for (const account of charTree.accounts || []) {
      if (account.spare) continue;
      for (const shard of account.shards || []) {
        if (shard.spare) continue;
        for (const character of shard.characters || []) {
          if (character.spare) continue;
          others.push({ account: account.name, shard: shard.name, character: character.name });
        }
      }
    }
    const seenValues = new Set();
    const addValue = (value, mark) => {
      if (seenValues.has(value)) return;
      seenValues.add(value);
      const option = el("option", "", mark + assignmentLabel(value));
      option.value = value;
      select.appendChild(option);
    };
    const none = el("option", "", "（選ぶ）");
    none.value = "";
    select.appendChild(none);
    for (const c of offer) addValue(assignmentValue(c), "候補: ");
    for (const c of others) addValue(assignmentValue(c), "");
    if (now) select.value = now;
    else if (pick) {
      // The character the older number is assigned to may not be on this PC's list: it is offered all the same.
      addValue(pick, "");
      select.value = pick;
    }
    cell.appendChild(select);
    // Nothing is saved before the names are read (saveNames), so the buttons that would save
    // stay shut until then, as the name boxes do - a press that is quietly thrown away is worse.
    const decide = el("button", "", "決定");
    decide.disabled = !namesLoaded;
    decide.addEventListener("click", () => {
      if (!select.value) return;
      names.chars[String(seen.id)] = select.value;
      saveNamesSoon();
      rebuild();
    });
    cell.append(" ", decide);
    if (now) cell.append(" ", undoButton(seen));
    if (note) cell.appendChild(el("div", "hint", note));
    tr.appendChild(cell);
    return tr;
  }

  // An older number of a character, under its row: the number, what its records call it, how many, and 解除.
  function olderRow(seen) {
    const tr = el("tr", "older");
    tr.appendChild(el("td", "", String(seen.id)));
    tr.appendChild(el("td", "", seen.name || "（名前なし）"));
    tr.appendChild(el("td", "", String(seen.records)));
    tr.appendChild(el("td", "", "以前の番号"));
    const cell = el("td");
    cell.appendChild(undoButton(seen));
    tr.appendChild(cell);
    return tr;
  }

  function undoButton(seen) {
    const undo = el("button", "", "解除");
    undo.disabled = !namesLoaded;
    undo.addEventListener("click", () => {
      delete names.chars[String(seen.id)];
      saveNamesSoon();
      rebuild();
    });
    return undo;
  }

  // Which pair the records that carry no number belong to. They are the ones written before the number
  // existed, so there is nothing in them to match on: the player says once which world they came from.
  // Shut until the names are read, as the assignment buttons are.
  // Offered only where there are such records; while no pair is chosen, 「（まだ選んでいない）」 is what it shows.
  function drawLegacyPair() {
    const select = $("legacyPair");
    $("legacyRow").hidden = !hasLegacyRecords();
    select.disabled = !namesLoaded;
    const keys = new Set(pcPairs());
    if (legacyPair()) keys.add(legacyPair());
    select.replaceChildren();
    if (!legacyPair()) {
      const option = el("option", "", "（まだ選んでいない）");
      option.value = "";
      select.appendChild(option);
    }
    for (const key of [...keys].sort(collator.compare)) {
      const option = el("option", "", key.split(PAIR_SEP).join(" ／ "));
      option.value = key;
      select.appendChild(option);
    }
    select.value = legacyPair() || "";
  }

  // ---- controls: 家 and 階
  const houseList = () => [...new Set(boxes.map(b => b.top.house))].filter(h => h !== null).sort((a, b) => a - b);
  // 家と階 in one frame of two rows: every
  // house's button (always all of them), then the floors' buttons - a floor a number shared by every house, 「N階」 (and
  // 「階不明」 last, where a house offered holds anything whose floor is not known). The floors offered are those of the
  // houses chosen, or of any house while none is; a floor chosen that is no longer offered is let go. What is shown is
  // every house chosen by every floor chosen (one floor of one house and another of
  // another cannot be chosen at once). A floor's own name, which is one house's (名前の設定), is not on its button.
  // (one frame a house, its floors after its button.)
  function chip(text, chosen, value, className, onToggle) {
    const l = el("label", [className, chosen.has(value) ? "on" : ""].filter(Boolean).join(" "), text);
    l.addEventListener("click", () => {
      if (chosen.has(value)) chosen.delete(value); else chosen.add(value);
      l.classList.toggle("on");
      if (onToggle) onToggle();
      state.limit = PAGE_SIZE;
      run();
    });
    return l;
  }
  // The houses whose floors are offered: the chosen ones, or every one while none is.
  const floorHouses = () => (state.houses.size ? houseList().filter(h => state.houses.has(h)) : houseList());
  // The floors offered, as numbers - smallest first, 0 (階不明) last - and a floor's words on its button.
  function floorsOffered() {
    const shown = floorHouses();
    const numbers = new Set();
    for (const h of shown) for (const f of houseFloors(h)) numbers.add(f.n);
    const offered = [...numbers].sort((a, b) => a - b);
    if (items.some(it => it.floor === 0 && shown.includes(it.house))) offered.push(0);
    return offered;
  }
  const floorWords = n => (n ? n + "階" : "階不明");
  function drawPlaces() {
    const offered = floorsOffered();
    for (const n of [...state.floors]) if (!offered.includes(n)) state.floors.delete(n);
    const container = $("houses");
    container.replaceChildren();
    const frame = el("div", "housebox");
    const houseRow = el("div", "checks");
    for (const h of houseList()) houseRow.appendChild(chip(houseName(h), state.houses, h, "housechip", drawPlaces));
    frame.appendChild(houseRow);
    if (offered.length) {
      const floorRow = el("div", "checks");
      for (const n of offered) floorRow.appendChild(chip(floorWords(n), state.floors, n, ""));
      frame.appendChild(floorRow);
    }
    container.appendChild(frame);
  }

  // ---- controls: one button for each kind of cabinet in the records
  // A cabinet (a jewel box, a dye tub cabinet, an armour refinement cabinet) holds its items in a gump, and
  // they are never in the ordinary results. One button is made for each kind the records hold, named as the
  // records name it - the box's own first property line, the newest record's - so a kind nobody has yet
  // makes no button and a kind nobody knows of yet needs no list here. Pressed, the results are that kind's
  // items; pressed again, the ordinary list. It is not a condition: 条件の消去 leaves it as it is, and the
  // conditions work on either.
  function cabinetKinds() {
    const found = new Map();
    for (const b of boxes) {
      const kind = cabinetKind(b);
      if (kind === null) continue;
      const seen = found.get(kind);
      if (!seen || b.closed > seen.closed) found.set(kind, { name: b.name || String(kind), closed: b.closed });
    }
    // Each in its cell of KIND_GRID; a kind not in it after the grid's last, in the order of its number.
    let next = KIND_CELLS.size;
    return [...found.entries()].sort((a, b) => a[0] - b[0])
      .map(([kind, v]) => ({ kind, name: v.name, cell: KIND_CELLS.has(kind) ? KIND_CELLS.get(kind) : next++ }))
      .sort((a, b) => a.cell - b.cell);
  }
  // Where each kind's button stands: a grid of two columns of the same width,
  // read row by row, each button as wide as its column, so that the right column's buttons start at one x in every
  // row. A kind the records do not hold
  // leaves its cell empty and the rows keep their height (drawKinds), so no other button moves. Every cell is a
  // kind's: the six fill three rows.
  const KIND_GRID = [[POWER_KIND, TRANS_KIND], [REFINE_KIND, DYE_KIND], [LOCKER_KIND, JEWEL_KIND]];
  const KIND_COLUMNS = 2;
  const KIND_CELLS = new Map(KIND_GRID.flatMap((row, r) => row.map((kind, c) => [kind, r * KIND_COLUMNS + c])));
  function drawKinds() {
    const kinds = cabinetKinds();
    // The records of the kind being shown can go (a folder emptied): back to the ordinary list.
    if (state.cabinet !== null && !kinds.some(k => k.kind === state.cabinet)) state.cabinet = null;
    const row = $("kinds");
    row.replaceChildren();
    // Its frame (at the bottom edge of the panel) is there only while the records hold such a box.
    $("kindbox").hidden = !kinds.length;
    // Every row of the grid is there, as high as the highest, even one no kind of the records stands in.
    const rows = Math.max(KIND_GRID.length, ...kinds.map(k => Math.floor(k.cell / KIND_COLUMNS) + 1));
    row.style.gridTemplateColumns = "repeat(" + KIND_COLUMNS + ", minmax(0, 1fr))";
    row.style.gridTemplateRows = "repeat(" + rows + ", 1fr)";
    for (const k of kinds) {
      const button = el("button", state.cabinet === k.kind ? "kind on" : "kind", k.name);
      button.dataset.kind = String(k.kind);
      button.style.gridRow = String(Math.floor(k.cell / KIND_COLUMNS) + 1);
      button.style.gridColumn = String(k.cell % KIND_COLUMNS + 1);
      button.title = k.kind === LOCKER_KIND ? LOCKER_BUTTON_TITLE
        : k.name + "の中の品だけを出します。もう一度押すと、ふだんの一覧に戻ります";
      button.addEventListener("click", () => {
        state.cabinet = (state.cabinet === k.kind) ? null : k.kind;
        state.limit = PAGE_SIZE;
        drawKinds();
        drawPickers();
        run();
      });
      row.appendChild(button);
    }
  }

  // ---- controls: the dropdowns, in the vendor search's order: 装備, その他, then the property groups.
  // Picking an entry adds it to 選択した検索条件 and puts the dropdown back to （選ぶ）.
  // Only entries some item in the results being shown carries are offered (one kind of cabinet's items
  // while its button is pressed, everything else otherwise), with how many of those items carry them.
  // While the button of the locker, the armour refinement cabinet or a scroll book is pressed, its own filter stands
  // here instead (drawFramedFilter).
  function drawPickers() {
    const pickers = $("pickers");
    pickers.replaceChildren();
    const framed = FRAMED_FILTERS.get(state.cabinet);
    $("hint").textContent = framed ? framed.hint : HINT_TEXT;
    // The FHD form shows the hint as the ? button's title, not under the filters.
    $("hintBtn").title = $("hint").textContent;
    if (framed) { drawFramedFilter(pickers, framed); return; }
    const view = items.filter(inView);
    const viewCount = new Map();
    for (const it of view) for (const key of it.hits.keys()) viewCount.set(key, (viewCount.get(key) || 0) + 1);
    // sections: [{ label, options: [{ value, text }] }]; a section with a label becomes a heading.
    const addSelect = (label, sections, onPick) => {
      const sel = el("select");
      sel.dataset.group = label;
      const first = el("option", "", sections.some(s => s.options.length) ? "（選ぶ）" : "（記録にまだありません）");
      first.value = "";
      sel.appendChild(first);
      for (const s of sections) {
        if (!s.options.length) continue;
        let into = sel;
        if (s.label) { into = el("optgroup"); into.label = s.label; sel.appendChild(into); }
        for (const o of s.options) { const op = el("option", "", o.text); op.value = o.value; into.appendChild(op); }
      }
      sel.addEventListener("change", () => { const v = sel.value; sel.value = ""; if (v) onPick(v); });
      pickers.appendChild(labelled(label, sel));
    };
    const entryOptions = g => g.sections.map(s => ({
      label: s.label,
      options: s.entries.filter(e => viewCount.get(e.key)).map(e => ({ value: e.key, text: e.label + "（" + viewCount.get(e.key) + "）" })),
    }));
    const pickEntry = key => {
      const e = entries.get(key);
      addCond({ type: "entry", key, label: e.label, group: e.group, valued: e.valued, min: null });
    };
    const equip = EQUIP.map(e => ({ value: e.value, n: view.filter(e.test).length })).filter(o => o.n > 0);
    addSelect("装備", [{ label: "", options: equip.map(o => ({ value: o.value, text: o.value + "（" + o.n + "）" })) }],
      value => addCond({ type: "equip", value }));
    const misc = groups[0];
    addSelect(misc.name, entryOptions(misc), pickEntry);
    pickers.appendChild(el("div", "sec", "プロパティ"));
    for (const g of groups.slice(1)) addSelect(g.name, entryOptions(g), pickEntry);
  }

  const HINT_TEXT = $("hint").textContent;
  // A dropdown with its label, as one piece: the FHD form (home_search.html) lays them out
  // two to a line with the label over it; otherwise the piece is display: contents and they are the grid's cells.
  function labelled(label, what) {
    const piece = el("div", "pick");
    piece.append(el("span", "lab", label), what);
    return piece;
  }
  // The filters' rows are grids of a fixed number of columns, 全種 in the first cell (the buttons in columns, as the
  // kinds of box are). Fixed, as the left panel's width is (430px, home_search.html), rather than worked out from the
  // words at run time. Measured with a full set of records at 1400×900: a row in a frame is 367px wide, and a cell is
  // the row less its 6px gaps, shared out. Each count is the most columns the row's longest button (its border and
  // padding in) fits in.
  const COLUMNS = {
    locker: 4,        // 367px: 87px - レンジャーの 78, イルシェナー 77
    refine: 3,        // 367px: 118px - スタッドサムライ 96 (4 columns: 87px)
    powerRank: 5,     // 367px: 69px - 全種 and the four grades on one line
    skillGroup: 4,    // 367px: 87px - two lines: 全種 戦闘 生産 魔法 / 野生 シーフ バード その他
    skill: 2,         // 367px: 180px - Spellweaving [織成呪文] 159, Swordsmanship [剣術] 148
  };
  // A row of a filter's buttons in a grid of that many columns (data-cols says how many). A button is as wide as its cell,
  // its words cut with 「…」 where they do not fit, and whole in its title (the buttons are given one: fbutton).
  function gridRow(cols) {
    const row = el("div", "checks cols");
    row.dataset.cols = String(cols);
    row.style.gridTemplateColumns = "repeat(" + cols + ", minmax(0, 1fr))";
    return row;
  }
  // A filter's button: its words whole in its title as well (a grid's cell can cut them).
  function fbutton(text, on, press, className) {
    const l = el("label", [className, on ? "on" : ""].filter(Boolean).join(" "), text);
    l.title = text;
    l.addEventListener("click", press);
    return l;
  }
  // The Davies' locker's filter, in the place of the dropdowns while its button is pressed: five rows - the kind,
  // the facet, the 「〜の」, the grade and the status - each with 全種 first, one choice a row, pressed again to let it
  // go, and 設定の解除. The buttons are the values the rows of the lockers shown hold (lockerValues), so a value nobody
  // has makes none and one not measured yet still comes. No counts on the buttons, as in the game's own filters.
  // In frames: 種類, ファセット, レベル (two rows in it: 〜の and 段階) and
  // ステータス, each with its heading, and above them the line of what is chosen (「絞り込み: なし」 while nothing is).
  // Each row carries its item's key (data-key).
  // The armour refinement cabinet's, the power scroll book's and the transcendence scroll book's filters look
  // and work as the locker's, so all four are drawn by one function
  // (drawFramedFilter) from a description each in FRAMED_FILTERS:
  //  - key: where its choices are kept in state; hint: the line under the filter;
  //  - own: which rows of the results shown it offers values from;
  //  - frames(rows): its frames as [heading, [[row key, values as [value, words], caption], ...]];
  //  - value(row, row key): what a row of the results is for that row of the filter, compared with the value chosen.
  // A row of the results passes when every row of the filter chosen holds (framedPasses).
  const LOCKER_HINT = "ロッカーの地図と SOS を、種類・ファセット・レベル・ステータスで絞り込みます。行ごとに 1 つ選べ、もう一度押すと外れます。";
  const REFINE_HINT = "防具強化材を、ランク・種別・防具種別で絞り込みます。行ごとに 1 つ選べ、もう一度押すと外れます。";
  const POWER_HINT = "パワースクロールを、ランク・スキルのグループ・スキルで絞り込みます。グループを選ぶと、その中のスキルが出ます。行ごとに 1 つ選べ、もう一度押すと外れます。";
  const TRANS_HINT = "超越のスクロールを、スキルのグループ・スキルで絞り込みます。グループを選ぶと、その中のスキルが出ます。行ごとに 1 つ選べ、もう一度押すと外れます。";
  // The order of the armour refinement cabinet's grades and bonuses: these
  // buttons are always there, and a word the records hold that is not here stands after them. The armour has no list:
  // its buttons are the words the records hold, in the order of the kana (kanaFirst).
  const REFINE_ORDER = { rank: ["良質", "高級", "優良", "特等", "究極"], bonus: ["抵抗強化", "回避強化"], armor: [] };
  // By the kana, and a word that starts with a kanji after every one that does not (「鋼製ガーグ」 last).
  const startsWithKanji = w => /^[\u3400-\u9fff]/.test(w);
  const kanaFirst = (a, b) => startsWithKanji(a) - startsWithKanji(b) || collator.compare(a, b);
  function refineValues(rows, key) {
    const fixed = REFINE_ORDER[key];
    const found = [...new Set(rows.map(it => it.refine[key]).filter(w => w !== null && !fixed.includes(w)))].sort(kanaFirst);
    return [...fixed, ...found].map(w => [w, w]);
  }
  // The power scroll's grades, highest first, as numbers: these are always there, and a number the records hold that
  // is not among them stands after them, highest first.
  const POWER_RANKS = [120, 115, 110, 105];
  function powerRanks(rows) {
    const found = [...new Set(rows.map(powerRank).filter(n => n !== null && !POWER_RANKS.includes(n)))].sort((a, b) => b - a);
    return [...POWER_RANKS, ...found].map(n => [n, String(n)]);
  }
  // The skills of the scrolls shown as [tid, words, group], in the words of the records and in the order they first
  // come: only a skill some scroll shown is of - a book's row is a skill it holds one or more of (bookRows).
  function bookSkills(rows) {
    const skills = new Map();
    for (const it of rows) if (!skills.has(it.book.skill)) skills.set(it.book.skill, [it.book.skill, it.name, it.book.group]);
    return [...skills.values()];
  }
  // The groups of the scroll books' skills: the tabs of the game's skills window. Which tab a skill is in, and its
  // place there, is not known to the page: the module writes it into the book's record (its bookgroup lines, read
  // into a skill's group as { tab, order }) from the game's own table. The page knows only the tabs' names and
  // where their buttons stand.
  //  - A tab's number is its number in Default.zip Source/SkillsWindow.lua (tab1 to tab7).
  //  - Its name: the tab's words on the player's screen (SkillsWindow.lua:116-126 names them by tid: 1077760 戦闘,
  //    1077761 生産, 1077762 魔法, 1077763 野生, 1078116 シーフ, 1077765 バード, 1078117 その他).
  //  - Their order here: tab2 to tab7 and then tab1. その他 (tab1) stands last here; the window has it first.
  // A skill with no group (a record of an older version, or one the module could not look up) is in 分類なし.
  const SKILL_TABS = [[2, "戦闘"], [3, "生産"], [4, "魔法"], [5, "野生"], [6, "シーフ"], [7, "バード"], [1, "その他"]];
  const SKILL_UNGROUPED = "分類なし";
  const SKILL_TAB_NAME = new Map(SKILL_TABS);
  const skillGroupOf = group => (group && SKILL_TAB_NAME.get(group.tab)) || SKILL_UNGROUPED;
  // The groups' buttons stand in fixed cells of their grid (COLUMNS.skillGroup: 全種 戦闘 生産 魔法 / 野生
  // シーフ バード その他); 分類なし, there only while a skill shown is in no group (or
  // it is chosen), in the first cell of a third line. A group no scroll shown is of leaves its cell empty.
  const SKILL_GROUP_CELLS = ["全種", ...SKILL_TABS.map(([, name]) => name), SKILL_UNGROUPED];
  // The skills of a group, in their places in its tab (分類なし: in the order given).
  const skillsOfGroup = (group, skills) => {
    const mine = skills.filter(([, , g]) => skillGroupOf(g) === group);
    return group === SKILL_UNGROUPED ? mine : mine.sort((a, b) => a[2].order - b[2].order);
  };
  // A filter's frames: [heading, rows], a row { key, values as [value, words], cols, caption } - or, for the scroll
  // books' skills, { skills } (drawFramedFilter's skill picker, which chooses the group and the skill).
  const FRAMED_FILTERS = new Map([
    [LOCKER_KIND, { key: "locker", hint: LOCKER_HINT, own: it => !!it.locker,
      frames: rows => [
        ["種類", [{ key: "kind", values: [...LOCKER_KIND_TEXT].filter(([kind]) => rows.some(it => it.locker.kind === kind)), cols: COLUMNS.locker }]],
        ["ファセット", [{ key: "facet", values: lockerValues(rows, "facet"), cols: COLUMNS.locker }]],
        ["レベル", [{ key: "prefix", values: lockerValues(rows, "prefix"), cols: COLUMNS.locker, caption: "〜の" },
          { key: "tier", values: lockerValues(rows, "tier"), cols: COLUMNS.locker, caption: "段階" }]],
        ["ステータス", [{ key: "status", values: lockerValues(rows, "status"), cols: COLUMNS.locker }]]],
      // A SOS has no 「〜の」 and no grade, so choosing either leaves it out; a row of no shape has none of them, and
      // passes only with nothing chosen.
      value: (it, key) => (key === "kind" ? it.locker.kind : it.locker[key + "Tid"]) }],
    [REFINE_KIND, { key: "refine", hint: REFINE_HINT, own: it => !!it.refine,
      frames: rows => [["ランク", [{ key: "rank", values: refineValues(rows, "rank"), cols: COLUMNS.refine }]],
        ["種別", [{ key: "bonus", values: refineValues(rows, "bonus"), cols: COLUMNS.refine }]],
        ["防具種別", [{ key: "armor", values: refineValues(rows, "armor"), cols: COLUMNS.refine }]]],
      value: (it, key) => (it.refine ? it.refine[key] : null) }],
    [POWER_KIND, { key: "power", hint: POWER_HINT, own: it => !!it.book,
      frames: rows => [["ランク", [{ key: "rank", values: powerRanks(rows), cols: COLUMNS.powerRank }]], ["スキル", [{ skills: bookSkills(rows) }]]],
      value: (it, key) => (!it.book ? null : key === "rank" ? powerRank(it) : key === "group" ? skillGroupOf(it.book.group) : it.book.skill) }],
    [TRANS_KIND, { key: "trans", hint: TRANS_HINT, own: it => !!it.book,
      frames: rows => [["スキル", [{ skills: bookSkills(rows) }]]],
      value: (it, key) => (!it.book ? null : key === "group" ? skillGroupOf(it.book.group) : it.book.skill) }],
  ]);
  const framedPasses = (spec, it) => Object.entries(state[spec.key]).every(([key, chosen]) => chosen === null || spec.value(it, key) === chosen);
  // The words each value was chosen by ("<filter>\n<row>\n<value>" -> words), for a chosen value no row shown holds.
  const framedChosenWords = new Map();
  function drawFramedFilter(pickers, spec) {
    const f = state[spec.key];
    const choose = change => () => { change(); state.limit = PAGE_SIZE; drawPickers(); run(); };
    const rows = items.filter(it => spec.own(it) && inView(it));
    // A value chosen stays a lit button of its row even when no row shown holds it any more (another pair looked
    // at, say), last in the row and in the words it was chosen by: pressed, it lets go. A choice that could not be seen
    // left the results empty with nothing lit; letting it go by itself would lose it without a word
    // when the pair is changed back.
    // The words of what is chosen are noted, in the order drawn, for the line above the frames.
    const chosenWords = [];
    // A value's button in a row: pressed, it is chosen, and pressed again it lets go.
    const button = (key, [value, text]) => {
      if (f[key] === value) chosenWords.push(text);
      return fbutton(text, f[key] === value, choose(() => {
        f[key] = f[key] === value ? null : value;
        framedChosenWords.set(spec.key + "\n" + key + "\n" + value, text);
      }));
    };
    // A chosen value no row shown holds, as [value, words], or null.
    const missing = (key, values) => (f[key] === null || values.some(([value]) => value === f[key]) ? null
      : [f[key], framedChosenWords.get(spec.key + "\n" + key + "\n" + f[key]) || String(f[key])]);
    // One item's row of buttons - 全種, then its values, with the one chosen added last when no row shown holds it - in a
    // grid of cols columns, with its caption over it when its frame holds two (over, not beside - beside, it
    // took the cells' room).
    const item = ({ key, values, cols, caption }) => {
      const row = gridRow(cols);
      row.dataset.key = key;
      row.appendChild(fbutton("全種", f[key] === null, choose(() => { f[key] = null; })));
      const lost = missing(key, values);
      for (const value of lost ? [...values, lost] : values) row.appendChild(button(key, value));
      return caption ? [el("div", "rowcap", caption), row] : [row];
    };
    // The scroll books' skills: the groups' buttons in their fixed cells
    // (SKILL_GROUP_CELLS), and only while a group is chosen, its name and its skills' buttons under them, in the group's
    // order, two to a line. A group chosen narrows the results to its scrolls. 全種, or the group chosen pressed again,
    // lets both the group and the skill go; another group changes to it and lets the skill go; the skill chosen pressed
    // again lets the skill alone go. A group chosen that no scroll shown is of stays lit in its cell, and a skill
    // chosen likewise stays lit last among its group's. (Every group's skills are in a frame of their own.)
    const skillPicker = ({ skills }) => {
      const box = el("div", "skillpick");
      box.dataset.key = "skill";
      const groups = gridRow(COLUMNS.skillGroup);
      groups.dataset.part = "groups";
      const present = new Set(skills.map(([, , group]) => skillGroupOf(group)));
      const place = (label, cell) => {
        label.style.gridRow = String(Math.floor(cell / COLUMNS.skillGroup) + 1);
        label.style.gridColumn = String(cell % COLUMNS.skillGroup + 1);
        groups.appendChild(label);
      };
      place(fbutton("全種", f.group === null, choose(() => { f.group = null; f.skill = null; })), 0);
      SKILL_GROUP_CELLS.forEach((name, cell) => {
        if (cell === 0 || (!present.has(name) && f.group !== name)) return;
        if (f.group === name) chosenWords.push(name);
        place(fbutton(name, f.group === name, choose(() => { f.skill = null; f.group = f.group === name ? null : name; })), cell);
      });
      // Every line of the grid is there and as high as the others, so that no group's button moves.
      const lines = present.has(SKILL_UNGROUPED) || f.group === SKILL_UNGROUPED ? 3 : 2;
      groups.style.gridTemplateRows = "repeat(" + lines + ", 1fr)";
      box.appendChild(groups);
      if (f.group !== null) {
        box.appendChild(el("div", "rowcap", f.group));
        const row = gridRow(COLUMNS.skill);
        row.dataset.part = "skills";
        const mine = skillsOfGroup(f.group, skills);
        const lost = missing("skill", mine);
        for (const value of lost ? [...mine, lost] : mine) row.appendChild(button("skill", value));
        box.appendChild(row);
      }
      return box;
    };
    const frames = spec.frames(rows).map(([title, frameRows]) => {
      const box = el("div", "framebox wide");
      box.appendChild(el("div", "framehead", title));
      for (const r of frameRows) box.append(...(r.skills ? [skillPicker(r)] : item(r)));
      return box;
    });
    pickers.appendChild(el("div", "filternow wide", "絞り込み: " + (chosenWords.length ? chosenWords.join(" ・ ") : "なし")));
    for (const box of frames) pickers.appendChild(box);
    const reset = el("button", "", "設定の解除");
    reset.addEventListener("click", choose(() => { clearFramedFilter(spec.key); }));
    const cell = el("div");
    cell.appendChild(reset);
    pickers.append(el("span", "lab", ""), cell);
  }
  function clearFramedFilter(key) {
    for (const row of Object.keys(state[key])) state[key][row] = null;
  }

  function addCond(cond) {
    const same = state.conds.find(c => c.type === cond.type && (c.key || c.value) === (cond.key || cond.value));
    if (!same) state.conds.push(cond);
    drawConds();
    state.limit = PAGE_SIZE;
    run();
  }
  // What a condition shows as, from the records as they are now (a wording can have gone since it was picked).
  const condEntry = c => (c.type === "entry" ? entries.get(c.key) || null : null);
  const condValued = c => { const e = condEntry(c); return e ? e.valued : !!c.valued; };

  // 並び順: 名前, 場所, and one "…が大きい順" per picked condition that carries numbers.
  // If the condition being sorted by is removed, the order goes back to 名前.
  function drawSortOptions() {
    const sortEl = $("sort");
    const options = [["name", "名前"], ["where", "場所"]];
    for (const c of state.conds) if (c.type === "entry" && condValued(c)) options.push(["v:" + c.key, (condEntry(c) || c).label + "が大きい順"]);
    if (!options.some(([v]) => v === state.sort)) state.sort = "name";
    sortEl.replaceChildren();
    for (const [v, text] of options) { const op = el("option", "", text); op.value = v; sortEl.appendChild(op); }
    sortEl.value = state.sort;
  }

  // Redraws with draw(), and puts the focus back on the input that stands for the same thing, with its
  // selection where it has one (a number box has none: its selectionStart is null). inputs: Map from the
  // thing to its input, emptied here and filled again by draw().
  function keepingFocus(inputs, draw) {
    const active = document.activeElement;
    let focused = null;
    for (const [key, inp] of inputs) {
      if (inp === active) focused = { key, range: inp.selectionStart === null ? null : [inp.selectionStart, inp.selectionEnd] };
    }
    inputs.clear();
    draw();
    const again = focused && inputs.get(focused.key);
    if (!again) return;
    again.focus();
    if (focused.range) again.setSelectionRange(focused.range[0], focused.range[1]);
  }

  // 選択した検索条件: the red × removes one; a number box only for entries whose lines carry numbers.
  // The number boxes by their condition, so that the one being typed in keeps the focus when new records
  // redraw the list.
  const condInputs = new Map();
  function drawConds() { keepingFocus(condInputs, drawCondRows); }
  function drawCondRows() {
    drawSortOptions();
    // How many conditions are in force, in the heading. Nothing is added at 0 - 「（0）」 would
    // only be one more thing to read where the line below already says there is nothing.
    $("condsTitle").textContent = "選択した検索条件" + (state.conds.length ? "（" + state.conds.length + "）" : "");
    const condsEl = $("conds");
    condsEl.replaceChildren();
    if (!state.conds.length) { condsEl.appendChild(el("li", "none", "まだありません。左の一覧から選ぶと、ここに並びます。")); return; }
    for (const c of state.conds) {
      const e = condEntry(c);
      const li = el("li");
      const x = el("button", "x", "×");
      x.title = "この条件を外す";
      x.addEventListener("click", () => {
        state.conds.splice(state.conds.indexOf(c), 1);
        drawConds();
        state.limit = PAGE_SIZE;
        run();
      });
      const text = el("span");
      text.append(el("span", "", c.type === "equip" ? c.value : (e || c).label), el("span", "grp", c.type === "equip" ? "装備" : c.group));
      const num = el("span", "num");
      if (condValued(c)) {
        const inp = el("input");
        inp.type = "number";
        inp.placeholder = "数字";
        inp.value = c.min === null ? "" : String(c.min);
        inp.addEventListener("input", () => { c.min = inp.value === "" ? null : Number(inp.value); state.limit = PAGE_SIZE; run(); });
        condInputs.set(c, inp);
        num.append(inp, "以上");
      }
      li.append(x, text, num);
      condsEl.appendChild(li);
    }
  }

  // ---- search
  function matches(it) {
    if (state.q && !it.search.includes(state.q)) return false;
    if (state.lineq.length && !state.lineq.every(w => it.lineText.includes(w))) return false;
    if (state.houses.size && !state.houses.has(it.house)) return false;
    // A floor chosen is every house's floor of that number (its house is asked on the line above).
    if (state.floors.size && !state.floors.has(it.floor)) return false;
    // Every picked condition must hold, 装備 and 必要スキル included.
    for (const c of state.conds) {
      if (c.type === "equip") {
        if (!EQUIP_BY_VALUE.get(c.value).test(it)) return false;
        continue;
      }
      const lines = it.hits.get(c.key);
      if (!lines) return false;
      if (c.min !== null && !lines.some(p => p.v.length && p.v[0] >= c.min)) return false;
    }
    return true;
  }
  // The largest value among the item's lines for that condition (an item can carry the line twice).
  function valueOf(it, key) {
    const values = (it.hits.get(key) || []).filter(p => p.v.length).map(p => p.v[0]);
    return values.length ? Math.max(...values) : -Infinity;
  }
  const byName = (a, b) => collator.compare(a.name, b.name);

  function run() {
    // The locker's filter only while its button is pressed, and the armour refinement cabinet's and the scroll books'.
    const framed = FRAMED_FILTERS.get(state.cabinet);
    const hits = items.filter(it => inView(it) && matches(it) && (!framed || framedPasses(framed, it)));
    if (state.sort === "name") hits.sort(byName);
    else if (state.sort === "where") hits.sort((a, b) => collator.compare(path(a.boxRef).join(">"), path(b.boxRef).join(">")) || byName(a, b));
    else { const key = state.sort.slice(2); hits.sort((a, b) => (valueOf(b, key) - valueOf(a, key)) || byName(a, b)); }
    $("count").replaceChildren(el("span", "big", hits.length.toLocaleString()), el("span", "", "件"));
    // Above the results, while a cabinet's button is pressed: how many items come from an older record of
    // their box (a
    // card's mark alone is easy to miss), and how many of the boxes shown the records do not cover to the
    // end. Split records that together hold everything say the first but not the second.
    const older = hits.filter(it => it.from).length;
    const short = new Set(hits.filter(it => jewelShort(it.boxRef)).map(it => it.boxRef.key));
    const lines = [];
    if (older) lines.push("前の記録の品を " + older + " 件ふくみます（カードに「前の記録」の印）。");
    if (short.size) lines.push("記録しきれていない入れ物が " + short.size + " 箱あります。ゲームでその入れ物を最後までめくって閉じると、そろいます。");
    // A scroll book is read a skill's page at a time, in as many openings as the player likes, so one not read to
    // the end is the usual thing: what to do about it, and how far each book has got (bookCoverage).
    const shortBooks = new Map();
    for (const it of hits) if (bookShort(it.boxRef)) shortBooks.set(it.boxRef.key, it.boxRef);
    if (shortBooks.size) {
      lines.push("最後まで読み込まれていないスクロールブックが " + shortBooks.size + " 冊あります。本を開いて、まだ読んでいない技能のページを開いてください。" +
        "スクロールを出し入れしたときは、その技能のページを開いて読み込み直してください。（" +
        [...shortBooks.values()].map(b => boxName(b) + " " + bookCoverage(b.book)).join("、") + "）");
    }
    showBar("oldRecords", lines.join(""));
    // The lockers among the results not read to the end, in a red line of its own - larger than the line above,
    // since a part of a locker shown as though it were the whole of it is the thing to avoid.
    const shortLockers = new Set(hits.filter(it => it.locker && lockerShort(it.boxRef)).map(it => it.boxRef.key));
    showBar("lockerShort", shortLockers.size ? "読み切っていないロッカーが " + shortLockers.size + " 個あります。ゲームでそのロッカーを最後のページまでめくって閉じると、そろいます。" : "");
    const results = $("results");
    results.replaceChildren();
    if (!hits.length) { results.appendChild(el("div", "empty panel", "条件に合うアイテムはありません")); return; }
    for (const it of hits.slice(0, state.limit)) results.appendChild(card(it));
    if (hits.length > state.limit) {
      const more = el("button", "more", "さらに表示（残り " + (hits.length - state.limit) + " 件）");
      more.addEventListener("click", () => { state.limit += PAGE_SIZE; run(); });
      results.appendChild(more);
    }
  }
  // Before the first records arrive: not the empty result (nothing has been searched yet).
  function drawNotLoaded() {
    if (loadedOnce) return;
    $("count").replaceChildren();
    $("results").replaceChildren(el("div", "empty panel", "記録をまだ読めていません"));
  }

  // Lines that answered a picked condition.
  function pickedLines(it) {
    const picked = new Set();
    for (const c of state.conds) if (c.type === "entry" && it.hits.has(c.key)) for (const p of it.hits.get(c.key)) picked.add(p);
    return picked;
  }
  function card(it) {
    const d = el("div", "item");
    d.dataset.id = it.id;
    const body = el("div", "body");
    const top = el("div", "top");
    top.appendChild(el("span", "name", it.name));
    // A scroll's grade and how many come right after the name and are drawn as large as it: on a book's rows they are
    // what is being looked for.
    if (it.book) {
      top.appendChild(el("span", "bookgrade", it.book.tier));
      top.appendChild(el("span", "bookcount", it.book.count + " 本"));
    }
    // A locker's map or SOS: its facet, status and coordinates, and its page. A row of no shape says so.
    if (it.locker) {
      const l = it.locker;
      if (l.kind === "odd") top.appendChild(el("span", "lockerodd", LOCKER_ODD));
      else top.appendChild(el("span", "lockerinfo", [l.facet, l.status, "座標 " + (l.coords || "-")].filter(Boolean).join(" ・ ")));
      if (l.page !== null) top.appendChild(el("span", "page", "頁 " + l.page));
    }
    if (it.twin) top.appendChild(el("span", "twin", "同名 " + it.twin.k + "/" + it.twin.n + "・#" + it.id.slice(-4)));
    // A jewel box's item from a record older than its newest: that page was not turned the last time.
    if (it.from) top.appendChild(el("span", "old", "前の記録 " + shortTime(it.from.closed)));
    // A jewel box has no slot that can be lit, so where the record saw the item is the page it was on.
    const pages = guidePages(it);
    if (pages.length) top.appendChild(el("span", "page", "頁 " + pages.join("・")));
    // A scroll has no base item and no kind: its grade and how many are up beside the name instead. Nor has
    // a locker's row.
    if (!it.book && !it.locker) top.appendChild(el("span", "meta", [it.base ? "元: " + it.base : "元の品名: 未記録", it.kind, it.part].filter(Boolean).join(" ・ ")));
    const guide = el("button", "guide", "ゲームで案内");
    guide.title = "ゲームの『家検索』に貼り付ける文字をコピーします";
    guide.addEventListener("click", e => { e.stopPropagation(); copyGuide(it); });
    top.appendChild(guide);
    const where = el("div", "where");
    path(it.boxRef).forEach((s, i) => {
      if (i) where.append(" ＞ ");
      where.appendChild(el(i < 2 ? "b" : "span", "", s));
    });
    // Every line but the name, each in its own frame: the lines that answered a picked condition first and
    // larger, then the rest in the item's own order.
    const chipsEl = el("div", "chips");
    const picked = pickedLines(it);
    const rest = it.props.slice(1);
    for (const p of [...rest.filter(p => picked.has(p)), ...rest.filter(p => !picked.has(p))]) chipsEl.appendChild(el("span", picked.has(p) ? "chip hit" : "chip", p.x));
    body.append(top, where);
    // A locker's row of a locker not read to the end says so under where it is, in red and larger than the card's
    // own words - the rows shown are not all the locker holds.
    if (it.locker && lockerShort(it.boxRef)) {
      const l = it.boxRef.locker;
      body.appendChild(el("div", "lockershort", "読み切っていないロッカー（読んだ " + dash(l.read) + " 件 / " + dash(l.count) + " 件）"));
    }
    body.appendChild(chipsEl);
    if (state.open.has(itemKey(it))) body.appendChild(detail(it));
    d.append(body);
    d.addEventListener("click", () => {
      const key = itemKey(it);
      if (state.open.has(key)) state.open.delete(key); else state.open.add(key);
      d.replaceWith(card(it));
    });
    return d;
  }
  // yyyymmdd-hhmmss as mm/dd hh:mm, for the mark on a card.
  const shortTime = s => String(s || "").replace(/^\d{4}(\d\d)(\d\d)-(\d\d)(\d\d)\d\d$/, "$1/$2 $3:$4");

  // Clicking a card adds where the record came from.
  function detail(it) {
    const b = it.boxRef;
    const closed = b.closed.replace(/^(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)$/, "$1/$2/$3 $4:$5");
    const where = "記録: " + closed + " ・ 箱の番号 " + b.id + " ・ 開いた位置 " + b.x + "," + b.y + " 高さ " + b.z;
    // A scroll has no id of its own: what the records have instead is how much of the book they read.
    if (it.book) {
      return el("div", "detail", where + " ・ " + bookCoverage(b.book) + " ・ 重ねた記録 " + b.book.records +
        " ・ " + (b.book.done ? "最後まで読み込み済み" : "最後まで読み込まれていない"));
    }
    // Nor has a locker's row: how much of the locker was seen, and whether the block opened is known.
    if (it.locker) {
      return el("div", "detail", where + (b.locker.confirmed ? "" : "（開いたブロックは確かめられず）") + " ・ 見た頁 " + dash(b.locker.seen) +
        " / " + dash(b.locker.pages) + " ・ 読んだ " + dash(b.locker.read) + " 件 / " + dash(b.locker.count) + " 件");
    }
    return el("div", "detail", where + " ・ アイテムの番号 " + it.id);
  }

  // ---- 開きに行くリスト
  function tableRows(table, heads, rows) {
    const head = el("tr");
    for (const h of heads) head.appendChild(el("th", "", h));
    table.replaceChildren(head);
    for (const cells of rows) {
      const tr = el("tr");
      for (const c of cells) tr.appendChild(el("td", c.className || "", String(c.text !== undefined ? c.text : c)));
      table.appendChild(tr);
    }
  }
  function drawTodo() {
    const todo = [];
    for (const it of items) {
      const n = CPlusHomeParse.containerCount(it);
      if (n === null || boxById.has(boxKeyOf(it.boxRef.world, it.id))) continue;
      todo.push({ where: path(it.boxRef).join(" ＞ "), name: it.name, n });
    }
    todo.sort((a, b) => b.n - a.n || collator.compare(a.where, b.where));
    tableRows($("todo"), ["入っている場所", "入れ物", "中の個数"], todo.map(r => [r.where, r.name, r.n]));
    // Cabinets the records do not cover to the end (jewelShort), with what the records laid over each
    // other come to, and what the newest of them said on its own.
    const num = n => (n === null ? "-" : n);
    const jewels = boxes.filter(jewelShort)
      .map(b => ({ where: path(b).join(" ＞ "), j: b.jewel, missing: (b.jewel.items || 0) - (b.jewel.stacked || 0) }));
    jewels.sort((a, b) => b.missing - a.missing || collator.compare(a.where, b.where));
    tableRows($("jewels"), ["入れ物", "記録した件数 / 入れ物の件数", "記録したページ / 全ページ", "最新の記録"],
      jewels.map(r => [r.where, num(r.j.stacked) + " / " + num(r.j.items), num(r.j.covered) + " / " + num(r.j.pages),
        num(r.j.itemsSeen) + " 件・" + num(r.j.pagesSeen) + "/" + num(r.j.pages) + " 頁"]));
    // Scroll books whose records laid over each other do not read every skill they hold, with how far they have
    // got (bookCoverage), how many records were laid over each other, and the skills the newest record read.
    const books = boxes.filter(bookShort).map(b => ({ where: path(b).join(" ＞ "), b: b.book }));
    books.sort((a, b) => b.b.stacked - a.b.stacked || collator.compare(a.where, b.where));
    tableRows($("books"), ["本", "読み込んだ技能 / 全部の技能", "重ねた記録", "最新の記録"],
      books.map(r => [r.where, bookCoverage(r.b), num(r.b.records), num(r.b.read) + " 技能"]));
    // Not a jewel box: its record holds only the pages turned, which the table of jewel boxes above tells.
    const mismatch = boxes.filter(b => !b.jewel && b.contents !== null && b.contents !== b.direct + b.nested);
    tableRows($("mismatch"), ["箱", "「内容」の数", "直下＋中の入れ物の内容"],
      mismatch.map(b => [path(b).join(" ＞ "), b.contents, { text: b.direct + " ＋ " + b.nested + " ＝ " + (b.direct + b.nested), className: "warn" }]));
  }

  // ---- 名前の設定
  // The inputs by what they name, so that the one being typed in keeps its place when the tab is redrawn.
  const nameInputs = new Map();
  function nameInput(kind, key, placeholder, onChange) {
    const inp = el("input");
    inp.type = "text";
    inp.placeholder = placeholder;
    inp.value = names[kind][key] || "";
    inp.disabled = !namesLoaded;
    inp.addEventListener("input", () => { changeName(kind, key, inp.value); onChange(); });
    nameInputs.set(kind + "/" + key, inp);
    return inp;
  }
  // A house's or a floor's name typed: what shows the names is drawn again. (A names file read after the
  // first reading builds everything again instead - refreshOnce.)
  function namesChanged() { drawPlaces(); run(); drawTodo(); }

  // A world's name as the page says it (words of this page's own, not held against the
  // game's). A world past these is said by its number.
  const FACET_NAMES = ["フェルッカ", "トランメル", "イルシェナー", "マラス", "徳之諸島", "テルマー"];
  const facetName = facet => FACET_NAMES[facet] || ("世界 " + facet);

  // Where a place is by the sextant, written the player's way: "39.48' S / 29.06' W" (the game's map
  // writes "39.48'S 29.06'W": Source/RadarWindow.lua:260, MapWindow.lua:717). The sums are Default's own
  // (Source/MapCommon.lua: the values at :81-88, GetSextantCenter :777, ConvertToMinutesXY :785,
  // GetSextantLocationStrings :807): measured from (1323, 1624), or from (6144, 3112) in the Lost Lands of Felucca
  // and Trammel (x from 5120 and y from 2304); 21600 minutes to 5120 tiles east-west and to 4096 north-south,
  // folded into -10800..10800; south and east count up. Degrees and minutes are both cut, never rounded - Lua's
  // "%d" and "%02d" of what it holds.
  const SEXTANT_CENTER = [1323, 1624];
  const SEXTANT_LOST_LANDS_CENTER = [6144, 3112];
  const SEXTANT_LOST_LANDS_FROM = [5120, 2304];
  const SEXTANT_TILES = [5120, 4096];
  const SEXTANT_MINUTES = 21600;
  function sextant(x, y, facet) {
    const lostLands = (facet === 0 || facet === 1) && x >= SEXTANT_LOST_LANDS_FROM[0] && y >= SEXTANT_LOST_LANDS_FROM[1];
    const [cx, cy] = lostLands ? SEXTANT_LOST_LANDS_CENTER : SEXTANT_CENTER;
    const fold = m => {
      if (m > SEXTANT_MINUTES / 2) m -= SEXTANT_MINUTES;
      if (m <= -SEXTANT_MINUTES / 2) m += SEXTANT_MINUTES;
      return m;
    };
    const part = (m, up, down) => {
      const a = Math.abs(m);
      return Math.floor(a / 60) + "." + String(Math.floor(a % 60)).padStart(2, "0") + "' " + (m < 0 ? down : up);
    };
    return part(fold(SEXTANT_MINUTES * (y - cy) / SEXTANT_TILES[1]), "S", "N") + " / " +
      part(fold(SEXTANT_MINUTES * (x - cx) / SEXTANT_TILES[0]), "E", "W");
  }

  // Under a house's name: its range as its pair's table holds it, and where its middle is by the sextant.
  // { lines } for a range - the world, X, Y and the middle, one under another:
  // in one line the house's panel is too narrow and breaks it anywhere. { text } for a sentence instead.
  function houseRange(pair, h) {
    const area = tableHouses(pair).find(t => t.n === h);
    if (!area) return { text: "範囲はまだ覚えていません（その家の箱を 1 つ開け閉めすると覚えます）" };
    const middle = sextant(Math.floor((area.minX + area.maxX) / 2), Math.floor((area.minY + area.maxY) / 2), area.facet);
    return { lines: [facetName(area.facet), "X " + area.minX + "〜" + area.maxX, "Y " + area.minY + "〜" + area.maxY, "中心 " + middle] };
  }

  // Above the houses, a button that copies a pair's houses for the game (copyAreas) for each pair whose
  // table holds a house: the pair being looked at, or under 全部を見る every such pair.
  function drawAreaCopy() {
    const pairs = state.pair === PAIR_ALL
      ? [...new Set(Object.keys(names.areas).map(pairOfAssignment))].sort(collator.compare)
      : [state.pair];
    const row = $("areaCopy");
    row.replaceChildren();
    for (const pair of pairs.filter(p => tableHouses(p).length > 0)) {
      const b = el("button", "", assignmentLabel(pair) + " の範囲をゲームへコピー");
      b.addEventListener("click", () => copyAreas(pair));
      row.appendChild(b);
    }
    $("areaPanel").hidden = !row.children.length;
  }

  function drawNames() { keepingFocus(nameInputs, drawNameRows); }
  function drawNameRows() {
    drawAreaCopy();
    const grid = $("housenames");
    grid.replaceChildren();
    for (const h of houseList()) {
      const p = el("div", "panel");
      const facet = (boxes.find(b => b.top.house === h) || {}).facet;
      p.appendChild(el("h2", "", "家" + h + "（世界 " + facet + "）"));
      // A house standing only in records nobody has placed yet gets no name box. A name
      // written now would be kept under「まだ決まっていない」and become unreachable the moment the
      // number is assigned - it would look like the name had been thrown away. Assigning comes first.
      if (housePair(h) === PAIR_UNASSIGNED) {
        p.appendChild(el("div", "hint", "この家の記録は、まだどのキャラクターのものか決まっていません。" +
          "「キャラクターの割り当て」で決めると、名前を付けられます。"));
        grid.appendChild(p);
        continue;
      }
      const row = el("div", "row");
      row.append(el("span", "lab", "家の名前"), nameInput("houses", nameKey(housePair(h), String(h)), "家" + h, namesChanged));
      p.appendChild(row);
      const found = houseRange(housePair(h), h);
      const value = found.lines ? el("div", "rangelines") : el("span", "", found.text);
      for (const line of found.lines || []) value.appendChild(el("div", "", line));
      const range = el("div", "row range");
      range.append(el("span", "lab", "範囲"), value);
      p.appendChild(range);
      for (const f of houseFloors(h)) {
        const r = el("div", "row");
        r.append(el("span", "lab", "高さ " + (f.min === f.max ? f.min : f.min + "〜" + f.max)),
          nameInput("floors", nameKey(housePair(h), h + ":" + f.n), f.n + "階", namesChanged));
        p.appendChild(r);
      }
      grid.appendChild(p);
    }
    drawBoxNames();
  }
  function drawBoxNames() {
    const q = $("boxq").value.trim().toLowerCase();
    const table = $("boxnames");
    const head = el("tr");
    for (const h of ["場所（家・階）", "箱の種類", "番号", "開いた位置", "中の数", "名前"]) head.appendChild(el("th", "", h));
    table.replaceChildren(head);
    const list = boxes.filter(b => !b.engraving && !b.locker).filter(b => !q || (b.name + b.id + houseName(b.top.house)).toLowerCase().includes(q));
    list.sort((a, b) => a.top.house - b.top.house || a.floor - b.floor || a.x - b.x || a.y - b.y);
    for (const b of list.slice(0, 300)) {
      const tr = el("tr");
      for (const v of [houseName(b.top.house) + " " + floorName(b.top.house, b.floor), b.name, b.id, b.x + "," + b.y, b.direct]) tr.appendChild(el("td", "", String(v)));
      const cell = el("td");
      // Same as a house's: no name box until the record's number has been given to a character.
      // Under 全部を見る, a name borrowed from another pair (sharedBoxName) is in the box's placeholder,
      // with whose it is: the box stays empty, since this pair has not named it, and what is typed is kept under
      // this pair.
      const borrowed = sharedBoxKey(b);
      const hint = borrowed ? borrowed.split(PAIR_SEP)[0] + " の名前: " + names.boxes[borrowed] : "例: 1階 西の壁 左から2番目";
      if (namesPairOf(b) === PAIR_UNASSIGNED) cell.appendChild(el("span", "hint", "割り当て後に名前を付けられます"));
      else cell.appendChild(nameInput("boxes", boxNameKey(b), hint, () => { run(); drawTodo(); }));
      tr.appendChild(cell);
      table.appendChild(tr);
    }
  }

  // ---- wiring
  let typing = 0;
  const debounce = fn => { clearTimeout(typing); typing = setTimeout(fn, 150); };
  $("q").addEventListener("input", e => debounce(() => { state.q = e.target.value.trim().toLowerCase(); state.limit = PAGE_SIZE; run(); }));
  $("lineq").addEventListener("input", e => debounce(() => { state.lineq = e.target.value.trim().toLowerCase().split(/\s+/).filter(Boolean); state.limit = PAGE_SIZE; run(); }));
  $("sort").addEventListener("change", e => { state.sort = e.target.value; run(); });
  $("boxq").addEventListener("input", drawBoxNames);
  $("clear").addEventListener("click", () => {
    state.q = ""; state.lineq = [];
    $("q").value = ""; $("lineq").value = "";
    state.houses.clear(); state.floors.clear(); state.conds = [];
    for (const spec of FRAMED_FILTERS.values()) clearFramedFilter(spec.key);   // The locker's filter as well (and the others')
    drawPlaces(); drawConds(); drawPickers();
    state.limit = PAGE_SIZE;
    run();
  });
  // The pair to look at. It is kept in the names file, so the page opens where it was left,
  // and everything is built again from the records of that pair alone.
  $("pair").addEventListener("change", e => {
    state.pair = e.target.value;
    names.view.pair = state.pair;
    saveNamesSoon();
    state.limit = PAGE_SIZE;
    state.houses.clear();
    state.floors.clear();
    rebuild();
  });
  // Where the records folder is: 変える opens and closes the form, ［決める］ or Enter sends the place.
  $("folderChange").addEventListener("click", () => {
    folderOpened = !folderOpened;
    drawFolderForm();
    if (folderOpened) $("folderPath").focus();
  });
  const sendFolder = () => setFolder().catch(e => {
    $("folderMsg").textContent = "記録のフォルダを変える途中で問題が起きました（" + String(e && e.message || e) + "）。";
  });
  $("folderSet").addEventListener("click", sendFolder);
  $("folderPath").addEventListener("keydown", e => { if (e.key === "Enter") sendFolder(); });
  // Where the records that carry no number belong.
  $("tidy").addEventListener("click", () => tidyAsk());
  $("legacyPair").addEventListener("change", e => {
    if (!e.target.value) return;
    movePlaceNames(legacyPair(), e.target.value);  // the names of those records' places go with them
    names.view.legacy = e.target.value;
    migrateNames();
    saveNamesSoon();
    rebuild();
  });

  // The sticky parts sit right under the header and the tabs, whatever their height (the header wraps on
  // narrow screens).
  measureHeader();
  window.addEventListener("resize", measureHeader);
  // ▲ and ▼ change shape with the width as well (hidden, the narrow layout alone has them one above the other):
  // a window widened past 1200px with the conditions hidden left --jump at their height one above the other.
  window.addEventListener("resize", measureJump);
  // The kinds of box: last in the panel of conditions, but in the FHD form (window.cplusForm, set up in the
  // head) at the top of the results' column, where they are held with 選択した検索条件: the panel is too low there for them
  // and what is searched by together. The form changes with the window's height; 一番上へ／一番下へ change with it (side
  // by side in the FHD form), so their height is measured again.
  function placeKinds() {
    (window.cplusForm.fhd ? $("kindsTop") : $("condsPanel")).appendChild($("kindbox"));
  }
  placeKinds();
  measureJump();
  window.cplusForm.onChange(() => { placeKinds(); measureJump(); });
  // 表示: ダーク / ライト / 自動 (window.cplusTheme is set up in the head, before the page draws).
  const themeEl = $("theme");
  themeEl.value = window.cplusTheme.choice;
  themeEl.addEventListener("change", () => window.cplusTheme.set(themeEl.value));
  // 条件を隠す / 条件を出す (window.cplusConds is set up in the head). The html's rules show the button and
  // hide the panel only in the narrow layout, so a wide window always has the panel whatever was chosen here.
  const condsToggle = $("condsToggle");
  // Its title says what pressing it does now, as its words do.
  const drawCondsToggle = () => {
    const hidden = window.cplusConds.hidden;
    condsToggle.textContent = hidden ? "条件を出す" : "条件を隠す";
    condsToggle.title = hidden ? "左の検索条件の枠を出します（狭い窓のときだけ）" : "左の検索条件の枠を隠して、結果を全幅にします（狭い窓のときだけ）";
  };
  drawCondsToggle();
  condsToggle.addEventListener("click", () => {
    window.cplusConds.set(!window.cplusConds.hidden);
    drawCondsToggle();
    // Hidden, ▲ and ▼ are one above the other again; shown in the FHD form, side by side.
    measureJump();
  });
  // Jump to the top (conditions, 条件の消去) or the bottom (さらに表示) of a long list.
  $("toTop").addEventListener("click", () => window.scrollTo({ top: 0, behavior: "smooth" }));
  $("toBottom").addEventListener("click", () => window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "smooth" }));
  // Each tab comes back where it was left. The tabs stay at the top, so
  // they can be pressed from far down a long list, and the tab pressed would otherwise open wherever that list had
  // got to. A tab not opened yet starts at its head; the places are kept while the page is open only, and pressing
  // the tab already shown does not move. 名前の設定 is drawn again once /api/chars answers, so it goes back after
  // that: before, the page can still be too short for the place. then: where to go instead, once drawn (the
  // unassigned bar's 割り当てる, which would otherwise be undone by going back).
  const tabScroll = new Map();
  let tabShown = "search";
  let tabPlaced = true;   // whether the tab shown has been put in its place yet (the page opens at the head of 検索)
  function showTab(tab, then) {
    const moved = tab !== tabShown;
    // Only a tab that has been put in its place is noted on leaving it. 名前の設定 is put there once
    // /api/chars answers; left before that, the place on the screen is still the tab before's, and noting it would
    // send 名前の設定 there next time. Its note stays as it was: the head, or where it was left.
    if (moved) {
      if (tabPlaced) tabScroll.set(tabShown, window.scrollY || 0);
      tabPlaced = false;
    }
    tabShown = tab;
    document.querySelectorAll("nav.tabs button").forEach(b => b.classList.toggle("on", b.dataset.tab === tab));
    for (const id of ["search", "todo", "names"]) $("tab-" + id).hidden = tab !== id;
    const place = () => {
      if (tabShown !== tab) return;   // another tab was pressed meanwhile
      if (then) then();
      else if (moved) window.scrollTo({ top: tabScroll.get(tab) || 0 });
      tabPlaced = true;
    };
    // A character made since the page was opened is there the next time the tab is.
    if (tab === "names") loadChars().then(ok => { if (ok) { drawAssign(); } }).finally(place);
    else place();
  }
  document.querySelectorAll("nav.tabs button").forEach(btn => btn.addEventListener("click", () => showTab(btn.dataset.tab)));

  // New records while the page is shown, and at once on coming back to it.
  const shown = () => document.visibilityState !== "hidden";
  setInterval(() => { if (shown()) refresh(); }, POLL_MS);
  window.addEventListener("focus", () => refresh());
  document.addEventListener("visibilitychange", () => { if (shown()) refresh(); });
  drawConds();
  drawNotLoaded();
  // The characters of this PC before the first records are put together: the pair of a record is known
  // from the first draw, rather than everything landing in 未割り当て for a moment.
  loadChars().then(() => refresh(), () => refresh());
})();
