// Search conditions laid out like the game's vendor search window (ベンダー検索クエリー; Default VendorSearch.lua): the same
// dropdowns, in the same order, holding the vendor search's own entries. The vendor search names its entries with
// tids of search conditions, which are not the tids on item lines (almost none of the numeric line tids match), so
// each entry lists the item-line tids it stands for, checked against the records (the Japanese wording of each tid
// is in the records). Labels come from the recorded wording. An entry shows up only once some recorded item carries
// it, so a tid not seen yet costs nothing. 特効 and スキル name the monster or the skill inside the line, so they take
// every recorded wording of their kind. Anything not here is reached through the 説明の言葉 box.
const SEARCH_GROUPS = [
  { name: "戦闘", tids: [
    [1060402], // damage increase: 武器ダメージ
    [1060408], // defense chance: 回避
    [1060415], // hit chance: 命中
    [1060486], // swing speed: 速度 ○%
    [1113630], // soul charge: マナ変換
    [1060400], // use best weapon skill
    [1112364], // reactive paralyze: 麻痺カウンター
    [1152206], // assassin honed (not recorded yet)
    [1151183], // searing weapon (not recorded yet)
    [1113591], // blood drinker: 吸血
    [1113710], // battle lust: 好戦
    [1072792], // balanced: 片手使用可
    [1113593], [1113594], [1113595], [1113596], [1113597], // fire / cold / poison / energy / kinetic eater: ヒットポイント変換
    [1113598], // damage eater
  ] },
  { name: "詠唱", tids: [
    [1060483], // spell damage increase: 魔法ダメージ
    [1113696], // casting focus: 詠唱集中
    [1060412], // faster cast recovery: キャストリカバリ
    [1060413], // faster casting: ファストキャスト
    [1060433], // lower mana cost: マナコスト
    [1060434], // lower reagent cost: 秘薬コスト
    [1060438], // mage weapon: 魔道武器
    [1060437], // mage armor: 瞑想可
    [1060482], // spell channeling: 詠唱可
  ] },
  { name: "ダメージタイプ", tids: [[1060403], [1060405], [1060404], [1060406], [1060407]] }, // 物理 炎 冷気 毒 エネルギー
  { name: "特効", wording: /^特効: / },
  { name: "抵抗", tids: [[1060448], [1060447], [1060445], [1060449], [1060446]] }, // 物理 炎 冷気 毒 エネルギー
  { name: "ステータス", tids: [
    [1060485], [1060409], [1060432], // STR DEX INT
    [1060431], [1060484], [1060439], // ヒットポイント スタミナ マナ
    [1060444], [1060443], [1060440], // それぞれの回復
  ] },
  { name: "スキル", wording: /^[A-Za-z][A-Za-z ]* \[[^\]]+\] \+○$/ },
  { name: "追加効果:呪文", tids: [
    [1060417], [1060420], [1060421], // dispel fireball harm
    [1060422], [1060423], // life leech: ライフリーチ, lightning
    [1072793], // velocity: 遠距離ボーナス
    [1060424], [1060425], // lower attack: 命中低下, lower defense: 回避低下
    [1060426], [1060427], [1060430], // magic arrow, mana leech, stamina leech
    [1113700], [1113699], // fatigue: スタミナダウン, mana drain: マナダウン
    [1112857], // splintering weapon: 破片残留
    [1154468], // bane: 破滅
  ] },
  { name: "追加効果:エリア", tids: [[1060428], [1060419], [1060416], [1060429], [1060418]] }, // 物理 炎 冷気 毒 エネルギー
  { name: "必要スキル", tids: [[1061172], [1061173], [1061174], [1061175], [1112075]] }, // 剣術 棍術 槍術 弓術 投擲
];

// The その他 dropdown, in sections: first the vendor search's miscellaneous entries that exist on owned items
// (its "not ..." entries and the Felucca / faction / promotional token entries are left out), then what the
// vendor search does not have but owned items do.
const MISC_GROUP = { name: "その他", sections: [
  { label: "ベンダー検索の項目", tids: [
    [1111709], // gargoyles only: ガーゴイル専用
    [1075086], // elves only: エルフ専用
    [1060441], // night sight
    [1049643], // cursed
    [1151782], // cannot be repaired (not recorded yet)
    [1116209], // brittle: 補強不可
    [1152714], // antique: 短命
    [1060411], // enhance potions: ポーション強化
    [1060435], // lower requirements: 装備条件
    [1060436], // luck: 幸運
    [1060442], // reflect physical damage: 物理ダメージ反射
    [1060450], // self repair: 自己修復
    [1061078], // artifact rarity: レアリティ
  ] },
  { label: "持ち物の状態", tids: [[1038021], [1061682], [1060636], [1060639]] }, // Blessed 保険 高品質 耐久性
  { label: "キラー", wording: / キラー: [+-]?○/ }, // talisman: <creature> キラー: +○%
  { label: "プロテクト", wording: / プロテクト: [+-]?○/ }, // talisman: <creature> プロテクト: +○%
] };

if (typeof module !== "undefined") module.exports = { SEARCH_GROUPS, MISC_GROUP };
