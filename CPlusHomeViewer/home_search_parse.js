// Reads the files CPlusHomeRecord writes (logs/CPlusExport/home<house>_[<clock>]_<box id>_<serial>.txt) and
// puts them together into boxes and items. No DOM here: the page uses it as the global CPlusHomeParse, and
// Node can require it.
//
// A file, one record per line, fields separated by TAB (CPlusHomeRecord.lua writes it):
//   CPLUS_HOME_RECORD <format>      the file log puts "[yy/mm/dd][hh:mm:ss] " in front of this first line
//   char <the character's own number> [<the character's name, titles and all>]   (not in the
//                                   records of older versions, which are read without it. The name is
//                                   left off when the client could not tell it was this character's)
//   box <id> <parent box id, 0 = on the floor> <house>
//   pos <x> <y> <z> <facet>         where the player stood when the box was opened
//   area <house> <facet> <min x> <max x> <min y> <max y>
//                                   the house the record was made in, as the character that wrote it had
//                                   registered it (not in the records of older versions, nor in one
//                                   whose house was cleared while the box was open)
//   time <opened> <closed>          yyyymmdd-hhmmss
//   boxprop <tid> <text>            the box's property lines; the first one is its name
//   boxparams @<tid> <value>...     the values of those lines, each line's after its @<tid>
//   item <id> <objectType> <hue> <quantity> <name> [<base name>: format 2]
//   prop <tid> <text>               the item's property lines; the first one is its name line
//   params @<tid> <value>...
//   count <items> <items without properties>
//   END
// A scroll book (its scrolls shown in a gump of their own, with no object id) is written with the same head
// and records of its own instead of items:
//   book      <the kind's tid> <buttons> <presses> <skills read> <every skill read 0/1> <skills in the book, or ->
//                                   after time. The last field is not in the records of older versions, which
//                                   are read without it
//   booktier  <the grade's tid> <its text>              the grades, in the order they stand
//   bookskill <the skill's tid> <its text> <count>...   one a skill, the counts in the grades' order
//   bookgroup <the skill's tid> <its tab 1-7> <its place in the tab>
//                                   the tab of the game's skills window the skill is in and its place there,
//                                   written by the module from the game's own table when it wrote the book.
//                                   A skill with none (an older version's record, or one the module could not
//                                   look up) has no group, and the page shows it as 分類なし
// Such a record is read as a box whose contents are its grades and skills: it has no item lines,
// and its scrolls have no object id of their own. Whether a book is read to the end is worked out here from
// its records laid over each other (stackedBook).
// A cabinet - a jewel box, a dye tub cabinet, an armour refinement cabinet: its contents shown in a gump,
// 50 to a page - is written the same way, with two records more (a reader that does not know
// them passes over them):
//   jewelbox <pages seen> <pages> <items gathered> <items in the box> <kind>   after time: the pages and
//                                   the items in the box as the gump's labels said, and the kind of cabinet
//                                   (the tid of the name in its gump's title). A record written before the
//                                   kind was in it has four fields and is a jewel box's.
//   jewelpage <page>...             after an item's params: the pages the item was seen on
// A cabinet item's objectType and hue are its ObjectInfo's where it has one (the dye tub cabinet's items
// do); where it has none they are read from the name line, and are "-" when the line does not name the
// base item.
// A Davies' locker (its treasure maps and SOS shown in a gump of its own, with no object id) is written
// with the same head and records of its own instead of items. Its box is the block the player used when that
// could be confirmed and 0 when not; the records of one house's locker are put together by the house, whatever
// their box (combine):
//   locker     <pages seen> <pages> <rows read> <maps and SOS held> <room> <box confirmed 1/0> <title>   after time
//   lockerrow  <page, or -> <map or sos> <coordinates> <facet tid> <facet> <「〜の」 tid> <「〜の」>
//              <grade tid> <grade> <status tid> <status>      a SOS's 「〜の」 and grade are "-"
//   lockerodd  <page, or -> <the text of each label>...      a row of no shape the Lua knows, kept as it was
// Whether the locker was read to the end is worked out here (lockerComplete).
// Lines end in CRLF. A bare LF inside a line is a <br> the file log turned into LF (format 1), so it is
// read as a space, never as a line end.
"use strict";

const CPlusHomeParse = (function () {
  const FORMAT_TAG = "CPLUS_HOME_RECORD";
  // The kind of a cabinet whose record does not say: the tid of the jewel box's name, the only cabinet the
  // records written before the kind could hold. CPlusHomeRecord.lua reads it from the gump's
  // title (measured: #1157694 the jewel box, #1164139 the dye tub, #1165086 the armour refinement cabinet).
  const KIND_JEWEL_BOX = 1157694;
  const FORMATS = ["1", "2"];
  const FIRST_LINE_PREFIX = /^\[\d\d\/\d\d\/\d\d\]\[\d\d:\d\d:\d\d\] /;
  // A value inside a param field. The decimal is kept (a weapon speed of 2.5 stays 2.5).
  const VALUE = /-?\d+(?:\.\d+)?/;

  const TID_ENGRAVING = 1072305;
  // A container's "Contents: n/125" line; its first value is how many things are in it.
  const TIDS_CONTENTS = [1073841, 1072241];

  // The tid of an item's base name from its objectType: below 16384 from 1020000, from 16384 on from
  // 1078872. Checked in game with GetStringFromTid on 13 types, the same rule as
  // CPlusHomeRecord.lua writes into format 2.
  const BASE_NAME_TID_LOW = 1020000;
  const BASE_NAME_TID_HIGH = 1078872;
  const BASE_NAME_HIGH_FROM = 16384;

  // Floors of a house: the heights of the boxes standing in it (not inside another box), sorted; a gap of
  // 10 or more starts the next floor. A storey is 20 apart in the records (for instance 14, 34 and 35, 54),
  // and a box on a shelf or a table stands a few above its floor.
  const FLOOR_GAP = 10;

  function baseNameTid(objectType) {
    return (objectType < BASE_NAME_HIGH_FROM ? BASE_NAME_TID_LOW : BASE_NAME_TID_HIGH) + objectType;
  }

  // Text as the page shows it and matches it: marks such as <BASEFONT ...> and <CENTER> taken out
  // (<br> and <p> become a space), and runs of spaces made one.
  function cleanText(text) {
    return String(text || "")
      .replace(/<(?:br|p)\s*\/?>/gi, " ")
      .replace(/<[^>]*>/g, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  const wholeNumber = s => (/^-?\d+$/.test(s || "") ? Number(s) : null);

  // A scroll book skill's group: the first bookgroup line for its tid, as { tab, order } - the tab of the
  // game's skills window, 1 to 7, and the skill's place in it from 1 - or null where there is none or its
  // numbers are not those.
  function bookGroupOf(rows, tid) {
    if (tid === null) return null;
    const row = rows.find(r => wholeNumber(r[1]) === tid);
    if (!row) return null;
    const tab = wholeNumber(row[2]), order = wholeNumber(row[3]);
    return tab !== null && tab >= 1 && tab <= 7 && order !== null && order >= 1 ? { tab, order } : null;
  }

  // An area: the facet, then x from and to, then y from and to - five fields, the way the record's
  // area line and the page's own table of houses both hold it. { facet, minX, maxX, minY, maxY }, or null
  // when a field is not a whole number of 0 or more, or a from is past its to: such an area is read as none,
  // as a record without the line is.
  const nonNegative = s => (/^\d+$/.test(s || "") ? Number(s) : null);
  function readArea(fields) {
    const [facet, minX, maxX, minY, maxY] = [0, 1, 2, 3, 4].map(i => nonNegative(fields[i]));
    if ([facet, minX, maxX, minY, maxY].some(v => v === null) || minX > maxX || minY > maxY) return null;
    return { facet, minX, maxX, minY, maxY };
  }
  // A record's area line: its house number (the character's own, 1 or more) and the area. null as above.
  function areaOf(row) {
    if (!row) return null;
    const n = nonNegative(row[1]);
    const area = readArea(row.slice(2));
    return n !== null && n >= 1 && area ? Object.assign({ n }, area) : null;
  }

  function rowsOf(text) {
    const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
    const lines = body.split("\r\n");
    lines[0] = lines[0].replace(FIRST_LINE_PREFIX, "");
    return lines.filter(line => line !== "").map(line => line.replace(/\n/g, " ").split("\t"));
  }

  // Property lines with their values. The params are grouped by their @<tid>; each line takes the first
  // group of its own tid not taken yet, so two lines with the same tid get their values in order.
  //
  // v holds the numbers of the line ( 「幸運 200」 -> [200] ). A param written #<tid> is not a number but
  // the name of another text ( an armour refining agent's name line says which kind and which grade it is that
  // way ). They are kept in ids, in the order written, and never mixed into v.
  function linesWithValues(lineRows, params) {
    const groups = [];
    for (const field of params) {
      if (field.startsWith("@")) {
        groups.push({ tid: field.slice(1), values: [], ids: [], taken: false });
      } else if (groups.length && field.startsWith("#")) {
        const id = wholeNumber(field.slice(1));
        if (id !== null) groups[groups.length - 1].ids.push(id);
      } else if (groups.length) {
        const m = VALUE.exec(field);
        if (m) groups[groups.length - 1].values.push(Number(m[0]));
      }
    }
    return lineRows.map(row => {
      const tid = row[1] || "";
      const group = groups.find(g => !g.taken && g.tid === tid);
      if (group) group.taken = true;
      return { t: wholeNumber(tid) || 0, x: cleanText(row[2]), v: group ? group.values : [],
        ids: group ? group.ids : [] };
    });
  }

  // One file. Returns { status: "ok", format, box, items }, { status: "partial", reason } for a file with
  // no END (read while it was being written: try again later), or { status: "unreadable", reason }.
  function parseRecord(text) {
    const rows = rowsOf(String(text || ""));
    if (!rows.length || rows[0][0] !== FORMAT_TAG) return { status: "unreadable", reason: "家の記録ではありません" };
    const format = rows[0][1] || "";
    if (!FORMATS.includes(format)) return { status: "unreadable", reason: "形式 " + format + " は読めません" };
    if (rows[rows.length - 1][0] !== "END") return { status: "partial", reason: "終わりの行（END）がありません" };

    let boxRow = null, posRow = [], timeRow = [], jewelRow = null, boxLines = [], boxParams = [], bookRow = null, charRow = null, areaRow = null;
    const bookTierRows = [], bookSkillRows = [], bookGroupRows = [];
    // A Davies' locker's: its locker line, and its rows in the order written.
    let lockerRow = null;
    const lockerRows = [];
    const items = [];
    let item = null;
    for (const row of rows.slice(1)) {
      switch (row[0]) {
        case "box": boxRow = row; break;
        case "char": charRow = row; break;
        case "pos": posRow = row; break;
        case "area": areaRow = row; break;
        case "time": timeRow = row; break;
        case "jewelbox": jewelRow = row; break;
        case "book": bookRow = row; break;
        case "booktier": bookTierRows.push(row); break;
        case "bookskill": bookSkillRows.push(row); break;
        case "bookgroup": bookGroupRows.push(row); break;
        case "locker": lockerRow = row; break;
        case "lockerrow": case "lockerodd": lockerRows.push(row); break;
        case "boxprop": boxLines.push(row); break;
        case "boxparams": boxParams = row.slice(1); break;
        case "item":
          item = { row, lines: [], params: [], pages: [] };
          items.push(item);
          break;
        case "prop": if (item) item.lines.push(row); break;
        case "params": if (item) item.params = row.slice(1); break;
        case "jewelpage": if (item) item.pages = row.slice(1).map(wholeNumber).filter(n => n !== null); break;
        default: break; // count, END, and rows this page does not know
      }
    }
    if (!boxRow) return { status: "unreadable", reason: "箱の行がありません" };

    const lines = linesWithValues(boxLines, boxParams);
    const engraving = lines.find(l => l.t === TID_ENGRAVING);
    const contents = lines.find(l => TIDS_CONTENTS.includes(l.t) && l.v.length);
    const box = {
      id: boxRow[1] || "",
      parent: boxRow[2] || "0",
      house: wholeNumber(boxRow[3]),
      x: wholeNumber(posRow[1]), y: wholeNumber(posRow[2]), z: wholeNumber(posRow[3]), facet: wholeNumber(posRow[4]),
      // The house the record was made in: { n, facet, minX, maxX, minY, maxY }, or null.
      area: areaOf(areaRow),
      opened: timeRow[1] || "",
      closed: timeRow[2] || "",
      // A locker has no property lines of its own in its record: its name is the title its gump gave.
      name: lines.length ? lines[0].x : (lockerRow ? cleanText(lockerRow[7]) : ""),
      engraving: engraving ? engraving.x.replace(/^[^:：]*[:：]\s*/, "") : "",
      contents: contents ? contents.v[0] : null,
      // A cabinet's: { pagesSeen, pages, itemsSeen, items, kind }, each a number or null. null for any
      // other box. kind is the tid of the name in the gump's title, which is what tells one kind of
      // cabinet from another; a record from before it was written (four fields) is a jewel box's.
      // Which character wrote the record: { id, name }, the number first and the name - titles
      // and all - last, since it is the field that holds spaces. The name is null on a line that has only
      // the number, which CPlusHomeRecord writes when the paperdoll's name was someone else's or unreadable;
      // null altogether for a record that does not say at all, which is every record written
      // by an older version.
      // The number must be one the writer would write: it refuses 0 and less, so a line carrying one is
      // not a character here either - one side alone deciding that is how the two drift apart.
      char: charRow && wholeNumber(charRow[1]) > 0
        ? { id: wholeNumber(charRow[1]), name: cleanText(charRow[2]) || null } : null,
      // A scroll book's: the kind (the tid of the name in its gump's title),
      // what the reading came to, the grades in the order they stand, and a skill a line - its counts in
      // the grades' order, one for every grade, 0 where the book holds none of it. A count that could not
      // be read is null. total is how many skills the book holds scrolls of, null where the record could not
      // count them or is of an older version. A skill's group is its bookgroup line's tab and place
      // ({tab, order}), null where it has none or the line's numbers cannot be read.
      // null for any box that is not a scroll book.
      book: bookRow ? {
        kind: wholeNumber(bookRow[1]),
        buttons: wholeNumber(bookRow[2]),
        presses: wholeNumber(bookRow[3]),
        read: wholeNumber(bookRow[4]),
        done: bookRow[5] === "1",
        total: wholeNumber(bookRow[6]),
        tiers: bookTierRows.map(row => ({ tid: wholeNumber(row[1]), text: cleanText(row[2]) })),
        skills: bookSkillRows.map(row => ({
          tid: wholeNumber(row[1]), text: cleanText(row[2]), counts: row.slice(3).map(wholeNumber),
          group: bookGroupOf(bookGroupRows, wholeNumber(row[1])),
        })),
      } : null,
      jewel: jewelRow ? {
        pagesSeen: wholeNumber(jewelRow[1]), pages: wholeNumber(jewelRow[2]),
        itemsSeen: wholeNumber(jewelRow[3]), items: wholeNumber(jewelRow[4]),
        kind: wholeNumber(jewelRow[5]) === null ? KIND_JEWEL_BOX : wholeNumber(jewelRow[5]),
      } : null,
      // A Davies' locker's: the pages seen and the pages, the rows read, the maps and SOS it holds and its
      // room, whether its box was confirmed as the block used, its title, and its rows - each with its page (null
      // where the page was not read). A row is a map's, a SOS's (no 「〜の」 and no grade: null and "") or one of no
      // shape, which keeps the text of its labels. A number that could not be read is null. null for anything that
      // is not a locker.
      locker: lockerRow ? {
        seen: wholeNumber(lockerRow[1]), pages: wholeNumber(lockerRow[2]), read: wholeNumber(lockerRow[3]),
        count: wholeNumber(lockerRow[4]), room: wholeNumber(lockerRow[5]), confirmed: lockerRow[6] === "1",
        title: cleanText(lockerRow[7]),
        rows: lockerRows.map(r => (r[0] === "lockerodd"
          ? { page: wholeNumber(r[1]), kind: "odd", texts: r.slice(2).map(cleanText) }
          : { page: wholeNumber(r[1]), kind: r[2] === "sos" ? "sos" : "map", coords: cleanText(r[3]),
            facetTid: wholeNumber(r[4]), facet: cleanText(r[5]),
            prefixTid: wholeNumber(r[6]), prefix: wholeNumber(r[6]) === null ? "" : cleanText(r[7]),
            tierTid: wholeNumber(r[8]), tier: wholeNumber(r[8]) === null ? "" : cleanText(r[9]),
            statusTid: wholeNumber(r[10]), status: cleanText(r[11]) })),
      } : null,
    };
    return {
      status: "ok",
      format,
      box,
      items: items.map(({ row, lines: itemLines, params, pages }) => ({
        id: row[1] || "",
        type: wholeNumber(row[2]),
        hue: wholeNumber(row[3]),
        qty: wholeNumber(row[4]),
        name: cleanText(row[5]),
        base: cleanText(row[6]), // format 2 only; empty in format 1
        props: linesWithValues(itemLines, params),
        pages, // a jewel box's item's; empty for any other
      })),
    };
  }

  // Which of two records of the same thing is the newer: the later closing time, then the newer file.
  function newer(a, b) {
    if (a.parsed.box.closed !== b.parsed.box.closed) return a.parsed.box.closed > b.parsed.box.closed;
    if (a.mtime !== b.mtime) return a.mtime > b.mtime;
    return a.name > b.name;
  }

  // Base names by objectType: format 2's own field first, then an item whose name line is its base name
  // (its tid is the base name tid).
  function learnBaseNames(records) {
    const names = new Map();
    for (const rec of records) {
      for (const it of rec.parsed.items) if (it.type !== null && it.base && !names.has(it.type)) names.set(it.type, it.base);
    }
    for (const rec of records) {
      for (const it of rec.parsed.items) {
        if (it.type === null || names.has(it.type) || !it.props.length) continue;
        if (it.props[0].t === baseNameTid(it.type) && it.props[0].x) names.set(it.type, it.props[0].x);
      }
    }
    return names;
  }

  const containerCount = it => {
    const line = it.props.find(l => TIDS_CONTENTS.includes(l.t) && l.v.length);
    return line ? line.v[0] : null;
  };

  // Floors of each house from the boxes standing in it: Map house -> [{ n, min, max }], n from 1 upwards.
  // The floors of a house, one world at a time: a house number is that world's, so two worlds' house 1
  // are two houses and their heights must not be put in one pile. The key is "<world>\u0000<house>".
  // (Under 全部を見る the world is a shard, and one shard's house of one number is counted as one house
  // whichever account's boxes stand in it.)
  function floorsOf(boxes) {
    const heights = new Map();
    for (const b of boxes) {
      if (b.top !== b || b.z === null) continue;
      const key = floorKey(b.world, b.house);
      if (!heights.has(key)) heights.set(key, new Set());
      heights.get(key).add(b.z);
    }
    const floors = new Map();
    for (const [house, zs] of [...heights].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))) {
      const list = [];
      for (const z of [...zs].sort((a, b) => a - b)) {
        const last = list[list.length - 1];
        if (!last || z - last.max >= FLOOR_GAP) list.push({ n: list.length + 1, min: z, max: z });
        else last.max = z;
      }
      floors.set(house, list);
    }
    return floors;
  }

  // The records of one jewel box to read, newest first: a jewel box's record holds only the pages that were turned
  // while it was open, so the newest one alone loses what an earlier one saw. They are laid over each other back
  // to the record that saw every page and read as many items as the box says it holds - older than that, the box
  // held what it held before it was last seen whole, which is not worth showing. Without such a record, every
  // readable one is used; a record with any of the four numbers unreadable is not one. Every page turned is not
  // enough. A turned page's items can still fail to come through: a cabinet's record can turn every page and read
  // only part of the items, some pages empty. Stopping there would drop the missing items from the page, and the
  // tidying would delete the older record that held them, since the page would be the same without it. Items taken
  // out lower the box's own count too, so a record made after that still reaches it and stops here.
  function jewelStack(recs) {
    const used = [];
    for (const rec of recs) {
      used.push(rec);
      const j = rec.parsed.box.jewel;
      if (j && j.pagesSeen !== null && j.pages !== null && j.pagesSeen >= j.pages &&
        j.itemsSeen !== null && j.items !== null && j.itemsSeen >= j.items) break;
    }
    return used;
  }

  // The records of one scroll book to read, newest first. A record that did not read every skill on its own
  // (its book line's every-skill field 0) holds only the skills whose pages were opened, so the records before it
  // are laid under it, back to the last one that did - older than that, the book held what it held before it was
  // last read whole. The same shape as jewelStack, for the same reason.
  function bookStack(recs) {
    const used = [];
    for (const rec of recs) {
      used.push(rec);
      const book = rec.parsed.box.book;
      if (book && book.done) break;
    }
    return used;
  }

  // One book out of those records: the newest record's word for everything it has, the older ones filling
  // in only the skills it never reached (a skill is kept from the newest record that holds it, and carries
  // from when that is not the newest record of all). The grades come from the newest record that has any;
  // a reading writes them from the first answer it reads, so a record that got that far has them all.
  // **Whether the book is read to the end is decided here and nowhere else**, on the records laid over each
  // other, never on one record alone: a book is read a skill's page at a time, in as many openings as the player
  // likes. total is how many skills the book holds scrolls of, the newest record's that could count them, and
  // held how many skills the records laid over each other hold a scroll of (a skill whose newest reading holds
  // none - its last scroll just taken out - is not one: it has no page left to open). done: held reaches total;
  // where no record could count them, whether one of the records laid over each other read every skill on its
  // own (a record of an older version, which counted none). Without either, the book is not covered - the page
  // says so rather than showing part of a book as though it were the whole of it.
  function stackedBook(recs) {
    const used = bookStack(recs);
    const newest = used[0].parsed.box.book;
    const skills = [];
    const bySkill = new Map();
    for (const rec of used) {
      const book = rec.parsed.box.book;
      if (!book) continue;
      for (const s of book.skills) {
        if (s.tid === null || bySkill.has(s.tid)) continue;
        const copy = Object.assign({}, s, {
          from: rec === used[0] ? null : { closed: rec.parsed.box.closed, file: rec.name },
        });
        bySkill.set(s.tid, copy);
        skills.push(copy);
      }
    }
    const withTiers = used.find(rec => rec.parsed.box.book && rec.parsed.box.book.tiers.length);
    const counted = used.find(rec => rec.parsed.box.book && rec.parsed.box.book.total !== null);
    const total = counted ? counted.parsed.box.book.total : null;
    const held = skills.filter(s => s.counts.some(n => n !== null && n > 0)).length;
    return Object.assign({}, newest, {
      tiers: withTiers ? withTiers.parsed.box.book.tiers : [],
      skills,
      stacked: held,                                             // the skills the records come to together
      records: used.length,                                      // how many were laid over each other
      total,
      done: total !== null ? held >= total : used.some(rec => rec.parsed.box.book && rec.parsed.box.book.done),
    });
  }

  // A Davies' locker's record read to the end - **decided here and nowhere else**: every page
  // seen (as many pages seen as the locker has) and every row read (as many as it holds). A number that could not be
  // read ("-") is not enough.
  function lockerComplete(locker) {
    return !!locker && locker.pages !== null && locker.seen !== null && locker.seen >= locker.pages &&
      locker.count !== null && locker.read !== null && locker.read >= locker.count;
  }
  // Whether a later record of a locker shows nothing that has changed since a reading to the end, whole: the same
  // count held, every row on a numbered page no further than whole's pages, and every page it saw holding the very
  // same rows as whole's page of that number, in the same order. A record with no row has changed.
  const lockerRowKey = r => JSON.stringify([r.kind, r.coords, r.facetTid, r.prefixTid, r.tierTid, r.statusTid, r.texts || null]);
  function lockerPagesOf(locker) {
    const pages = new Map();
    for (const r of locker.rows) {
      if (!pages.has(r.page)) pages.set(r.page, []);
      pages.get(r.page).push(lockerRowKey(r));
    }
    return pages;
  }
  function lockerUnchanged(later, whole) {
    const locker = later.parsed.box.locker, was = whole.parsed.box.locker;
    if (!locker || locker.count === null || locker.count !== was.count || !locker.rows.length) return false;
    const before = lockerPagesOf(was);
    for (const [page, rows] of lockerPagesOf(locker)) {
      if (page === null || page < 1 || page > was.pages) return false;
      const then = before.get(page) || [];
      if (rows.length !== then.length || rows.some((r, i) => r !== then[i])) return false;
    }
    return true;
  }
  // The record of one house's locker to show, out of its records sorted newest first: the newest, unless it was not
  // read to the end and nothing has changed since the newest reading that was - a locker opened at its first page and
  // closed writes such a record, and it must not hide the whole locker behind a red warning. Then that reading. The
  // records are never laid over each other: a map taken out moves every row after it.
  function lockerChosen(recs) {
    if (lockerComplete(recs[0].parsed.box.locker)) return recs[0];
    const at = recs.findIndex(rec => lockerComplete(rec.parsed.box.locker));
    if (at < 0) return recs[0];
    return recs.slice(0, at).every(rec => lockerUnchanged(rec, recs[at])) ? recs[at] : recs[0];
  }
  // The record to show out of one thing's records sorted newest first: a locker's as above, anything else's the
  // newest. The same choice decides what 整理削除 keeps (home_search.js olderRecords).
  const chosenOf = recs => (recs[0].parsed.box.locker ? lockerChosen(recs) : recs[0]);

  // What makes two records "the same box".
  //
  // A box's number is unique on its own shard. **It is not unique across shards**: two worlds may both
  // hold a box numbered 1101, and nothing measured here says otherwise - records from one shard
  // alone cannot show the case. Taking the number alone would put the two boxes
  // together: the newer record would win, and the other world's box - with everything in it - would be
  // gone from 全部を見る without a word. That is the kind of wrong nobody notices, so the number is
  // never used on its own.
  //
  // world(rec) gives whatever tells the records of one world from another's ( the page passes the
  // account and the shard while one pair is looked at, and the shard alone under 全部を見る: there
  // two accounts' records of one shard's box are that one box; anything that does not care passes nothing
  // and gets the number alone as the key ).
  // Everything keyed by a box or an item - which records are of one box, which box holds an item, which
  // box is the parent, the floors of a house - is keyed by the world and the number together.
  const NOT_HERE = "\u0000";
  const worldOf = (world, rec) => (world ? world(rec) : "");
  // How a box is asked for: that world's box of that number, never a number on its own. The same for
  // the floors of a house, which are one world's house.
  const boxKey = (world, id) => (world || "") + NOT_HERE + id;
  const floorKey = (world, house) => (world || "") + NOT_HERE + house;
  // A Davies' locker is one a house: whichever of its blocks was
  // opened - the record's box - the records of one world's house are of one locker. Two lockers in one house are
  // shown as one. The key can be no box's: a box's number has no NOT_HERE in it.
  // The house is told by its area - the facet and the range of the house the page found the record in
  // (houseArea, home_search.js houseOf) - not by its number, which is one pair's: under 全部を見る the world is the
  // shard, and two pairs' house 1 can be two houses, or one house can be one pair's 1 and another's 2.
  // Only a record whose house the page decided by its own number (houseArea null: no house of the table holds
  // it) is told by that number. box: the record's box with house and houseArea as the page gave them - the one
  // function the reading (combine) and 整理削除 (home_search.js olderRecords) both key a locker by.
  const lockerKey = (world, box) => boxKey(world, "locker" + NOT_HERE + (box.houseArea
    ? "area " + [box.houseArea.facet, box.houseArea.minX, box.houseArea.maxX, box.houseArea.minY, box.houseArea.maxY].join(" ")
    : "house " + box.house));

  // Puts the readable records together. records: [{ name, mtime, parsed }] with parsed.status "ok".
  //  - A box recorded more than once is read from its newest record only; a jewel box's older records are
  //    laid under it as well (jewelStack), and an item from one of those carries from, and so are a scroll book's
  //    (stackedBook).
  //  - An item in more than one of those records is placed in the newest one (it was moved there).
  //  - A missing base name is taken from another item of the same objectType.
  // Returns { boxes, items, floors }. Boxes carry top (the box standing on the floor that holds them,
  // themselves when they stand on the floor), floor, direct (items directly in them) and nested (what
  // the containers among those say they hold); items carry box (its id), house and floor.
  //  - A Davies' locker's records are of one locker a house, whatever their box (lockerKey), and it is read
  //    from one record as a book is: lockerChosen's.
  function combine(records, world) {
    const keyOfRecord = rec => (rec.parsed.box.locker ? lockerKey(worldOf(world, rec), rec.parsed.box)
      : boxKey(worldOf(world, rec), rec.parsed.box.id));
    const byBox = new Map();
    for (const rec of records) {
      const key = keyOfRecord(rec);
      if (!byBox.has(key)) byBox.set(key, []);
      byBox.get(key).push(rec);
    }
    const chosen = [];
    const used = [];
    for (const recs of byBox.values()) {
      recs.sort((a, b) => (newer(a, b) ? -1 : newer(b, a) ? 1 : 0));
      const shown = chosenOf(recs);
      chosen.push(shown);
      for (const rec of recs[0].parsed.box.jewel ? jewelStack(recs) : [shown]) used.push(rec);
    }
    const top = new Map(chosen.map(rec => [keyOfRecord(rec), rec]));

    // An item's number, like a box's, is one world's. The same number in two worlds is two things.
    const owner = new Map();
    for (const rec of used) {
      for (const it of rec.parsed.items) {
        const key = boxKey(worldOf(world, rec), it.id);
        const cur = owner.get(key);
        if (!cur || newer(rec, cur.rec)) owner.set(key, { rec, it });
      }
    }

    const boxes = chosen.map(rec => {
      const counts = rec.parsed.items.map(containerCount).filter(n => n !== null);
      return Object.assign({}, rec.parsed.box, {
        // Which world this box is in, and the key that stands for it there. id is left as it is: the
        // game knows nothing of worlds, so the line for the game carries the number alone.
        world: worldOf(world, rec),
        key: keyOfRecord(rec),
        file: rec.name,
        direct: rec.parsed.items.length,
        nested: counts.reduce((sum, n) => sum + n, 0),
        // A copy, with how many items the records laid over each other come to (stacked, filled in below).
        jewel: rec.parsed.box.jewel ? Object.assign({}, rec.parsed.box.jewel, { stacked: 0 }) : null,
        // A scroll book: the records of this book laid over each other (stackedBook), newest first.
        book: rec.parsed.box.book ? stackedBook(byBox.get(keyOfRecord(rec))) : null,
      });
    });
    const boxById = new Map(boxes.map(b => [b.key, b]));
    for (const b of boxes) {
      const seen = new Set([b.key]);
      let top = b;
      // The parent is a number of the same world, so it is looked up with that world in front of it.
      while (top.parent !== "0" && boxById.has(boxKey(top.world, top.parent)) && !seen.has(boxKey(top.world, top.parent))) {
        top = boxById.get(boxKey(top.world, top.parent));
        seen.add(top.key);
      }
      b.top = top;
    }
    const floors = floorsOf(boxes);
    for (const b of boxes) {
      const f = (floors.get(floorKey(b.top.world, b.top.house)) || [])
        .find(fl => b.top.z !== null && b.top.z >= fl.min && b.top.z <= fl.max);
      b.floor = f ? f.n : 0;
    }

    const baseNames = learnBaseNames(records);
    const items = [...owner.values()].map(({ rec, it }) => {
      const box = boxById.get(keyOfRecord(rec));
      if (box.jewel) box.jewel.stacked++;
      return Object.assign({}, it, {
        base: it.base || (it.type !== null && baseNames.get(it.type)) || "",
        box: box.id,
        // Which box, when two worlds have one of that number: box is the number the game knows.
        boxKey: box.key,
        house: box.top.house,
        floor: box.floor,
        // An older record of the same jewel box: the page it was on was not turned the last time.
        from: rec === top.get(box.key) ? null : { closed: rec.parsed.box.closed, file: rec.name },
      });
    });
    // What the records laid over each other come to, for the page's "recorded to the end" judgement: how
    // many items they hold (stacked, counted above) and how many of the box's pages those items were seen
    // on (covered). A page number outside 1..pages is not counted: it came from a record of when the box
    // held more pages than it does now.
    const jewelPages = new Map();
    for (const it of items) {
      const b = boxById.get(it.boxKey);
      if (!b || !b.jewel || !it.pages.length) continue;
      if (!jewelPages.has(b.key)) jewelPages.set(b.key, new Set());
      for (const page of it.pages) jewelPages.get(b.key).add(page);
    }
    for (const b of boxes) {
      if (!b.jewel) continue;
      const seen = [...(jewelPages.get(b.key) || [])];
      b.jewel.covered = seen.filter(p => p >= 1 && (b.jewel.pages === null || p <= b.jewel.pages)).length;
    }
    return { boxes, items, floors };
  }

  return { parseRecord, combine, newer, lockerComplete, lockerChosen, chosenOf, baseNameTid, cleanText,
    containerCount, readArea, FORMATS, NOT_HERE, boxKey, floorKey, lockerKey };
})();

if (typeof module !== "undefined") module.exports = CPlusHomeParse;
