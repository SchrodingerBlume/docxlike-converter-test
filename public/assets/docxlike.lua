-- docxlike — Word-compatible page, paragraph and line layout
-- Author: 吴俊豪 <andrew.junhao.wu@gmail.com>
-- License: LaTeX Project Public License 1.3c or later

























local factories, loaded = {}, {}
factories.metrics = function()

local M = {}

local function u16(s, p) local a, b = s:byte(p + 1, p + 2); return a * 256 + b end
local function i16(s, p) local v = u16(s, p); if v >= 32768 then v = v - 65536 end; return v end
local function u32(s, p) local a, b, c, d = s:byte(p + 1, p + 4); return ((a * 256 + b) * 256 + c) * 256 + d end
local function utf16be(s)
  local out, i = {}, 1
  while i + 1 <= #s do
    local c = s:byte(i) * 256 + s:byte(i + 1)
    i = i + 2
    if c >= 0xD800 and c <= 0xDBFF and i + 1 <= #s then
      local d = s:byte(i) * 256 + s:byte(i + 1)
      i = i + 2
      c = 0x10000 + (c - 0xD800) * 0x400 + (d - 0xDC00)
    end
    out[#out + 1] = utf8.char(c)
  end
  return table.concat(out)
end

local function read_names(data, off)
  local count, strs = u16(data, off + 2), u16(data, off + 4)
  local names, seen, fams, primary = {}, {}, {}, {}
  for i = 0, count - 1 do
    local r = off + 6 + i * 12
    local plat, enc, id, len, o = u16(data, r), u16(data, r + 2), u16(data, r + 6), u16(data, r + 8), u16(data, r + 10)
    if id == 1 or id == 4 or id == 6 or id == 16 then
      local raw = data:sub(off + strs + o + 1, off + strs + o + len)
      local s
      if plat == 3 or plat == 0 then s = utf16be(raw)
      elseif plat == 1 and enc == 0 then s = raw:gsub('[\128-\255]', '') end
      if s and s ~= '' then
        if not seen[s] then seen[s] = true; names[#names + 1] = s end
        if id == 1 or id == 16 then fams[s] = true end
        if id ~= 16 then primary[s] = true end
      end
    end
  end
  return names, fams, primary
end
local function read_face(data, base)
  local n = u16(data, base + 4)
  local tab = {}
  for i = 0, n - 1 do
    local r = base + 12 + i * 16
    tab[data:sub(r + 1, r + 4)] = u32(data, r + 8)
  end
  local head, hhea, os2, name = tab['head'], tab['hhea'], tab['OS/2'], tab['name']
  if not (head and hhea and os2) then return nil end
  local ver = u16(data, os2)
  local fs = u16(data, os2 + 62)
  local cp1 = ver >= 1 and u32(data, os2 + 78) or 0
  local f = {
    units = u16(data, head + 18),
    win = { u16(data, os2 + 74), u16(data, os2 + 76) },
    hhea = { i16(data, hhea + 4), -i16(data, hhea + 6), i16(data, hhea + 8) },
    typo = { i16(data, os2 + 68), -i16(data, os2 + 70), i16(data, os2 + 72) },
    use_typo = tab['glyf'] ~= nil and ver >= 4 and (fs // 128) % 2 == 1,
    class = ((cp1 // 131072) % 32 ~= 0) and 'east-asian' or 'latin',
    italic = fs % 2 == 1,
    bold = (fs // 32) % 2 == 1,
    weight = u16(data, os2 + 4),
    avg = i16(data, os2 + 2),
    math = tab['MATH'] ~= nil,
    script = { sub_size = i16(data, os2 + 12), sub_y = i16(data, os2 + 16),
               sup_size = i16(data, os2 + 20), sup_y = i16(data, os2 + 24) },
    strikeout = { size = i16(data, os2 + 26), y = i16(data, os2 + 28) },
  }
  
  local vdmx = tab['VDMX']
  if vdmx then
    local nratios = u16(data, vdmx + 4)
    for i = 0, nratios - 1 do
      local r = vdmx + 6 + i * 4
      local cs, xr, y0, y1 = data:byte(r + 1, r + 4)
      if cs == 1 and (xr == 0 or (xr == 1 and y0 <= 1 and 1 <= y1)) then
        local g = vdmx + u16(data, vdmx + 6 + nratios * 4 + i * 2)
        local rows = {}
        for j = 0, u16(data, g) - 1 do
          local e = g + 4 + j * 6
          rows[u16(data, e)] = { i16(data, e + 2), -i16(data, e + 4) }
        end
        f.vdmx = rows
        break
      end
    end
  end
  local post = tab['post']
  if post then f.underline = { i16(data, post + 8), i16(data, post + 10) } end
  if name then f.names, f.families, f.primary = read_names(data, name)
  else f.names, f.families, f.primary = {}, {}, {} end
  return f
end

function M.read_file(path)
  local fh = io.open(path, 'rb')
  if not fh then return {} end
  local data = fh:read('a')
  fh:close()
  local faces = {}
  if data:sub(1, 4) == 'ttcf' then
    for i = 0, u32(data, 8) - 1 do
      local ok, f = pcall(read_face, data, u32(data, 12 + i * 4))
      if ok and f then faces[#faces + 1] = f end
    end
  else
    local ok, f = pcall(read_face, data, 0)
    if ok and f then faces[1] = f end
  end
  return faces
end


function M.factors(face)
  local a, d, gap
  if face.use_typo then
    a, d, gap = table.unpack(face.typo)
  else
    a, d = table.unpack(face.win)
    gap = math.max(0, face.hhea[3] - (a + d - face.hhea[1] - face.hhea[2]))
  end
  local total, ascent
  if face.class == 'east-asian' then
    total = math.floor((a + d) * 1.3)
    ascent = a + (total - a - d) / 2
  else
    total, ascent = a + d + gap, a + gap
  end
  return { natural = total / face.units, ascent = ascent / face.units,
           math = face.math }
end

local font_factors, math_factors, font_faces, font_paths, file_faces = {}, {}, {}, {}, {}
local function face_for_font(id)
  if font_faces[id] ~= nil then return font_faces[id] or nil, font_paths[id] end
  local live = font and font.getfont and font.getfont(id)
  local properties = live and live.properties or {}
  local raw = live and live.shared and live.shared.rawdata
  local metadata = raw and raw.metadata or {}
  local path = live and (live.filename or properties.filename)
  if not path then font_faces[id] = false; return nil end
  local faces = file_faces[path]
  if not faces then faces = M.read_file(path); file_faces[path] = faces end
  local names = {}
  for _, name in ipairs({live.psname or '', live.fullname or '', properties.fontname or '',
                         metadata.fontname or '', metadata.fullname or '', live.name or ''}) do
    if name ~= '' then names[M.key(name)] = true end
  end
  local pick
  for _, face in ipairs(faces) do
    for _, name in ipairs(face.names) do
      if names[M.key(name)] then pick = face; break end
    end
    if pick then break end
  end
  if not pick and #faces == 1 then pick = faces[1] end
  font_faces[id] = pick or false
  font_paths[id] = path
  return pick, path
end
function M.for_font(id)
  if font_factors[id] ~= nil then return font_factors[id] or nil end
  local pick, path = face_for_font(id)
  if not pick then font_factors[id] = false; return nil end
  local factors = M.factors(pick)
  factors.filename, factors.names = path, pick.names
  font_factors[id] = factors
  return factors
end
function M.win(id)
  local face = face_for_font(id)
  if not face or not face.win then return nil end
  return face.win[1] / face.units, face.win[2] / face.units
end
function M.for_math_font(id)
  if math_factors[id] ~= nil then return math_factors[id] or nil end
  local face = face_for_font(id)
  if not face or not face.math then math_factors[id] = false; return nil end
  local a, d, gap = table.unpack(face.typo)
  if a <= 0 or d < 0 then math_factors[id] = false; return nil end
  gap = math.max(0, gap)
  local factors = { natural = (a + d + gap) / face.units,
                    ascent = (a + gap) / face.units }
  math_factors[id] = factors
  return factors
end



local function half(x) return math.floor(2 * x + 0.5) / 2 end
local function gdi_px(face, ppem)
  local u, row = face.units, face.vdmx and ppem < 255 and face.vdmx[ppem]
  local a = row and row[1] or math.floor(face.win[1] * ppem / u + 0.5)
  local d = row and row[2] or math.floor(face.win[2] * ppem / u + 0.5)
  local gap = math.max(0, face.hhea[3] - (face.win[1] + face.win[2] - face.hhea[1] - face.hhea[2]))
  return a, d, math.floor(gap * ppem / u + 0.5)
end
local function east_px(face, ppem)
  local a = math.floor(face.win[1] * ppem / face.units + 0.5)
  local d = math.floor(face.win[2] * ppem / face.units + 0.5)
  local extra = math.floor((math.floor((a + d) * 1.3) - a - d) / 2 + 0.5)
  return a + extra, d + extra
end
function M.avg_width(id)
  local face = id and face_for_font(id)
  if not face or not face.avg or face.avg <= 0 then return nil end
  return face.avg / face.units
end


function M.strikeout(id, base)
  local face = id and face_for_font(id)
  if not face or not face.strikeout or face.strikeout.size <= 0 then return nil end
  return face.strikeout.size / face.units * base, face.strikeout.y / face.units * base
end
function M.script(id, kind, base)
  local face = face_for_font(id)
  if not face or not face.script or not base or base <= 0 then return "" end
  local u, s = face.units, face.script
  local sup = kind == "superscript"
  local east = face.class == 'east-asian'
  local y_sup = s.sup_y / u
  local fallback = s.sup_size / u < 0.2 or y_sup <= 0 or y_sup >= face.win[1] / u
    or 4 * math.floor(2 * base * y_sup + 0.5) + 4 <= 2 * base
  local size, offset
  if fallback then
    size, offset = half(0.6 * base), half((sup and 0.4 or 0.2) * base)
  else
    size = half((sup and s.sup_size or s.sub_size) / u * base)
    offset = half(math.abs(sup and s.sup_y or s.sub_y) / u * base)
  end
  local p1, p2 = math.floor(base * 600 / 72 + 0.5), math.floor(size * 600 / 72 + 0.5)
  if not east then
    local a1, d1, g1 = gdi_px(face, p1)
    local a2, d2 = gdi_px(face, p2)
    offset = math.min(offset, sup and half(half((a1 + g1) * 72 / 600) - a2 * 72 / 600)
      or half(half(d1 * 72 / 600) - d2 * 72 / 600))
  elseif fallback and not sup then
    local _, d1 = east_px(face, p1)
    local _, d2 = east_px(face, p2)
    offset = math.min(offset, half(half(d1 * 72 / 600) - d2 * 72 / 600))
  end
  return string.format("%.4f,%.4f", size, sup and offset or -offset)
end


function M.live(name)
  local key, pick = M.key(name), nil
  local function choose(path, exact)
    if not path or not lfs.isfile(path) then return end
    local faces = file_faces[path]
    if not faces then faces = M.read_file(path); file_faces[path] = faces end
    for _, face in ipairs(faces) do
      local matches = false
      for _, nm in ipairs(face.names) do if M.key(nm) == key then matches = true; break end end
      if matches then
        local rank = (face.italic and 10000 or 0) + (face.bold and 1000 or 0) + math.abs((face.weight or 400)-400)
        if not pick or rank < pick.rank then pick = {face=face,rank=rank} end
      end
    end
    if not exact and not pick and faces[1] then pick = {face=faces[1],rank=100000} end
  end
  if font and font.each then
    local seen = {}
    for _, loaded in font.each() do
      local path = loaded.filename or (loaded.properties and loaded.properties.filename)
      if path and not seen[path] then seen[path]=true; choose(path,true) end
    end
  end
  if not pick then
    local names = fonts and fonts.names
    if names and names.lookup_font_file then
      local okp, path = pcall(names.lookup_font_file,name)
      if okp then choose(path,false) end
    end
  end
  if not pick then return "" end
  pick = pick.face
  return table.concat({ pick.units, pick.win[1], pick.win[2], pick.hhea[1], pick.hhea[2],
    pick.hhea[3], pick.typo[1], pick.typo[2], pick.typo[3],
    pick.use_typo and "true" or "false", pick.class }, ",")
end



local symbol_unicode = {
  [0x20]=0x0020, [0x21]=0x0021, [0x22]=0x2200, [0x23]=0x0023, [0x24]=0x2203, [0x25]=0x0025, [0x26]=0x0026, [0x27]=0x220B,
  [0x28]=0x0028, [0x29]=0x0029, [0x2A]=0x2217, [0x2B]=0x002B, [0x2C]=0x002C, [0x2D]=0x2212, [0x2E]=0x002E, [0x2F]=0x002F,
  [0x30]=0x0030, [0x31]=0x0031, [0x32]=0x0032, [0x33]=0x0033, [0x34]=0x0034, [0x35]=0x0035, [0x36]=0x0036, [0x37]=0x0037,
  [0x38]=0x0038, [0x39]=0x0039, [0x3A]=0x003A, [0x3B]=0x003B, [0x3C]=0x003C, [0x3D]=0x003D, [0x3E]=0x003E, [0x3F]=0x003F,
  [0x40]=0x2245, [0x41]=0x0391, [0x42]=0x0392, [0x43]=0x03A7, [0x44]=0x2206, [0x45]=0x0395, [0x46]=0x03A6, [0x47]=0x0393,
  [0x48]=0x0397, [0x49]=0x0399, [0x4A]=0x03D1, [0x4B]=0x039A, [0x4C]=0x039B, [0x4D]=0x039C, [0x4E]=0x039D, [0x4F]=0x039F,
  [0x50]=0x03A0, [0x51]=0x0398, [0x52]=0x03A1, [0x53]=0x03A3, [0x54]=0x03A4, [0x55]=0x03A5, [0x56]=0x03C2, [0x57]=0x2126,
  [0x58]=0x039E, [0x59]=0x03A8, [0x5A]=0x0396, [0x5B]=0x005B, [0x5C]=0x2234, [0x5D]=0x005D, [0x5E]=0x22A5, [0x5F]=0x005F,
  [0x61]=0x03B1, [0x62]=0x03B2, [0x63]=0x03C7, [0x64]=0x03B4, [0x65]=0x03B5, [0x66]=0x03C6, [0x67]=0x03B3, [0x68]=0x03B7,
  [0x69]=0x03B9, [0x6A]=0x03D5, [0x6B]=0x03BA, [0x6C]=0x03BB, [0x6D]=0x00B5, [0x6E]=0x03BD, [0x6F]=0x03BF, [0x70]=0x03C0,
  [0x71]=0x03B8, [0x72]=0x03C1, [0x73]=0x03C3, [0x74]=0x03C4, [0x75]=0x03C5, [0x76]=0x03D6, [0x77]=0x03C9, [0x78]=0x03BE,
  [0x79]=0x03C8, [0x7A]=0x03B6, [0x7B]=0x007B, [0x7C]=0x007C, [0x7D]=0x007D, [0x7E]=0x223C, [0xA1]=0x03D2, [0xA2]=0x2032,
  [0xA3]=0x2264, [0xA4]=0x2044, [0xA5]=0x221E, [0xA6]=0x0192, [0xA7]=0x2663, [0xA8]=0x2666, [0xA9]=0x2665, [0xAA]=0x2660,
  [0xAB]=0x2194, [0xAC]=0x2190, [0xAD]=0x2191, [0xAE]=0x2192, [0xAF]=0x2193, [0xB0]=0x00B0, [0xB1]=0x00B1, [0xB2]=0x2033,
  [0xB3]=0x2265, [0xB4]=0x00D7, [0xB5]=0x221D, [0xB6]=0x2202, [0xB7]=0x2022, [0xB8]=0x00F7, [0xB9]=0x2260, [0xBA]=0x2261,
  [0xBB]=0x2248, [0xBC]=0x2026, [0xBF]=0x21B5, [0xC0]=0x2135, [0xC1]=0x2111, [0xC2]=0x211C, [0xC3]=0x2118, [0xC4]=0x2297,
  [0xC5]=0x2295, [0xC6]=0x2205, [0xC7]=0x2229, [0xC8]=0x222A, [0xC9]=0x2283, [0xCA]=0x2287, [0xCB]=0x2284, [0xCC]=0x2282,
  [0xCD]=0x2286, [0xCE]=0x2208, [0xCF]=0x2209, [0xD0]=0x2220, [0xD1]=0x2207, [0xD5]=0x220F, [0xD6]=0x221A, [0xD7]=0x22C5,
  [0xD8]=0x00AC, [0xD9]=0x2227, [0xDA]=0x2228, [0xDB]=0x21D4, [0xDC]=0x21D0, [0xDD]=0x21D1, [0xDE]=0x21D2, [0xDF]=0x21D3,
  [0xE0]=0x25CA, [0xE1]=0x2329, [0xE5]=0x2211, [0xF1]=0x232A, [0xF2]=0x222B, [0xF3]=0x2320, [0xF5]=0x2321,
}
function M.symbol_tounicode(tfmdata)
  if type(tfmdata) ~= "table" or not tfmdata.characters then return end
  local name = ((tfmdata.psname or tfmdata.fontname or tfmdata.fullname or tfmdata.name or "") .. ""):lower()
  if not name:find("symbol", 1, true) then return end
  for code, u in pairs(symbol_unicode) do
    local ch = tfmdata.characters[0xF000 + code]
    if ch then ch.tounicode = string.format("%04X", u) end
  end
end
function M.key(s)
  return (s:gsub('[%s_%-]', ''):lower())
end
function M.entry(k, f, comment)
  return string.format(
    '\\docxlike_font_metrics_gset:nnnnnn { %s } { %d } { %d %d } { %d %d %d } { %d %d %d } { %s %s }%s',
    k, f.units, f.win[1], f.win[2], f.hhea[1], f.hhea[2], f.hhea[3],
    f.typo[1], f.typo[2], f.typo[3], f.use_typo and 'true' or 'false', f.class,
    comment and (' % ' .. comment) or '')
end
M.families = [[
SimSun; NSimSun; SimHei; KaiTi; FangSong; LiSu; YouYuan; KaiTi_GB2312; FangSong_GB2312;
Microsoft YaHei; Microsoft YaHei Light; Microsoft YaHei UI; DengXian; DengXian Light;
Microsoft JhengHei; PMingLiU; MingLiU; DFKai-SB;
STSong; STKaiti; STFangsong; STZhongsong; STXihei; STXinwei; STLiti; STXingkai; STHupo; STCaiyun;
FZShuTi; FZYaoTi;
Noto Sans SC; Noto Serif SC;
Yu Gothic; Yu Mincho; MS Gothic; MS PGothic; MS Mincho; MS PMincho; Meiryo; Malgun Gothic; Batang; Gulim; Dotum;
Times New Roman; Arial; Arial Narrow; Calibri; Calibri Light; Cambria; Aptos; Aptos Display; Aptos Narrow;
Georgia; Verdana; Tahoma; Segoe UI; Consolas; Courier New; Garamond; Palatino Linotype; Book Antiqua;
Bookman Old Style; Century; Century Gothic; Century Schoolbook; Corbel; Candara; Constantia;
FandolSong; FandolHei; FandolKai; FandolFang R;
Noto Serif CJK SC; Noto Sans CJK SC; Source Han Serif SC; Source Han Sans SC;
Adobe Song Std; Adobe Heiti Std; Adobe Kaiti Std; Adobe Fangsong Std; Adobe Ming Std;
FZShuSong-Z01; FZHei-B01; FZKai-Z03; FZFangSong-Z02; FZXiaoBiaoSong-B05; FZLiShu-S01;
HYShuSongErKW; HYZhongHeiKW; HYKaiTiKW; HYFangSongS;
Songti SC; STHeiti; Heiti SC; Kaiti SC; PingFang SC; Yuanti SC; Baoli SC; Hiragino Sans GB; Libian SC; Xingkai SC;
Latin Modern Roman; Latin Modern Sans; Latin Modern Mono; LM Roman 10; LM Sans 10; LM Mono 10;
TeX Gyre Termes; TeX Gyre Heros; TeX Gyre Pagella; TeX Gyre Bonum; TeX Gyre Schola; TeX Gyre Cursor; TeX Gyre Adventor
]]

local function wanted()
  local w = {}
  for f in M.families:gmatch('[^;]+') do
    local k = M.key(f)
    if k ~= '' then w[k] = true end
  end
  return w
end

local function walk(path, out)
  local attr = lfs.attributes(path)
  if not attr then return end
  if attr.mode == 'directory' then
    local items = {}
    for e in lfs.dir(path) do
      if e ~= '.' and e ~= '..' then items[#items + 1] = e end
    end
    table.sort(items)
    for _, e in ipairs(items) do walk(path .. '/' .. e, out) end
  else
    local l = path:lower()
    if l:match('%.ttf$') or l:match('%.otf$') or l:match('%.ttc$') then out[#out + 1] = path end
  end
end

function M.table(out, sources)
  local want, entries = wanted(), {}
  for si, src in ipairs(sources) do
    local files = {}
    walk(src, files)
    for _, p in ipairs(files) do
      for fi, f in ipairs(M.read_file(p)) do
        local set, fams = {}, {}
        for nm in pairs(f.families) do
          local k = M.key(nm)
          if want[k] and not set[k] then set[k] = true; fams[#fams + 1] = k end
        end
        if #fams > 0 then
          table.sort(fams)
          entries[#entries + 1] = { src = si, italic = f.italic and 1 or 0, bold = f.bold and 1 or 0,
            dw = math.abs(f.weight - 400), path = p, idx = fi, f = f, fam = table.concat(fams, ',') }
        end
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.src ~= b.src then return a.src < b.src end
    if a.italic ~= b.italic then return a.italic < b.italic end
    if a.bold ~= b.bold then return a.bold < b.bold end
    if a.dw ~= b.dw then return a.dw < b.dw end
    if a.path ~= b.path then return a.path < b.path end
    return a.idx < b.idx
  end)
  
  
  local chosen, taken = {}, {}
  for _, e in ipairs(entries) do
    if not taken[e.fam] then taken[e.fam] = true; chosen[#chosen + 1] = e end
  end
  local tbl, keys = {}, {}
  for pass = 1, 2 do
    for _, e in ipairs(chosen) do
      for _, nm in ipairs(e.f.names) do
        local k = M.key(nm)
        if k ~= '' and not tbl[k] and (pass == 2 or e.f.primary[nm]) then
          tbl[k] = { f = e.f, name = nm, file = e.path:match('[^/]+$') }
          keys[#keys + 1] = k
        end
      end
    end
  end
  
  if tbl['lmroman10regular'] then
    for _, a in ipairs({ 'computermodern', 'cmr10', 'cmunrm' }) do
      if not tbl[a] then
        tbl[a] = { f = tbl['lmroman10regular'].f, name = 'Computer Modern (= LM Roman 10)',
                   file = tbl['lmroman10regular'].file }
        keys[#keys + 1] = a
      end
    end
  end
  table.sort(keys)
  local fh = assert(io.open(out, 'w'))
  fh:write('%% 常用字体行高相关的原始度量，构建时内嵌到 docxlike.sty。\n')
  fh:write('%% 由 tools/font-metrics.lua 从字体文件读出；make font-metrics 重新生成。\n')
  fh:write(string.format('%%%% 共 %d 个名字。名字规范化：小写，去掉空格、连字符与下划线。\n', #keys))
  fh:write('%% 参数：名字、unitsPerEm、OS/2 usWinAscent usWinDescent、hhea ascender |descender| lineGap、\n')
  fh:write('%%       OS/2 sTypoAscender |sTypoDescender| sTypoLineGap、是否照 typo（TrueType 且 v4+ 且\n')
  fh:write('%%       USE_TYPO_METRICS）、类别（latin 或 east-asian）。行尾注释是原名与文件。\n')
  for _, k in ipairs(keys) do
    fh:write(M.entry(k, tbl[k].f, tbl[k].name .. ' | ' .. tbl[k].file), '\n')
  end
  local groups, order = {}, {}
  for _, k in ipairs(keys) do
    local f = tbl[k].f
    if not groups[f] then groups[f] = {}; order[#order + 1] = f end
    table.insert(groups[f], k)
  end
  fh:write('%% 同一副字体的名字，一行一组。\n')
  local lines = {}
  for _, f in ipairs(order) do
    if #groups[f] > 1 then
      lines[#lines + 1] = '\\docxlike_font_names_gset:n { ' .. table.concat(groups[f], ' , ') .. ' }'
    end
  end
  table.sort(lines)
  for _, l in ipairs(lines) do fh:write(l, '\n') end
  fh:close()
  print(string.format('%d names -> %s', #keys, out))
end
return M
end
factories.run = function()
local M = { used = false, colors = {} }
local LTJ = docxlike.runtime.load("ltj")
local cjk_fallback_profiles, cjk_fallback_keys = {}, {}
local function cjk_fallback_filter(head)
  if not LTJ.available then return head end
  local cluster, state, profile_id, primary_id = {}, nil, nil, nil
  local function covers(id)
    local data = font.getfont(id or -1)
    if not data then return false end
    local base
    for _,g in ipairs(cluster) do
      local c=g.char
      if (c>=0xFE00 and c<=0xFE0F) or (c>=0xE0100 and c<=0xE01EF) then
        local resources=data.resources or (data.shared and data.shared.rawdata and data.shared.rawdata.resources) or {}
        if not (resources.variants and resources.variants[c] and resources.variants[c][base]) then return false end
      elseif c~=0x200C and c~=0x200D then
        if not data.characters[c] then return false end
        base=c
      end
    end
    return true
  end
  local function flush()
    local profile=cjk_fallback_profiles[profile_id]
    if profile and cluster[1] and LTJ.is_cjk_char(cluster[1]) and not covers(primary_id) then
      for _,id in ipairs(profile) do
        if covers(id) then
          for _,g in ipairs(cluster) do LTJ.set_jfont(g,id) end
          break
        end
      end
    end
    cluster,state,profile_id,primary_id={},nil,nil,nil
  end
  for glyph in node.traverse(head) do
    if glyph.id==node.id('glyph') and LTJ.unprocessed(glyph) then
      local profile=node.get_attribute(glyph,M.cjk_fallback_attr)
      local primary=LTJ.jfont_of(glyph)
      if profile~=profile_id or primary~=primary_id then flush() end
      local fresh,next_state=M.cjk_graphemes.read_codepoint(glyph.char,state)
      if fresh and #cluster>0 then
        flush(); local ignored,new_state=M.cjk_graphemes.read_codepoint(glyph.char,nil); next_state=new_state
      end
      state,profile_id,primary_id=next_state,profile,primary
      cluster[#cluster+1]=glyph
    else flush() end
  end
  flush()
  return head
end
function M.cjk_fallback_register(ids)
  if #ids == 0 then return 0 end
  local key = table.concat(ids,',')
  local found = cjk_fallback_keys[key]
  if found then return found end
  if not M.cjk_fallback_attr then
    M.cjk_graphemes = require('lua-uni-graphemes')
    M.cjk_fallback_attr = luatexbase.attributes['docxlike@cjkfallback@attr']
    for _, callback in ipairs({'pre_linebreak_filter','hpack_filter'}) do
      local order = luatexbase.callback_descriptions(callback)
      local available = false
      for _, description in ipairs(order) do
        if description == LTJ.FONT_SETUP_CALLBACK then available = true end
      end
      assert(available,'CJK fallback requires the luatexja font setup callback')
      luatexbase.add_to_callback(callback,cjk_fallback_filter,'docxlike.cjk-fallback')
      
      local following = false
      for _, description in ipairs(order) do
        if description == LTJ.FONT_SETUP_CALLBACK then following = true end
        if following then
          luatexbase.declare_callback_rule(callback,'docxlike.cjk-fallback','before',description)
        end
      end
    end
  end
  local id = #cjk_fallback_profiles+1
  cjk_fallback_profiles[id], cjk_fallback_keys[key] = ids, id
  return id
end

local HLIST, VLIST = node.id("hlist"), node.id("vlist")
local GLYPH, GLUE, KERN, WHATSIT = node.id("glyph"), node.id("glue"), node.id("kern"), node.id("whatsit")
local PENALTY, WHATSIT, RULE = node.id("penalty"), node.id("whatsit"), node.id("rule")
local has_attr = node.has_attribute
local traverse = node.traverse
local ul_attr, ulc_attr, ulfont_attr, va_attr, vaja_attr, pos_attr

local SINGLE, WORDS = 1, 2
local HALF_BP = tex.sp("0.5bp")

local closing, opening = {}, {}
for _, c in utf8.codes("，。、；：？！）」』】〕〉》”’") do closing[c] = true end
for _, c in utf8.codes("（「『【〔〈《“‘") do opening[c] = true end

local sizes = {}
local function fsize(f)
  local s = sizes[f]
  if not s then
    local t = font.getfont(f)
    s = t and t.size or 0
    sizes[f] = s
  end
  return s
end


local files, posts = {}, {}
local function post_underline(f)
  local u = posts[f]
  if u ~= nil then return u end
  u = false
  local t = fonts and fonts.hashes and fonts.hashes.identifiers and fonts.hashes.identifiers[f]
  local path = t and t.filename
  local reader = docxlike and docxlike.metrics and docxlike.metrics.read_file
  if path and reader then
    local faces = files[path]
    if not faces then faces = reader(path); files[path] = faces end
    local sub = t.specification and tonumber(t.specification.sub) or 1
    local face = faces[sub] or faces[1]
    if face and face.underline and face.units then
      u = { top = -face.underline[1] / face.units, thick = face.underline[2] / face.units }
    end
  end
  posts[f] = u
  return u
end


local function font_metrics(f)
  local size = fsize(f)
  local u = post_underline(f)
  if LTJ.is_jfont(f) then
    return math.floor(size / 8 + HALF_BP + 0.5), math.floor((u and u.thick or 0.05) * size + 0.5)
  end
  if u then
    return math.floor((u.top + u.thick / 2) * size + 0.5), math.floor(u.thick * size + 0.5)
  end
  return math.floor(0.135 * size + 0.5), math.floor(0.05 * size + 0.5)
end

local function edge_glyph(n, last)
  if n.id == GLYPH then return n end
  if n.id == HLIST or n.id == VLIST then
    local m = n.head
    if m and last then m = node.tail(m) end
    while m do
      local g = edge_glyph(m, last)
      if g then return g end
      if last then m = m.prev else m = m.next end
    end
  end
end

local function is_space(n)
  return n.id == GLUE and (n.subtype == 13 or n.subtype == 14)
end

local function is_jfm_glue(n)
  return n.id == GLUE and LTJ.is_jfmglue(n)
end


local BOX = 2


local function solid(n, v)
  local id = n.id
  if id == GLYPH or id == HLIST then return true end
  if id == RULE then return n.width > 0 end
  if id == GLUE then
    local st = n.subtype
    if st == 13 or st == 14 then return v == SINGLE end
    if st == 0 then
      return not LTJ.is_inserted_glue(n)
    end
  end
  return false
end

local function bridge(n)
  local id = n.id
  return id == KERN or id == PENALTY or id == WHATSIT or (id == RULE and n.width == 0)
end


local function run_metrics(n)
  local f = has_attr(n, ulfont_attr)
  if f then return font_metrics(f) end
end



local function metrics(n)
  local id = n.id
  if id == GLYPH then return font_metrics(n.font) end
  if id == HLIST and n.subtype ~= BOX then
    local g = edge_glyph(n, false)
    if g then return font_metrics(g.font) end
  end
  if id == HLIST or (id == RULE and n.width > 0) or is_space(n) then return run_metrics(n) end
end

local function colorstack(cmd, data)
  local w = node.new(WHATSIT, "pdf_colorstack")
  w.stack = 0
  w.command = cmd
  if data then w.data = data end
  return w
end

local function draw(box, first, last, c, th, v)
  local head = box.head
  local lastsolid = last
  local t = last.next
  while t and t.id == KERN and (has_attr(t, ul_attr) or v) == v do
    last = t
    t = t.next
  end
  if t and is_jfm_glue(t) then
    local g = edge_glyph(lastsolid, true)
    if g and closing[g.char] then last = t end
  end
  local p = first.prev
  if p and is_jfm_glue(p) then
    local g = edge_glyph(first, false)
    if g and opening[g.char] then first = p end
  end
  local w = node.dimensions(box.glue_set, box.glue_sign, box.glue_order, first, last.next)
  if w <= 0 or not c then return last end
  local r = node.new(RULE)
  r.width, r.height, r.depth = w, -(c - th // 2), c + th - th // 2
  local k = node.new(KERN)
  k.kern = -w
  local col = ulc_attr and (has_attr(first, ulc_attr) or has_attr(lastsolid, ulc_attr))
  local data = col and M.colors[col]
  if data then head = node.insert_before(head, first, colorstack(1, data)) end
  head = node.insert_before(head, first, r)
  if data then head = node.insert_before(head, first, colorstack(2)) end
  head = node.insert_before(head, first, k)
  box.head = head
  return last
end


local function underline(box)
  local n = box.head
  while n do
    local v = has_attr(n, ul_attr)
    if v and solid(n, v) then
      local first, last = n, n
      local c, th = metrics(n)
      local m = n.next
      while m do
        local mv = has_attr(m, ul_attr)
        if mv == v then
          if v == WORDS and is_space(m) then break end
          local mc, mth = metrics(m)
          if mc and c and (mc ~= c or mth ~= th) then break end
          if not c then c, th = mc, mth end
          if solid(m, v) then last = m end
        elseif mv ~= nil or not bridge(m) then
          break
        end
        m = m.next
      end
      if not c then c, th = run_metrics(first) end
      n = draw(box, first, last, c, th, v).next
    else
      n = n.next
    end
  end
end



local fill_attr, exact_attr
local wordbox = {}
local function word_ascdesc(f)
  local v = wordbox[f]
  if v ~= nil then return v end
  v = false
  local t = fonts and fonts.hashes and fonts.hashes.identifiers and fonts.hashes.identifiers[f]
  local path = t and t.filename
  local reader = docxlike and docxlike.metrics and docxlike.metrics.read_file
  if path and reader then
    local faces = files[path]
    if not faces then faces = reader(path); files[path] = faces end
    local sub = t.specification and tonumber(t.specification.sub) or 1
    local face = faces[sub] or faces[1]
    if face and face.units then
      local a, d, g
      if face.use_typo then
        a, d, g = face.typo[1], face.typo[2], face.typo[3]
      else
        a, d = face.win[1], face.win[2]
        g = math.max(0, face.hhea[3] - ((a + d) - (face.hhea[1] + face.hhea[2])))
      end
      local u = face.units
      if face.class == 'east-asian' then
        local nat = math.floor((a + d) * 1.3)
        local up = a + (nat - a - d) / 2
        v = { up / u, (nat - up) / u }
      else
        v = { (a + g) / u, d / u }
      end
    end
  end
  wordbox[f] = v
  return v
end
local function fill_line(box)
  local exact = exact_attr and has_attr(box, exact_attr)
  local n = box.head
  while n do
    local v = has_attr(n, fill_attr)
    if v and (n.id == GLYPH or n.id == HLIST or n.id == GLUE) then
      local first, last = n, n
      local up, dn = 0, 0
      local function grow(m)
        local g = m.id == GLYPH and m or (m.id == HLIST and m.subtype ~= BOX and edge_glyph(m, false))
        if g then
          local s, w = fsize(g.font), word_ascdesc(g.font)
          if w then up = math.max(up, w[1] * s); dn = math.max(dn, w[2] * s) end
        end
      end
      grow(n)
      local m = n.next
      while m do
        local mv = has_attr(m, fill_attr)
        if mv == v then
          grow(m)
          if m.id ~= PENALTY then last = m end
        elseif mv ~= nil or not bridge(m) then
          break
        end
        m = m.next
      end
      local t = last.next
      while t and t.id == KERN and not has_attr(t, fill_attr) do last = t; t = t.next end
      local w = node.dimensions(box.glue_set, box.glue_sign, box.glue_order, first, last.next)
      if exact then up, dn = box.height, box.depth end
      local data = M.colors[v]
      if w > 0 and up + dn > 0 and data then
        local r = node.new(RULE)
        r.width, r.height, r.depth = w, math.floor(up + 0.5), math.floor(dn + 0.5)
        local k = node.new(KERN)
        k.kern = -w
        local head = box.head
        head = node.insert_before(head, first, colorstack(1, data))
        head = node.insert_before(head, first, r)
        head = node.insert_before(head, first, colorstack(2))
        head = node.insert_before(head, first, k)
        box.head = head
      end
      n = last.next
    else
      n = n.next
    end
  end
end

local function walk(box)
  for m in traverse(box.head) do
    local id = m.id
    if id == VLIST or (id == HLIST and not (box.id == HLIST
        and (has_attr(m, ul_attr) or (fill_attr and has_attr(m, fill_attr))))) then
      walk(m)
    end
  end
  if box.id == HLIST then
    if fill_attr then fill_line(box) end
    underline(box)
  end
end


M.baseline_records = {}
local baseline_cache = {}
function M.baseline_register(fid, role, reference)
  local f = font.getfont(fid)
  local raw = f and f.shared and f.shared.rawdata
  local desc = raw and raw.descriptions
  local anchor = 0x56FD
  local d = desc and desc[anchor]
  if not d then anchor = 0x570B; d = desc and desc[anchor] end
  local b = d and d.boundingbox
  local units = raw and raw.metadata and raw.metadata.units
  if not b or not units or units <= 0 then
    texio.write_nl('term and log', 'docxlike baseline: skipped '..role
      ..' ('..tostring(f and f.fullname)..'): anchor bounds unavailable')
    return 0
  end
  local center = (b[2] + b[4]) / (2 * units)
  local delta = reference - center
  if math.abs(delta) < 0.001 then delta = 0 end
  local key = tostring(raw)..':'..role..':'..tostring(reference)
  if baseline_cache[key] then return baseline_cache[key] end
  local i = #M.baseline_records + 1
  M.baseline_records[i] = {role=role, center=center, reference=reference,
    delta=delta, anchor=anchor, filename=f.filename, font=f.fullname}
  baseline_cache[key] = i
  texio.write_nl('log', string.format('docxlike baseline: %s font=%s anchor=U+%04X center=%.9f target=%.9f shift=%.9fem',
    role, tostring(f.fullname), anchor, center, reference, delta))
  return i
end
local function baseline_feature(tfmdata, value)
  local properties = {}
  for k, v in pairs(tfmdata.properties or {}) do properties[k] = v end
  properties.docxlike_baseline = tonumber(tostring(value):match('^ref(%d+)$'))
  tfmdata.properties = properties
end
fonts.handlers.otf.features.register {
  name='docxbaseline', description='docxlike CJK ink baseline',
  initializers={base=baseline_feature, node=baseline_feature, plug=baseline_feature},
}
function M.baseline_shift(box)
  local enabled = luatexbase.attributes['docxlike@baseline@attr']
  local done = luatexbase.attributes['docxlike@baseline@done@attr']
  for n in traverse(box.head) do
    if n.id == GLYPH and enabled and has_attr(n, enabled) == 1 then
      local f = font.getfont(n.font)
      local record = f and f.properties and M.baseline_records[f.properties.docxlike_baseline]
      if record then
        local delta = math.floor(record.delta * f.size + 0.5)
        n.yoffset = n.yoffset + delta - (has_attr(n, done) or 0)
        node.set_attribute(n, done, delta)
      end
    elseif n.id == HLIST or n.id == VLIST then
      M.baseline_shift(n)
    end
  end
end

local function shift(box)
  for n in traverse(box.head) do
    local id = n.id
    if id == GLYPH then
      local a, j = has_attr(n, va_attr), has_attr(n, vaja_attr)
      if a or j then
        local d
        if LTJ.is_jfont(n.font) then d = j else d = a end
        if d and d ~= 0 then n.yoffset = n.yoffset + d end
      end
      local p = pos_attr and has_attr(n, pos_attr)
      if p and p ~= 0 then n.yoffset = n.yoffset + p end
    elseif id == HLIST or id == VLIST then
      shift(n)
    end
  end
end

function M.color(i, hex)
  local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
  local c = string.format("%.4f %.4f %.4f", r / 255, g / 255, b / 255)
  
  M.colors[i] = c .. " rg " .. c .. " RG"
end





local SMALL_CAPS = 0.8
local function small_caps_scale(f, k)
  local half = 65781.76 / 2
  local nominal = math.floor((f.size * SMALL_CAPS + 1) / half + 0.5) * half
  if k == 100 then return nominal / f.size end
  local pixel = .12 * 65781.76
  return math.floor((nominal + 1) / pixel + 0.5) * pixel / f.size
end
local scale_attr, smallcaps_attr, spacing_attr, spacefont_attr
local derived = {}
M.wscale, M.wadd, M.metric_size = {}, {}, {}


local function derived_font(fid, k, small, cs)
  cs = cs or 0
  local key = fid .. ":" .. k .. ":" .. (small and 1 or 0) .. ":" .. cs
  local c = derived[key]
  if c then return c end
  local f = font.getfont(fid)
  if not f or not f.characters then return fid end
  local z = small and small_caps_scale(f, k) or 1
  local x = k / 100 * z
  local t = {}
  for a, b in pairs(f) do t[a] = b end
  t.size = math.floor(f.size * z + 0.5)
  t.extend = math.floor((f.extend or 1000) * k / 100 + 0.5)
  t.parameters = {}
  for a, b in pairs(f.parameters or {}) do
    t.parameters[a] = type(b) == "number" and a ~= "slant" and math.floor(b * z + 0.5) or b
  end
  for _, a in ipairs({ "space", "space_stretch", "space_shrink" }) do
    if t.parameters[a] then t.parameters[a] = math.floor(t.parameters[a] * k / 100 + 0.5) end
  end
  if t.parameters.space then t.parameters.space = t.parameters.space + cs end
  t.characters = {}
  for code, ch in pairs(f.characters) do
    local cc = {}
    for a, b in pairs(ch) do cc[a] = b end
    if cc.width then cc.width = math.floor(cc.width * x + 0.5) + cs end
    if cc.height then cc.height = math.floor(cc.height * z + 0.5) end
    if cc.depth then cc.depth = math.floor(cc.depth * z + 0.5) end
    t.characters[code] = cc
  end
  c = font.define(t)
  
  local ids = fonts and fonts.hashes and fonts.hashes.identifiers
  if ids then ids[c] = t end
  LTJ.alias_jfont(c, fid)
  derived[key] = c
  
  
  M.wscale[c] = k / 100
  M.wadd[c] = cs
  M.metric_size[c] = M.metric_size[fid] or f.size
  return c
end
M.derived_font = derived_font
function M.stretched_font(fid, k) return derived_font(fid, k, false, 0) end
local function scale_box(box, k, cs)
  box.width = math.floor(box.width * k / 100 + 0.5) + cs
  for m in traverse(box.head) do
    if m.id == GLYPH then m.font = derived_font(m.font, k, false, cs)
    elseif m.id == KERN then m.kern = math.floor(m.kern * k / 100 + 0.5) end
  end
end
local upper = unicode.utf8.upper
local function small_letter(c)
  local u = utf8.codepoint(upper(utf8.char(c)))
  return u ~= c and u or nil
end
function M.scale(head)
  for n in traverse(head) do
    local k = scale_attr and has_attr(n, scale_attr) or 100
    local sc = smallcaps_attr and has_attr(n, smallcaps_attr) == 1
    local cs = spacing_attr and has_attr(n, spacing_attr) or 0
    if k ~= 100 or sc or cs ~= 0 then
      local id = n.id
      if id == GLYPH then
        local u = sc and small_letter(n.char)
        if u then n.char = u end
        n.font = derived_font(n.font, k, u ~= nil and u ~= false, cs)
      elseif id == HLIST and LTJ.is_packed(n) then scale_box(n, k, cs)
      elseif id == KERN then n.kern = math.floor(n.kern * k / 100 + 0.5)
      elseif id == GLUE then
        local sf = spacefont_attr and has_attr(n, spacefont_attr)
        local f = sf and font.getfont(sf)
        local z = k / 100 * (sc and n.subtype == 13 and f and small_caps_scale(f, k) or 1)
        local add = LTJ.is_inserted_glue(n) and 0 or cs
        node.setglue(n, n.width * z + add, n.stretch * z, n.shrink * z, n.stretch_order, n.shrink_order)
      end
    end
  end
  return head
end
function M.scale_install()
  scale_attr = luatexbase.attributes["docxlike@scale@attr"]
  smallcaps_attr = luatexbase.attributes["docxlike@smallcaps@attr"]
  spacing_attr = luatexbase.attributes["docxlike@spacing@attr"]
  spacefont_attr = luatexbase.attributes["docxlike@spacefont@attr"]
  M.scale_attr, M.smallcaps_attr, M.spacing_attr = scale_attr, smallcaps_attr, spacing_attr
  M.scale_on = true
end



local bold_attr
local EMBOLDEN = tonumber(token.get_macro("c_docxlike_font_fake_bold_tl")) / 6578.176
local realbold, clones = {}, {}
function M.real_bold(fid)
  local v = realbold[fid]
  if v == nil then
    local f = font.getfont(fid)
    local md = f and f.shared and f.shared.rawdata and f.shared.rawdata.metadata
    local w = string.lower(md and md.weight or "")
    v = (f ~= nil and f.mode == 2) or w:find("bold") ~= nil or w:find("black") ~= nil
      or w:find("heavy") ~= nil
    realbold[fid] = v
  end
  return v
end
local function embolden(fid)
  local c = clones[fid]
  if not c then
    local f = font.getfont(fid)
    if not f or not f.size then return fid end
    local t = {}
    for k, v in pairs(f) do t[k] = v end
    t.mode, t.width = 2, f.size * EMBOLDEN
    c = font.define(t)
    clones[fid] = c
    realbold[c] = true
  end
  return c
end
local function bolden(head)
  for n in traverse(head) do
    local id = n.id
    if id == GLYPH then
      if has_attr(n, bold_attr) and not M.real_bold(n.font) then n.font = embolden(n.font) end
    elseif id == HLIST or id == VLIST then
      bolden(n.list)
    end
  end
end







local pdf_link_levels={}
local pdf_start_link,pdf_end_link=node.subtype('pdf_start_link'),node.subtype('pdf_end_link')
local function link_content_hd(head)
  local height,depth,content,adjusted=0,0,false,false
  for n in traverse(head) do
    if (node.getproperty(n) or {}).docxlike_line_strut then
      adjusted=true
    else
      local h,d
      if n.id==GLYPH then
        h,d=n.height+n.yoffset,n.depth-n.yoffset
        adjusted=adjusted or n.yoffset~=0
      elseif n.id==HLIST and n.head then
        local material,changed
        h,d,material,changed=link_content_hd(n.head)
        if not changed and (not material or n.height~=0 or n.depth~=0) then h,d=n.height,n.depth end
        
        
        
        local smashed=material and n.height==0 and n.depth==0 and (h~=0 or d~=0)
        h,d=h-n.shift,d+n.shift
        adjusted=adjusted or changed or smashed
      else
        local _,natural_height,natural_depth=node.dimensions(n,n.next)
        h,d=natural_height,natural_depth
      end
      height,depth=math.max(height,h),math.max(depth,d)
      content=content or h~=0 or d~=0
    end
  end
  return height,depth,content,adjusted
end
local function link_rectangles(head,level)
  local direct=pdf_link_levels[#pdf_link_levels]==level
  for n in traverse(head) do
    if n.id==WHATSIT then
      if n.subtype==pdf_start_link then
        pdf_link_levels[#pdf_link_levels+1]=level;direct=true
      elseif n.subtype==pdf_end_link then
        pdf_link_levels[#pdf_link_levels]=nil;direct=true
      end
    elseif (n.id==HLIST or n.id==VLIST) and n.head then
      local properties=node.getproperty(n) or {}
      local contents=link_rectangles(n.head,level+1)
      if n.id==HLIST and contents and not properties.docxlike_link_content then
        
        
        
        local height,depth,_,adjusted=link_content_hd(n.head)
        local smashed=n.height==0 and n.depth==0 and (height~=0 or depth~=0)
        if not adjusted and not smashed and properties.docxlike_line_leading==nil
            and properties.docxlike_para_first==nil then height,depth=n.height,n.depth end
        local inner=node.new(HLIST)
        inner.width,inner.height,inner.depth=n.width,height,depth
        inner.glue_set,inner.glue_sign,inner.glue_order=n.glue_set,n.glue_sign,n.glue_order
        inner.dir=n.dir
        inner.head=n.head;n.head=inner
        properties.docxlike_link_content=true
        node.setproperty(n,properties)
      end
    end
  end
  return direct
end
function M.install(ul, ulc, ulfont, va, vaja, bold, fill, exact)
  ul_attr, ulc_attr, ulfont_attr, va_attr, vaja_attr, bold_attr = ul, ulc, ulfont, va, vaja, bold
  pos_attr = luatexbase.attributes["docxlike@pos@attr"]
  fill_attr, exact_attr = fill, exact
  luatexbase.add_to_callback("pre_shipout_filter", function(h)
    M.baseline_shift(h)
    if M.used then
      shift(h)
      walk(h)
      if bold_attr then bolden(h) end
    end
    return true
  end, "docxlike.run")
  luatexbase.add_to_callback('pre_shipout_filter',function(head)
    link_rectangles(head,0)
    return true
  end,'docxlike.run.links')
  luatexbase.declare_callback_rule('pre_shipout_filter','docxlike.run.links','after','docxlike.run')
end



local GLUE, PENALTY, MARK, INS, WHATSIT = node.id("glue"), node.id("penalty"), node.id("mark"),
  node.id("ins"), node.id("whatsit")
local quiet = {}
for _, name in ipairs({ "open", "write", "close", "user_defined", "save_pos", "pdf_dest",
    "pdf_annot", "pdf_start_link", "pdf_end_link", "pdf_action", "pdf_refobj" }) do
  local subtype = node.subtype(name)
  if subtype then quiet[subtype] = true end
end
function M.mark_space_after()
  local tail = tex.nest[tex.nest.ptr].tail
  if tail and tail.id == GLUE then
    local p = node.getproperty(tail) or {}
    p.docxlike_space_after = tail.width
    node.setproperty(tail, p)
  end
end
function M.hidden_space_after()
  local n = tex.nest[tex.nest.ptr].tail
  while n do
    local id = n.id
    if id == GLUE then
      local p = node.getproperty(n)
      return p and p.docxlike_space_after or 0
    elseif not (id == PENALTY or id == MARK or id == INS or (id == WHATSIT and quiet[n.subtype])) then
      return 0
    end
    n = n.prev
  end
  return 0
end

return M
end
factories.linebreak = function()





local M = {}
M.version = "v3.2a"
local node, tex = node, tex
local traverse = node.traverse
local traverse_id = node.traverse_id
local GLYPH, GLUE, KERN, PENALTY, RULE, HLIST, VLIST, WHATSIT, MATH, DISC, LOCALPAR =
  node.id("glyph"), node.id("glue"), node.id("kern"), node.id("penalty"), node.id("rule"),
  node.id("hlist"), node.id("vlist"), node.id("whatsit"), node.id("math"), node.id("disc"), node.id("local_par")
local INS, MARK, ADJUST = node.id("ins"), node.id("mark"), node.id("adjust")
local cluster_cf_text = {}
local function tag_cluster_controls(head)
  
  local cluster_text = {}
  for n in traverse_id(GLYPH,head) do
    local props = node.getproperty(n)
    local text = props and props.glyph_info
    if type(text)=="string" and (text:find(utf8.char(0x200C),1,true) or text:find(utf8.char(0x200D),1,true)) then
      local id = M.cluster_attr and node.get_attribute(n,M.cluster_attr)
      local source = id and cluster_cf_text[id]
      if source and text:find(source,1,true) then cluster_text[id] = text end
    end
  end
  local first, last, active
  local function close()
    if not first then return end
    local bytes = {"FEFF"}
    for _, c in utf8.codes(cluster_text[active] or cluster_cf_text[active]) do
      if c < 0x10000 then bytes[#bytes+1]=string.format("%04X",c)
      else
        c=c-0x10000; bytes[#bytes+1]=string.format("%04X%04X",0xD800+(c>>10),0xDC00+(c&0x3FF))
      end
    end
    local begin = node.new("whatsit","pdf_literal"); begin.mode=1
    begin.data="/Span<</ActualText<"..table.concat(bytes)..">>>BDC"
    local finish = node.new("whatsit","pdf_literal"); finish.mode=1; finish.data="EMC"
    head=node.insert_before(head,first,begin)
    head=node.insert_after(head,last,finish)
    first,last,active=nil,nil,nil
  end
  local n=head
  while n do
    local following=n.next
    local id=M.cluster_attr and node.get_attribute(n,M.cluster_attr)
    if id and cluster_cf_text[id] then
      if active and active~=id then close() end
      if not first then first,active=n,id end
      last=n
    elseif n.id==GLYPH then close() end
    n=following
  end
  close()
  return head
end
local LTJ = docxlike.runtime.load("ltj")

local function set_of(s)
  local t = {}
  for _, c in utf8.codes(s) do t[c] = true end
  return t
end

local closers = set_of("。，、；：？！）》〉”’」』】］．｝〕〗〙〛")
local openers = set_of("（《〈「『【“‘［｛〔〖〘〚")
local closing_for = {}
do
  local left, right = {}, {}
  for _,c in utf8.codes("（《〈「『【“‘［｛〔〖〘〚") do left[#left+1]=c end
  for _,c in utf8.codes("）》〉」』】”’］｝〕〗〙〛") do right[#right+1]=c end
  for i,c in ipairs(left) do closing_for[c]=right[i] end
end

local never_compressed = set_of("？")

local latinish = set_of("～—–·")
local ascii_close = set_of(".,;:!?)]}%")
local ascii_open = set_of("([{")
local ascii_bracket_close = set_of(")]}")

local no_line_start = set_of("!%),.:;>?]}¢¨°·ˇˉ―‖’”…‰′″›℃∶")
local no_line_end = set_of("$([{£¥·‘“〈《「『【〔〖〝")

local connectors = set_of("—–―…‖～")
local legacy_dashes = set_of("—–―")

M.trace = false
M.compat = 11   
M.code_optimal = true
M.snap = false  
M.cell = false  


local DEVU = 0.012 * 65781.76
local function devtrunc(x)
  local q = x / DEVU
  if q >= 0 then q = math.floor(q + 1e-6) else q = math.ceil(q - 1e-6) end
  return q * DEVU
end
local function devround(x)
  return math.floor(x / DEVU + .5) * DEVU
end

local function trace(...)
  if M.trace then texio.write_nl("term and log", "HG| " .. string.format(...)) end
end
local function trace_char(c)
  return c>=0 and c<=0x10FFFF and utf8.char(c) or string.format("<glyph:%X>",c)
end

local is_jfont, is_packed, is_kinsoku = LTJ.is_jfont, LTJ.is_packed, LTJ.is_kinsoku
local is_jfmglue, is_kanjiskip, is_xkanjiskip = LTJ.is_jfmglue, LTJ.is_kanjiskip, LTJ.is_xkanjiskip
local function is_wide(c)
  if not c then return false end
  return (c >= 0x2E80 and c <= 0x2FDF) or (c >= 0x3000 and c <= 0x30FF) or (c >= 0x3100 and c <= 0x33FF)
    or (c >= 0x3400 and c <= 0x9FFF) or (c >= 0xAC00 and c <= 0xD7AF) or (c >= 0x1100 and c <= 0x11FF)
    or (c >= 0xF900 and c <= 0xFAFF) or (c >= 0xFE30 and c <= 0xFE4F) or (c >= 0xFF00 and c <= 0xFF60)
    or (c >= 0xFFE0 and c <= 0xFFE6) or (c >= 0x20000 and c <= 0x3134F)
end
local function is_hangul(c)
  return c and ((c >= 0xAC00 and c <= 0xD7A3) or (c >= 0x1100 and c <= 0x11FF)
    or (c >= 0xA960 and c <= 0xA97F) or (c >= 0xD7B0 and c <= 0xD7FF))
end

local function is_latin_letter(c)
  return c ~= nil and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 0xC0 and c <= 0x24F and c ~= 0xD7 and c ~= 0xF7))
end
local function is_alnum(c)
  if not c then return false end
  return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
    or (c >= 0xC0 and c <= 0x24F and c ~= 0xD7 and c ~= 0xF7) or (c >= 0x370 and c <= 0x4FF)
    or (c >= 0x1E00 and c <= 0x1EFF)
end
local function is_digit(c)
  return c and c >= 48 and c <= 57
end
local function device_latin_run(it)
  if not it.glyphs or not it.glist then return false end
  for _,g in ipairs(it.glist) do
    local c=g.char
    if c>=0x250 and not (c>=0x300 and c<=0x36F)
      and not (c>=0x1E00 and c<=0x1EFF) and not (c>=0x2000 and c<=0x206F)
      and not (c>=0x20A0 and c<=0x20CF) then return false end
  end
  return true
end

local sizecache, spacecache = {}, {}
local function fsize(fid)
  local s = sizecache[fid]
  if not s then
    local f = font.getfont(fid)
    s = (f and f.size) or tex.sp("1em")
    
    local R = docxlike.run
    local w = R and R.wscale and R.wscale[fid]
    if w then s = math.floor(s * w + 0.5) + (R.wadd[fid] or 0) end
    sizecache[fid] = s
  end
  return s
end
local function fspace(fid)
  local s = spacecache[fid]
  if not s then
    local f = font.getfont(fid)
    s = (f and f.parameters and f.parameters.space) or 0
    spacecache[fid] = s
  end
  return s
end

local boldcache = {}
local bold_attr = false
local function bold_info(fid)
  local v = boldcache[fid]
  if not v then
    local f = font.getfont(fid)
    local md = f and f.shared and f.shared.rawdata and f.shared.rawdata.metadata
    local w = string.lower(md and md.weight or "")
    v = { stroked = f ~= nil and f.mode == 2,
          real = w:find("bold") ~= nil or w:find("black") ~= nil or w:find("heavy") ~= nil,
          extra = ((f and f.size) or 0) / 280 }
    boldcache[fid] = v
  end
  return v
end
local function fake_bold(n)
  if bold_attr == false then bold_attr = luatexbase.attributes["docxlike@bold@attr"] end
  local b = bold_info(n.font)
  if b.stroked then return b.extra end
  if bold_attr and not b.real and node.has_attribute(n, bold_attr) then return b.extra end
  return 0
end
M.fake_bold = fake_bold


local kernfile, kerncache = {}, {}

local function device_advance(g)
  local f=font.getfont(g.font)
  local size=f and f.size
  if not f or f.format~='truetype' then return g.width end
  local device_size=size and math.floor(size/DEVU+1/DEVU)*DEVU
  return size and size>0 and devround(g.width*device_size/size) or g.width
end
local printed_font_cache={}
local geometry_snapshot
local function printed_font(fid)
  local cached=printed_font_cache[fid]
  if cached then return cached end
  local f=font.getfont(fid)
  cached=fid
  if f and f.format=='truetype' and f.size and f.size>0 then
    local pixel=.12*65781.76
    
    
    
    local size=math.floor((f.size+1)/pixel+.5)*pixel
    local extend=f.extend
    local run=docxlike.run
    local stretch=run and run.wscale and run.wscale[fid]
    if stretch and stretch~=1 and docxlike.metrics and docxlike.metrics.avg_width then
      
      
      
      local average=docxlike.metrics.avg_width(fid)
      average=average and math.floor(average*size/pixel+.5)
      if average and average>0 then
        local requested=math.floor(average*stretch+1e-9)
        if requested>0 then extend=math.floor((f.extend or 1000)*requested/(average*stretch)+.5) end
      end
    end
    if math.abs(size-f.size)>1 or extend~=f.extend then
      
      local copy
      if f.name and fonts and fonts.definers and fonts.definers.read then
        
        local ok,t=pcall(fonts.definers.read,(f.name:gsub('"','')),size)
        if ok and type(t)=='table' and t.characters then
          
          
          copy={}
          for k,v in pairs(t) do copy[k]=v end
          copy.extend,copy.slant,copy.squeeze=f.extend,f.slant,f.squeeze
          copy.mode=f.mode
          copy.width=f.width and f.width*size/f.size
        end
      end
      if not copy then
        copy=font.getcopy(fid)
        copy.used=false
        local ratio=size/f.size
        copy.size=size
        for _,c in pairs(copy.characters) do
          for _,key in ipairs({'width','height','depth','italic'}) do
            if c[key] then c[key]=c[key]*ratio end
          end
        end
        for _,key in ipairs({'space','space_stretch','space_shrink','x_height','quad','extra_space'}) do
          if copy.parameters[key] then copy.parameters[key]=copy.parameters[key]*ratio end
        end
      end
      copy.extend=extend
      copy.used=false
      cached=font.define(copy)
      
      
      
      if fonts and fonts.hashes and fonts.hashes.identifiers then
        copy.id=cached
        fonts.hashes.identifiers[cached]=copy
      end
      printed_font_cache[cached]=cached
    end
  end
  printed_font_cache[fid]=cached
  return cached
end
local function paint_device_fonts(head,inside_toc)
  local g=head
  while g do
    local next=g.next
    local math_object=(node.getproperty(g) or {}).docxlike_math_object
    if g.id==GLYPH and not math_object then
      local fid=printed_font(g.font)
      if fid~=g.font then
        local width=g.width
        g.font=fid
        local kern=node.new(KERN);kern.kern=width-g.width
        head=node.insert_after(head,g,kern)
      end
    elseif g.id==HLIST and g.head and not math_object then
      local attr=luatexbase.attributes['docxlike@toc@tail@attr']
      local toc=inside_toc or attr and node.has_attribute(g,attr)
      if toc or is_packed(g) then g.head=paint_device_fonts(g.head,toc) end
    end
    g=next
  end
  return head
end



















local latin_device={fonts={},bp=65781.76,pixel=.12*65781.76}
function latin_device.float32(x) return string.unpack('<f',string.pack('<f',x)) end
function latin_device.truncate(x) return math.modf(x) end
function latin_device.font_info(fid)
  if latin_device.fonts[fid]~=nil then return latin_device.fonts[fid] or nil end
  local source=font.getfont(fid)
  local run=docxlike.run
  if not source or source.format~='truetype' or not source.size or source.size<=0
      or source.hb or source.type=='virtual' or source.mode==2
      or run and run.wscale and run.wscale[fid] and run.wscale[fid]~=1
      or run and run.metric_size and run.metric_size[fid] and math.abs(run.metric_size[fid]-source.size)>1
      or run and run.wadd and run.wadd[fid] and run.wadd[fid]~=0 then
    latin_device.fonts[fid]=false;return
  end
  local height=math.floor((source.size+1)/latin_device.pixel+.5)
  if height<=0 then latin_device.fonts[fid]=false;return end
  local printed=math.floor(height*latin_device.pixel+.5)
  local value={source=source,source_id=fid,height=height,printed=printed,printed_bp=printed/latin_device.bp,
    key=(source.filename or '')..':'..tostring(height)..':'..tostring(source.fullname)}
  latin_device.fonts[fid]=value
  return value
end
function latin_device.realize(value)
  if value.id then return value.id end
  local source,printed=value.source,value.printed
  local copy=font.getcopy(value.source_id)
  
  
  
  copy.used=false
  local ratio=printed/source.size
  
  
  
  copy.fullname=(source.fullname or source.name or 'TrueType')..'-docxlike-integer-widths'
  copy.size=printed
  for _,c in pairs(copy.characters) do
    if c.width then c.width=math.floor(math.floor(c.width/source.size*1000+.5)*printed/1000+.5) end
    for _,key in ipairs({'height','depth','italic'}) do if c[key] then c[key]=c[key]*ratio end end
  end
  for _,key in ipairs({'space','space_stretch','space_shrink','x_height','quad','extra_space'}) do
    if copy.parameters[key] then copy.parameters[key]=copy.parameters[key]*ratio end
  end
  value.id=font.define(copy)
  if fonts and fonts.hashes and fonts.hashes.identifiers then
    copy.id=value.id
    fonts.hashes.identifiers[value.id]=copy
  end
  return value.id
end
function latin_device.transform(box,allocate_device,single_gap,word_widths,normalize_fallback)
  local units={}
  local position=0
  local last_font
  local last_language
  local line_language
  local unsupported=false
  local extended=false
  local mixed_language=false
  local extended_latin=false
  local pending_split=false
  local function glue_width(n)
    local value=n.width
    if box.glue_sign==1 and n.stretch_order==box.glue_order then value=value+box.glue_set*n.stretch
    elseif box.glue_sign==2 and n.shrink_order==box.glue_order then value=value-box.glue_set*n.shrink end
    return value
  end
  local function collect(head)
    for n in node.traverse(head) do
      if n.id==GLYPH then
        local code=M.code_attr and node.get_attribute(n,M.code_attr)
        
        
        
        if n.char>0xff then
          if (word_widths or normalize_fallback) and (n.char<=0x24f or n.char>=0x2000 and n.char<=0x206f) then
            extended=true
            if n.char<=0x24f then extended_latin=true end
          else unsupported=true;return end
        end
        if code and code>0 or (node.getproperty(n) or {}).docxlike_math_object then unsupported=true;return end
        local language=M.language_attr and node.get_attribute(n,M.language_attr) or 0
        if line_language~=nil and language~=line_language then
          if normalize_fallback then mixed_language=true else unsupported=true;return end
        end
        line_language=language
        local fi=latin_device.font_info(n.font)
        if not fi then unsupported=true;return end
        local ch=fi.source.characters[n.char]
        if not ch or not ch.width then unsupported=true;return end
        units[#units+1]={glyph=n,head=head,fi=fi,logical_x=position,
          ideal=n.width/latin_device.pixel,base=math.floor(n.width/fi.source.size*fi.height+.5),
          norm=math.floor(ch.width/fi.source.size*1000+.5),split=pending_split or n.char==0xa0,old_width=n.width,
          language=language}
        
        
        
        pending_split=n.char==0xa0
        position=position+n.width
        last_font=fi
        last_language=units[#units].language
      elseif n.id==DISC then
        local soft=M.soft_hyphen_attr and node.get_attribute(n,M.soft_hyphen_attr)==1
        if not soft and M.soft_hyphen_attr then
          for g in node.traverse(n.pre) do
            if node.get_attribute(g,M.soft_hyphen_attr)==1 then soft=true;break end
          end
        end
        local explicit=n.subtype<=1 or soft
        if explicit then pending_split=true end
        if n.replace then collect(n.replace) end
        if explicit then pending_split=true end
      elseif n.id==GLUE then
        local w=glue_width(n)
        if n.leader then unsupported=true;return end
        if last_font and math.abs(w)>1 then
          local ch=last_font.source.characters[32]
          units[#units+1]={fi=last_font,logical_x=position,ideal=w/latin_device.pixel,
            base=math.floor(w/latin_device.pixel+.5),norm=ch and math.floor(ch.width/last_font.source.size*1000+.5) or 250,
            gap=true,split=pending_split,
            language=M.language_attr and node.get_attribute(n,M.language_attr) or last_language or 0}
          pending_split=false
        elseif not last_font and math.abs(w)>1 and (n.subtype==13 or n.subtype==14) then
          
          
          units[#units+1]={logical_x=position,ideal=w/latin_device.pixel,
            base=math.floor(w/latin_device.pixel+.5),gap=true,leading=true,
            language=M.language_attr and node.get_attribute(n,M.language_attr) or 0}
        end
        position=position+w
      elseif n.id==KERN then
        if math.abs(n.kern)>1 then unsupported=true;return end
        position=position+n.kern
      elseif n.id==WHATSIT then
        
        
        
      elseif n.id==HLIST or n.id==VLIST or n.id==MATH then unsupported=true;return
      else position=position+(n.width or 0) end
      if unsupported then return end
    end
  end
  collect(box.head)
  while #units>0 and not units[#units].glyph do units[#units]=nil end
  if unsupported or #units==0 then return end
  local realize_words=false
  if single_gap then
    local count=0
    for _,u in ipairs(units) do if u.gap and not u.leading then count=count+1 end end
    if count~=1 then
      if word_widths and count>1 then realize_words=true else return end
    end
  end
  local normalize_only=normalize_fallback and extended_latin and not mixed_language
  if mixed_language then return end
  if extended and not realize_words and not normalize_only then return end
  for _,u in ipairs(units) do
    if u.leading then
      local fi=units[#units].fi
      for _,g in ipairs(units) do if g.glyph then fi=g.fi;break end end
      local ch=fi.source.characters[32]
      u.fi=fi;u.norm=ch and math.floor(ch.width/fi.source.size*1000+.5) or 250
    end
  end
  if normalize_only then
    
    
    
    local key=units[1].fi.key
    for _,u in ipairs(units) do
      if u.fi.key~=key or math.abs(u.fi.printed-u.fi.source.size)>1
          or (u.glyph and u.head~=box.head) then return end
    end
    for _,u in ipairs(units) do
      if u.glyph then
        local g=u.glyph
        g.font=latin_device.realize(u.fi)
        local delta=u.old_width-g.width
        if delta~=0 then
          local k=node.new(KERN);k.kern=delta;node.insert_after(u.head,g,k)
        end
        local boundary=node.new('whatsit','pdf_literal')
        boundary.mode=0;boundary.data='q Q'
        box.head=node.insert_before(box.head,g,boundary)
      end
    end
    return
  end
  if realize_words then
    
    
    
    
    
    local key=units[1].fi.key
    local count,maximum=0,0
    local expected=units[1].logical_x
    for _,u in ipairs(units) do
      if u.fi.key~=key or math.abs(u.fi.printed-u.fi.source.size)>1
          or (u.glyph and u.head~=box.head) or math.abs(u.logical_x-expected)>1
          or (u.glyph and (u.glyph.expansion_factor or 0)~=0) then return end
      if u.glyph then
        count=count+1
        expected=u.logical_x+u.old_width
      elseif u.gap then
        maximum=math.max(maximum,count);count=0
        expected=u.logical_x+u.ideal*latin_device.pixel
      end
    end
    if math.max(maximum,count)<3 then return end
    local cursor,advance=units[1].logical_x,0
    local word_unit=units[1].fi.source.size/1000
    for _,u in ipairs(units) do
      if u.glyph then
        u.printed_x=(cursor+advance)/latin_device.bp
        advance=advance+u.old_width
      elseif u.gap then
        cursor=cursor+math.floor(advance/word_unit+1e-6)*word_unit+u.ideal*latin_device.pixel
        advance=0
      end
    end
    for _,u in ipairs(units) do
      if u.glyph then
        local g=u.glyph
        g.font=latin_device.realize(u.fi)
        local delta=u.old_width-g.width
        if delta~=0 then
          local k=node.new(KERN);k.kern=delta
          node.insert_after(u.head,g,k)
        end
        g.xoffset=math.floor(u.printed_x*latin_device.bp-u.logical_x+.5)
        
        
        
        local boundary=node.new('whatsit','pdf_literal')
        boundary.mode=0;boundary.data='q Q'
        box.head=node.insert_before(box.head,g,boundary)
      end
    end
    return
  end
  if not allocate_device then
    
    
    
    for _,u in ipairs(units) do
      if u.glyph then
        local g=u.glyph
        g.font=latin_device.realize(u.fi)
        local delta=u.old_width-g.width
        if delta~=0 then
          local k=node.new(KERN);k.kern=delta
          node.insert_after(u.head,g,k)
        end
      end
    end
    return
  end
  local target,device=0,0
  for i,u in ipairs(units) do
    u.device_origin=device
    target=target+u.ideal
    device=device+u.base
    local error=target-device
    local following=units[i+1]
    local ahead=following and following.ideal-following.base or 0
    local correction=math.abs(error+ahead)>1.5+1e-10 and latin_device.truncate(error) or 0
    device=device+correction
    u.dx=u.base+correction
  end
  local origin=units[1].logical_x/latin_device.bp
  local cursor=origin
  local first=1
  while first<=#units do
    local last=first
    while last<#units and units[last+1].fi.key==units[first].fi.key
        and units[last+1].language==units[first].language and not units[last+1].split do last=last+1 end
    local nominal,wanted,sw,sd=0,0,0,0
    if first>1 then
      
      
      
      cursor=(units[first].logical_x+(units[first].glyph and units[first].glyph.xoffset or 0))/latin_device.bp
    end
    for i=first,last do
      local u=units[i]
      u.printed_x=cursor
      cursor=cursor+u.norm*u.fi.printed_bp/1000
      nominal=latin_device.float32(nominal+latin_device.float32(u.norm/1000))
      wanted=latin_device.float32(wanted+latin_device.float32(u.dx/u.fi.height))
      sw,sd=sw+u.norm,sd+u.dx
      if last-first+1>2 and i<last and math.abs(latin_device.float32(nominal-wanted))>latin_device.float32(.003) then
        local numerator=sw*u.fi.height-sd*1000
        local adjustment=latin_device.truncate((2*numerator+u.fi.height)/(2*u.fi.height))
        cursor=cursor-adjustment*u.fi.printed_bp/1000
        nominal,wanted,sw,sd=0,0,0,0
      end
    end
    first=last+1
  end
  for _,u in ipairs(units) do
    if u.glyph then
      local g=u.glyph
      g.font=latin_device.realize(u.fi)
      local delta=u.old_width-g.width
      if delta~=0 then
        local k=node.new(KERN);k.kern=delta
        node.insert_after(u.head,g,k)
      end
      g.xoffset=math.floor(u.printed_x*latin_device.bp-u.logical_x+.5)
    end
  end
end
local function paint_word_lines(head)
  for n in traverse(head) do
    if n.id==HLIST or n.id==VLIST then
      local properties=node.getproperty(n) or {}
      if properties.docxlike_device_fonts then
        if properties.docxlike_latin_device_fonts then
          latin_device.transform(n,properties.docxlike_latin_device_allocate,properties.docxlike_latin_device_single_gap,properties.docxlike_latin_device_word_widths,properties.docxlike_latin_device_normalize)
          properties.docxlike_latin_device_fonts=nil
          properties.docxlike_latin_device_allocate=nil
          properties.docxlike_latin_device_single_gap=nil
          properties.docxlike_latin_device_word_widths=nil
          properties.docxlike_latin_device_normalize=nil
        end
        n.head=paint_device_fonts(n.head)
        local geometry=properties.docxlike_geometry_trace
        if geometry and type(M._geometry_observer)=='function' then
          geometry.printed=geometry_snapshot(n.head,n.shift or 0,n)
          M._geometry_observer('printed',geometry)
          properties.docxlike_geometry_trace=nil
        end
        properties.docxlike_device_fonts=nil
        node.setproperty(n,properties)
      elseif n.head then paint_word_lines(n.head) end
    end
  end
end
luatexbase.add_to_callback('pre_shipout_filter',function(head)
  paint_word_lines(head)
  return true
end,'docxlike.linebreak.device-fonts')
if luatexbase.declare_callback_rule then
  luatexbase.declare_callback_rule('pre_shipout_filter','docxlike.linebreak.device-fonts','after','docxlike.run')
  luatexbase.declare_callback_rule('pre_shipout_filter','docxlike.run.links','after','docxlike.linebreak.device-fonts')
end
local getbool
local function native_controls()
  return getbool("l__docxlike_latex_controls_bool") == true
end
local function read_kern_table(filename, subfont)
  local fh = io.open(filename, "rb")
  if not fh then return nil end
  local hdr = fh:read(12)
  if hdr and hdr:sub(1, 4) == "ttcf" then
    fh:seek("set", 12 + 4 * ((subfont or 1) - 1))
    local base = string.unpack(">I4", fh:read(4))
    fh:seek("set", base); hdr = fh:read(12)
  end
  if not hdr or #hdr < 12 then fh:close(); return nil end
  local n = string.unpack(">I2", hdr, 5)
  local dir = fh:read(16 * n)
  local kern, head
  for i = 0, n - 1 do
    local tag, _, off, len = string.unpack(">c4I4I4I4", dir, 1 + 16 * i)
    if tag == "kern" then kern = { off, len } elseif tag == "head" then head = off end
  end
  if not kern or not head then fh:close(); return nil end
  fh:seek("set", head + 18)
  local upem = string.unpack(">I2", fh:read(2))
  fh:seek("set", kern[1])
  local data = fh:read(kern[2])
  fh:close()
  local version, ntab = string.unpack(">I2I2", data, 1)
  if version ~= 0 then return nil end
  local t, pos = {}, 5
  for _ = 1, ntab do
    local _, len, cov = string.unpack(">I2I2I2", data, pos)
    if cov >> 8 == 0 and cov & 7 == 1 then
      local np = string.unpack(">I2", data, pos + 6)
      local q = pos + 14
      for _ = 1, np do
        local l, r, v = string.unpack(">I2I2i2", data, q)
        local row = t[l]
        if not row then row = {}; t[l] = row end
        row[r] = (row[r] or 0) + v
        q = q + 6
      end
    end
    pos = pos + len
  end
  return t, upem
end

local function kern_pairs(fid, space)
  local ansi = getbool("g_docxlike_ansi_kerning_bool") == true
  local cache_key = tostring(fid) .. ":" .. tostring(ansi) .. ":" .. tostring(space == true)
  local v = kerncache[cache_key]
  if v ~= nil then return v end
  v = false
  local f = font.getfont(fid)
  local gpos = f and f.resources and f.resources.features and f.resources.features.gpos
  local shaped = gpos and gpos.kern and f.shared and f.shared.features and f.shared.features.kern
  if f and f.filename and f.size and not is_jfont(fid) and (ansi or space or not shaped) then
    local sub = f.subfont or (f.specification and f.specification.sub)
    local key = f.filename .. ":" .. tostring(sub)
    local raw = kernfile[key]
    if raw == nil then
      local ok, t, upem = pcall(read_kern_table, f.filename, sub)
      raw = (ok and t and upem) and { t, upem } or false
      kernfile[key] = raw
    end
    
    if raw then v = { pairs = raw[1], scale = f.size / raw[2], chars = f.characters or {} } end
  end
  kerncache[cache_key] = v
  return v
end
local function pair_kern(fid, a, b)
  local t = kern_pairs(fid, a == 32 or b == 32)
  if not t then return 0 end
  local ca, cb = t.chars[a], t.chars[b]
  local r = ca and cb and ca.index and t.pairs[ca.index]
  local val = r and r[cb.index]
  return val and math.floor(val * t.scale + 0.5) or 0
end
M.pair_kern = pair_kern

local function invisible_box(b)
  if b.width ~= 0 then return false end
  local function empty(list)
    for x in node.traverse(list) do
      local id = x.id
      if id == GLYPH or (id == RULE and x.width ~= 0) or id == MATH then return false end
      if (id == HLIST or id == VLIST) and not (x.width == 0 and empty(x.head)) then return false end
      if id == DISC and not (empty(x.pre) and empty(x.post) and empty(x.replace)) then return false end
    end
    return true
  end
  return empty(b.head)
end
M.invisible_box = invisible_box

local SP_NOISE = 2

local function fold_lastskip(head)
  for g in node.traverse_id(GLUE, head) do
    local h = g.next
    if g.subtype == 0 and g.width < 0 and h and h.id == GLUE and h.subtype == 0 then
      local q = g.prev
      while q and (q.id == PENALTY or q.id == WHATSIT or q.id == MARK) do q = q.prev end
      if q and q.id == GLUE and q.width == -g.width and q.stretch == -g.stretch and q.shrink == -g.shrink
          and h.stretch == q.stretch and h.shrink == q.shrink
          and h.stretch_order == q.stretch_order and h.shrink_order == q.shrink_order then
        g.width, g.stretch, g.shrink = 0, 0, 0
        h.width, h.stretch, h.shrink = 0, 0, 0
      end
    end
  end
end
local function kern_enabled(n)
  if not M.kern_attr then return true end
  local v = node.get_attribute(n, M.kern_attr)
  return v == nil or v ~= 0
end

local fletter
local harfcache = {}
local function harf(fid)
  local v = harfcache[fid]
  if v == nil then
    local f = font.getfont(fid)
    v = (f and f.hb) and true or false
    harfcache[fid] = v
  end
  return v
end
local function legacy_kern(head)
  local lastg, mid = nil, nil
  local ansi = getbool("g_docxlike_ansi_kerning_bool") == true
  local function process(list)
    local n = list
    while n do
      local id = n.id
      if id == GLYPH then
        if lastg and lastg.font == n.font then
          local replace = ansi and kern_pairs(n.font)
          local enabled = kern_enabled(lastg)
          local k = enabled and pair_kern(n.font, lastg.char, n.char) or 0
          
          if mid and replace then
            mid.kern = fletter(n.font) + k
          elseif mid and not enabled and not harf(n.font) then
            
            
            mid.kern = fletter(n.font)
          elseif k ~= 0 and enabled then
            if mid then
              mid.kern = mid.kern + k
            else
              local kn = node.new(KERN); kn.subtype = 0; kn.kern = k
              
              list = node.insert_before(list, n, kn)
            end
          end
        end
        lastg, mid = n, nil
      elseif id == KERN and n.subtype == 0 and lastg and not mid then
        mid = n
      elseif id == DISC then
        
        if n.replace then n.replace = process(n.replace) end
      else
        lastg, mid = nil, nil
      end
      n = n.next
    end
    return list
  end
  return process(head)
end
local lscache = {}
fletter = function(fid)
  local v = lscache[fid]
  if not v then
    local f = font.getfont(fid)
    local kc = f and f.properties and f.properties.kerncharacters
    v = 0
    if kc and kc ~= "max" and f.parameters and f.parameters.quad then v = kc * f.parameters.quad end
    lscache[fid] = v
  end
  return v
end

local function nodewidth(g)
  local id = g.id
  if id == GLYPH or id == HLIST or id == VLIST or id == RULE then return g.width
  elseif id == GLUE then return g.width
  elseif id == KERN then return g.kern
  elseif id == DISC then
    local w = 0
    for h in traverse(g.replace) do if h.id == GLYPH then w = w + h.width elseif h.id == KERN then w = w + h.kern end end
    return w
  else return 0 end
end
geometry_snapshot=function(head,origin,box)
  local result={glyphs={},opaque_boxes={}}
  local bp=65781.76
  local function width(g,parent)
    local w=nodewidth(g)
    if g.id==GLUE and parent then
      if parent.glue_sign==1 and g.stretch_order==parent.glue_order then w=w+parent.glue_set*g.stretch
      elseif parent.glue_sign==2 and g.shrink_order==parent.glue_order then w=w-parent.glue_set*g.shrink end
    end
    return w
  end
  local function walk(list,position,parent)
    for g in traverse(list) do
      if g.id==GLYPH then
        local f=font.getfont(g.font) or {}
        local c=f.characters and f.characters[g.char]
        result.glyphs[#result.glyphs+1]={char=g.char,text=trace_char(g.char),font_id=g.font,
          font_name=f.psname or f.fullname or f.name or '',font_file=tostring(f.filename or ''),
          subfont=tonumber(f.subfont) or 0,size_bp=(f.size or 0)/bp,
          x_bp=(position+g.xoffset)/bp,xoffset_bp=g.xoffset/bp,yoffset_bp=g.yoffset/bp,
          advance_bp=g.width/bp,font_advance_bp=c and c.width and c.width/bp or nil}
      elseif g.id==HLIST and is_packed(g) then
        walk(g.head,position,g)
      elseif g.id==DISC then
        walk(g.replace,position,nil)
      elseif g.id==HLIST or g.id==VLIST then
        result.opaque_boxes[#result.opaque_boxes+1]={x_bp=position/bp,width_bp=g.width/bp,
          math_object=(node.getproperty(g) or {}).docxlike_math_object==true}
      end
      position=position+width(g,parent)
    end
    return position
  end
  result.end_x_bp=walk(head,origin or 0,box)/bp
  return result
end
local function spanwidth(it)
  local w = 0
  local g = it.first
  while g do w = w + nodewidth(g); if g == it.last then break end; g = g.next end
  return w
end
local function punctuation_ink(it)
  local g=it.core
  if g and g.id==HLIST then
    g=g.head
    while g and g.id~=GLYPH do g=g.next end
  end
  local f=g and g.id==GLYPH and font.getfont(g.font)
  local raw=f and f.shared and f.shared.rawdata
  local desc=raw and raw.descriptions and raw.descriptions[g.char]
  local bounds=desc and desc.boundingbox
  if bounds and f.units_per_em then
    return f.size*bounds[1]/f.units_per_em,f.size*bounds[3]/f.units_per_em
  end
end


local function box_ends(b)
  local hd, tl, lead_glue, trail_glue
  local function walk(list)
    for g in traverse(list) do
      if g.id == GLYPH then
        if not hd then hd = g.char end
        tl = g.char; trail_glue = false
      elseif (g.id == HLIST or g.id == VLIST) and g.shift == 0 then
        walk(g.list)
      elseif g.id == GLUE and g.width ~= 0 then
        if not hd then lead_glue = true end
        trail_glue = true
      end
    end
  end
  walk(b.list)
  if lead_glue then hd = nil end
  if trail_glue then tl = nil end
  return hd, tl
end





local toc_tail_attr = luatexbase.attributes["docxlike@toc@tail@attr"]
local function tokenize(head, split_code, nogrid)
  local items = {}
  local run = nil
  local lastsize, lastfont = nil, nil
  local function flush_run()
    if run then items[#items + 1] = run; run = nil end
  end
  local function put(kind, first, last, w, c, size)
    flush_run()
    items[#items + 1] = { kind = kind, first = first, last = last, core = last, w = w, c = c, size = size or lastsize or tex.sp("1em") }
    return items[#items]
  end
  local function attach(n)
    if run then run.last = n elseif #items > 0 then items[#items].last = n end
  end
  local function is_code(g)
    return M.code_attr and (node.get_attribute(g, M.code_attr) or 0) ~= 0
  end
  local function addglyph(n, c, w)
    if split_code and run and (not not run.code) ~= (not not is_code(n)) then flush_run() end
    local size = fsize(n.font)
    lastsize = size; lastfont = n.font
    if not run then
      run = { kind = 3, first = n, last = n, gw = 0, gn = 0, kw = 0, head = c, tail = c, kerns = {}, glist = {},
              size = size, head_w = w, second_w = 0, tail_w = w, c = c, fb = fake_bold(n), font = n.font }
    end
    run.tailfont = n.font
    run.hangul = run.hangul or (is_hangul(c) and is_jfont(n.font))
    local source = M.cluster_start_attr and node.get_attribute(n,M.cluster_start_attr) or c
    run.thai = run.thai or (source and source >= 0xE00 and source <= 0xE7F)
    if is_code(n) then run.code = true end
    run.last = n; run.core = n; run.gw = run.gw + w; run.gn = run.gn + 1; run.tail = c; run.tail_w = w
    if run.gn == 2 then run.second_w = w end
    run.glist[#run.glist + 1] = n
    
    run.tail_hang = ascii_close[c] and w or 0
  end
  local function putja(n, c, w, size)
    lastsize = size
    local it
    local id=M.language_attr and node.get_attribute(n,M.language_attr)
    if not id and n.id==HLIST then
      local g=n.head
      while g and g.id~=GLYPH do g=g.next end
      id=g and M.language_attr and node.get_attribute(g,M.language_attr)
    end
    local profile=id and (docxlike.language_profiles or {})[id]
    
    local korean_stop=nogrid and c==0x3002 and profile and profile.script=="Kore"
    if korean_stop then
      it=put(0,n,n,size,c,size)
      it.word_loose_start=true
    elseif closers[c] then it = put(1, n, n, size, c, size)
    elseif openers[c] then it = put(2, n, n, size, c, size)
    elseif not is_wide(c) then
      it = put((no_line_start[c] and not connectors[c]) and 1 or 0, n, n, w, c, size)
      it.symbol = true
    else it = put(0, n, n, size, c, size) end
    if n.id == GLYPH then it.fb = fake_bold(n) end
    local glyph=n.id==GLYPH and n or n.id==HLIST and n.head
    while glyph and glyph.id~=GLYPH do glyph=glyph.next end
    local R=docxlike.run
    it.run_spacing=glyph and R and R.wadd and R.wadd[glyph.font] or 0
    return it
  end
  fold_lastskip(head)
  local n = head
  local indent = 0
  local strut_h, strut_d = 0, 0
  local lead = nil   
  while n do
    local id = n.id
    local nxt = n.next
    if #items == 0 and not run and not lead and id ~= LOCALPAR and not (id == HLIST and n.subtype == 3) then lead = n end
    if id == LOCALPAR then
    elseif id == HLIST and n.subtype == 3 then
      
      indent = n.width
      lead = nil
    elseif id == GLYPH then
      local c = n.char
      
      if is_jfont(n.font) and not latinish[c] and not is_hangul(c) then
        putja(n, c, n.width, fsize(n.font))
      else
        
        if latinish[c] then flush_run() end
        addglyph(n, c, n.width)
        if latinish[c] then flush_run() end
      end
    elseif id == HLIST and toc_tail_attr and node.get_attribute(n,toc_tail_attr)==1 then
      local it=put(3,n,n,n.width,nil)
      it.rigid=true; it.toc_tail=n
    elseif id == HLIST and is_packed(n) then
      local g = n.head
      while g and g.id ~= GLYPH do g = g.next end
      local c = g and g.char or 0
      local size = g and fsize(g.font) or lastsize or tex.sp("1em")
      
      
      local it = putja(n, c, n.width, size)
      if c == 0xB7 and g then
        local fd = font.getfont(g.font)
        local ch = fd and fd.characters and fd.characters[c]
        local real = ch and ch.width or size
        if real > n.width then it.w = real; it.midpad = n.width end
      end
    elseif id == GLUE then
      if is_kanjiskip(n) then
        attach(n)
      elseif is_xkanjiskip(n) then
        attach(n)
        local it = run or items[#items]
        if it and n.width ~= 0 then it.xk = true end
      elseif is_jfmglue(n) then
        if #items > 0 and not run and (items[#items].kind == 1 or items[#items].kind == 2) and not items[#items].jfmglue then
          items[#items].last = n; items[#items].jfmglue = n
        else
          attach(n)
        end
      elseif n.subtype == 13 or n.subtype == 14 then
        if n.width == 0 and run and run.thai then
          attach(n)
        else
        
        
        local sf = M.spacefont_attr and node.get_attribute(n, M.spacefont_attr)
        if not sf or sf <= 0 then sf = lastfont end
        
        local R = docxlike.run
        local sk = sf and R.scale_attr and node.get_attribute(n, R.scale_attr) or 100
        local sc = sf and R.smallcaps_attr and node.get_attribute(n, R.smallcaps_attr) == 1
        local cs = sf and R.spacing_attr and node.get_attribute(n, R.spacing_attr) or 0
        if sk ~= 100 or sc or cs ~= 0 then sf = R.derived_font(sf, sk, sc, cs) end
        if M.trace then
          local a,b=sf and font.getfont(sf),lastfont and font.getfont(lastfont)
          trace('SPACE source=%s last=%s width=%.6f lastwidth=%.6f',
            a and a.fullname or '?',b and b.fullname or '?',
            (sf and fspace(sf) or 0)/65781.76,(lastfont and fspace(lastfont) or 0)/65781.76)
        end
        local boundary = n.width == 0
        local w = boundary and 0 or (sf and fspace(sf) or 0)
        if not boundary and w <= 0 then w = n.width end
        local it = put(4, n, n, w, nil, sf and fsize(sf))
        it.sfont, it.boundary = sf, boundary
        end
      elseif n.subtype == 0 and n.width > SP_NOISE then
        if M.balanced_space_attr and node.get_attribute(n,M.balanced_space_attr)==1 then
          
          local it = put(4,n,n,n.width,nil)
          it.sbcs=true
          it.sfont=M.spacefont_attr and node.get_attribute(n,M.spacefont_attr) or lastfont
        else
          
          local it = put(4, n, n, n.width, nil)
          it.user = true; it.rigid = true
        end
      else
        attach(n)
      end
    elseif id == KERN and #items == 0 and not run then
      
      indent = indent + n.kern
      n.kern = 0
    elseif id == KERN then
      if run then
        run.last = n
        if n.subtype == 0 then
          
          local real = n.kern - (lastfont and fletter(lastfont) or 0)
          if math.abs(real) < 16 then real = 0 end
          run.kerns[#run.kerns + 1] = { n, real }
          run.kw = run.kw + real
        else
          run.kw = run.kw + n.kern; run.core = n
        end
      else
        attach(n)
      end
    elseif id == DISC then
      
      local w, c, code, kw, fontid, kerns = 0, nil, false, 0, lastfont, {}
      for g in traverse(n.replace) do
        if g.id == GLYPH then
          w = w + g.width; c = g.char; code = code or is_code(g); fontid = g.font
        elseif g.id == KERN then
          local real = g.kern
          if g.subtype == 0 then
            real = real - (fontid and fletter(fontid) or 0)
            if math.abs(real) < 16 then real = 0 end
            kerns[#kerns + 1] = {g, real}
          end
          kw = kw + real
        end
      end
      local native = native_controls() and n.subtype == 0
      local optional_break = not c and run and n.pre and not n.post
        and (n.subtype <= 1 or getbool("g_docxlike_format_hyphen_bool"))
      if native_controls() and (n.penalty or 0) >= 10000 then optional_break = false end
      if native then
        
        if not run then
          run = {kind=3,first=n,last=n,gw=0,gn=0,kw=0,kerns={},glist={},
            size=lastsize or tex.sp("1em"),head_w=0,second_w=0,tail_w=0}
        end
        run.last = n
        run.gw = run.gw + (n.replace and node.dimensions(n.replace) or 0) - kw
        local count = 0
        for g in traverse(n.replace) do
          if g.id == GLYPH then
            count=count+1
            run.head=run.head or g.char; run.tail=g.char; run.c=run.c or g.char
          end
        end
        run.gn=run.gn+count
        run.native_discs=run.native_discs or {}
        run.native_discs[#run.native_discs+1]=n
        optional_break=(n.penalty or 0)<10000
        if optional_break then
          run.core=n; run.native_disc=n; run.hyphen_disc=n
          run.native_delta=(n.pre and node.dimensions(n.pre) or 0)
            -(n.replace and node.dimensions(n.replace) or 0)
          run.hyphen_delta=run.native_delta
        end
      elseif c and code and n.prev then
        
        local rep = n.replace
        n.replace = nil
        local prev, after = n.prev, n.next
        local tail = node.tail(rep)
        prev.next = rep; rep.prev = prev
        tail.next = after; if after then after.prev = tail end
        n.next = nil; n.prev = nil
        node.free(n)
        nxt = rep
      elseif c then
        local size = lastsize or tex.sp("1em")
        if not run then
          run = { kind = 3, first = n, last = n, gw = 0, gn = 0, kw = 0, head = c, tail = c, kerns = {}, glist = {},
                  size = size, head_w = w, second_w = 0, tail_w = w, c = c }
        end
        run.last = n; run.core = n; run.gw = run.gw + w; run.gn = run.gn + 1; run.tail = c; run.tail_w = w
        if run.gn == 2 then run.second_w = w end
        run.discs = run.discs or {}; run.discs[#run.discs + 1] = n
        run.tail_hang = 0
      else
        attach(n)
        if optional_break then
          local pre, replacement = 0, 0
          for g in traverse(n.pre) do pre = pre + nodewidth(g) end
          for g in traverse(n.replace) do replacement = replacement + nodewidth(g) end
          run.core = n
          run.hyphen_disc = n
          run.hyphen_delta = pre - replacement
          if native_controls() then run.native_disc=n; run.native_delta=pre-replacement end
        end
      end
      if run and not code then
        run.kw = run.kw + kw
        for _, entry in ipairs(kerns) do run.kerns[#run.kerns + 1] = entry end
      end
      if c == 45 and not code and not native then flush_run() end
      if optional_break then flush_run() end
    elseif id == PENALTY then
      
      attach(n)
      if run and n.penalty < 10000 then flush_run() end
    elseif id == RULE then
      if n.width == 0 then
        
        if n.subtype == 0 and n.height > strut_h then strut_h = n.height; strut_d = n.depth end
        attach(n)
      else
        local it = put(3, n, n, n.width, nil)
        it.rigid = true; it.frame = true
      end
    elseif id == MATH then
      
      
      flush_run()
      local size = lastsize or tex.sp("1em")
      local first = n
      local m = n.next
      local last = n
      while m do
        if m.id == PENALTY and m.penalty < 10000 then
          items[#items + 1] = { kind = 3, first = first, last = m, core = m.prev, w = node.dimensions(first, m),
                                math = true, rigid = true, frame = true, size = size }
          first = m.next
        elseif m.id == MATH then
          break
        end
        last = m
        m = m.next
      end
      if m then last = m end
      items[#items + 1] = { kind = 3, first = first, last = last, core = last, w = node.dimensions(first, last.next),
                            math = true, rigid = true, frame = true, size = size }
      nxt = last.next
    elseif (id == HLIST or id == VLIST) and invisible_box(n) then
      attach(n)
    elseif id == HLIST or id == VLIST then
      flush_run()
      
      local hd, tl
      if n.shift == 0 then hd, tl = box_ends(n) end
      items[#items + 1] = { kind = 3, first = n, last = n, core = n, w = n.width, rigid = true, frame = true,
                            head = hd, tail = tl, size = lastsize or tex.sp("1em") }
    else
      attach(n)
    end
    n = nxt
  end
  flush_run()
  local tail=items[#items]
  if native_controls() and tail and tail.native_disc
      and (tail.native_disc.post or (tail.native_disc.penalty or 0)<=-10000) then
    
    local marker=node.new(HLIST)
    node.insert_after(head,tail.native_disc,marker)
    local ending=tail.last==tail.native_disc and marker or tail.last
    tail.last=tail.native_disc
    items[#items+1]={kind=3,first=marker,last=ending,core=marker,w=0,
      rigid=true,size=tail.size}
  end
  for _, it in ipairs(items) do
    if it.kind == 3 and it.gn then it.w = it.gw + it.kw; it.glyphs = true else it.gn = it.gn or 0 end
  end
  if lead and items[1] and items[1].first ~= lead then items[1].first = lead end
  return items, indent, strut_h, strut_d
end


local function kern_on(it)
  if not M.kern_attr or not it.core then return true end
  local v = node.get_attribute(it.core, M.kern_attr)
  return v == nil or v ~= 0
end



local va_attr = luatexbase.attributes["docxlike@va@attr"]
local vaja_attr = luatexbase.attributes["docxlike@vaja@attr"]
local function raised(it)
  if not it then return false end
  local g = (it.glist and it.glist[1]) or it.core
  if not g or g.id ~= GLYPH then return false end
  local a = va_attr and node.get_attribute(g, va_attr)
  local j = vaja_attr and node.get_attribute(g, vaja_attr)
  return (a ~= nil and a ~= 0) or (j ~= nil and j ~= 0)
end
local function auto_ok(P, c)
  if c and c >= 48 and c <= 57 then return P.autospace_dn end
  return P.autospace_de
end
local function auto_at(P, size, after_cjk, font, run_spacing)
  if not P.autospace then return 0 end
  local delta=run_spacing or 0
  if run_spacing==nil and font then
    local R=docxlike.run
    delta=R and R.wadd and R.wadd[font] or 0
  end
  
  
  if P.nogrid and not P.balance then
    size=size+(P.spacing or 0)
    if after_cjk then return size / 4 end
    local avg = font and docxlike and docxlike.metrics and docxlike.metrics.avg_width
      and docxlike.metrics.avg_width(font)
    if not avg then return size / 5 end
    local px = .12 * 65781.76
    return math.floor(avg * size / px + 0.5) * px / 2
  end
  if P.grid and not P.balance then
    local extra=(P.char_grid_extra or 0)/5
    return devround(size/4+(after_cjk and extra or 0))
  end
  local ex = P.excess
  if P.nogrid and P.balance then
    
    
    return (size+ex+delta)/4
  end
  if P.compat == 15 then
    local gap=size / 4 + math.min(math.max(ex / 5, (ex - 0.26 * P.bp) * 0.46), 0.2 * P.bp)
    return P.grid and devround(gap) or gap
  end
  local gap=size / 4 + ex / 5
  return P.grid and devround(gap) or gap
end



local function natural(items, P)
  local n = #items
  local text_font,mixed_fonts,latin_text=nil,false,true
  for _,it in ipairs(items) do
    if it.kind==3 and it.glyphs and it.font then
      if not device_latin_run(it) then latin_text=false end
      if text_font and text_font~=it.font then mixed_fonts=true end
      text_font=it.font
    end
  end
  local printer_spaces=latin_text and P.compat==15 and (P.justify and not P.balance or mixed_fonts)
  local function wide(t)
    return t.kind == 0 or t.symbol or t.frame
      or ((P.compat ~= 15 or is_wide(t.c)) and (t.kind == 1 or t.kind == 2))
  end
  local function wide_next(t) return wide(t) or t.kind == 1 or t.kind == 2 end
  local function symbol_width(it)
    local latin1 = it.c and it.c >= 0xA1 and it.c <= 0xFF
    if it.w < it.size * 0.9 or (P.compat == 15 and latin1) then return it.w + P.latin_add end
    return it.w + P.excess
  end
  for k = 1, n do
    local it, prev, nx = items[k], items[k - 1], items[k + 1]
    
    
    
    local run_extra=P.balance and not it.symbol and (it.run_spacing or 0) or 0
    local gap = 0
    
    local paired = false
    if P.cjk_compress ~= false and (it.kind == 1 or it.kind == 2) and not it.symbol and nx and kern_on(it) and not never_compressed[it.c] then
      local ok = (it.kind == 1 and (nx.kind == 1 or nx.kind == 2)) or (it.kind == 2 and nx.kind == 2)
      paired = ok and not never_compressed[nx.c] and not nx.symbol
    end
    
    it.open_pair_next = it.kind==2 and paired or false
    if it.kind==2 then paired=prev and prev.kind==2 and prev.open_pair_next or false end
    it.paired = paired
    if it.kind == 0 then
      it.nw = it.symbol and symbol_width(it) or (it.w + P.excess + run_extra + (it.fb or 0))
      it.spot = false
    elseif it.kind == 1 and it.symbol then
      
      it.full = symbol_width(it); it.nw = it.full
      it.spot = (it.c == 0xB7)
    elseif it.kind == 1 then
      it.full = it.w + P.excess + run_extra + (it.fb or 0)
      it.nw = paired and it.full / 2 or it.full
      it.spot = P.cjk_compress ~= false and (not paired) and not never_compressed[it.c]
    elseif it.kind == 2 then
      it.full = it.w + P.excess + run_extra + (it.fb or 0)
      it.nw = paired and it.full / 2 or it.full
      it.spot = P.cjk_compress ~= false and (not paired) and not (prev and (prev.kind == 1 or prev.kind == 2) and not prev.paired and not prev.symbol)
    elseif it.kind == 3 then
      it.terminal_grid_drop = nil
      if it.rigid then it.nw = it.w
      elseif latinish[it.c] and it.w >= it.size * 0.9 then it.nw = it.w + P.excess
      else
        local add = (it.code and 0 or P.latin_add)
        it.nw = it.w + (add + (it.fb or 0)) * it.gn
        if it.hangul then
          for _, g in ipairs(it.glist) do
            if is_hangul(g.char) and is_jfont(g.font) then it.nw = it.nw + P.excess - add end
          end
        end
      end
      if it.native_disc then
        local function added(list)
          local width=0
          for g in traverse(list) do
            if g.id==GLYPH then width=width+P.latin_add+(fake_bold(g) or 0) end
          end
          return width
        end
        it.hyphen_delta=it.native_delta+added(it.native_disc.pre)-added(it.native_disc.replace)
        it.native_post_width=(it.native_disc.post and node.dimensions(it.native_disc.post) or 0)
          +added(it.native_disc.post)
      end
      if prev and prev.kind == 0 and not prev.symbol and is_alnum(it.head) and auto_ok(P, it.head)
        and not raised(prev) and not raised(it) then gap = auto_at(P, prev.size, true, nil, prev.run_spacing) end
      
      if P.grid and not P.balance and it.glyphs and nx and nx.kind==0 and not nx.symbol
        and is_alnum(it.tail) and auto_ok(P,it.tail) and not raised(it) and not raised(nx) then
        it.terminal_grid_drop=P.grid_extra or 0
        it.nw=it.nw-it.terminal_grid_drop
      end
      it.spot = false
    else
      if it.user or it.boundary then
        it.nw = it.w
        if it.boundary then it.rigid = true end
      else
        
        local double = (prev and prev.kind == 4 and not prev.user) or (nx and nx.kind == 4 and not nx.user)
        local ctx = it.sbcs or (double and P.balance)
        if not ctx and P.balance then
          local i = k - 1
          while i >= 1 and items[i].kind == 4 and not items[i].user do i = i - 1 end
          if i >= 1 and wide(items[i]) then ctx = true end
        end
        if not ctx and P.balance then
          local i = k + 1
          while i <= n and items[i].kind == 4 and not items[i].user do i = i + 1 end
          if i <= n and wide_next(items[i]) then ctx = true end
        end
        local sk = 0
        if it.sfont and kern_on(it) then
          if prev and prev.kind == 3 and prev.glyphs and prev.tailfont == it.sfont then
            local kern=pair_kern(it.sfont, prev.tail, 32)
            local font_boundary=nx and nx.kind==3 and nx.font~=it.sfont
            if P.compat~=15 and not P.justify and (P.nogrid and font_boundary or ctx) then
              kern=devtrunc(kern/10)*10
            end
            sk = sk + kern
          end
          it.leading_kern=0
          if nx and nx.kind == 3 and nx.glyphs and nx.font == it.sfont
            and not (P.grid and ctx and not it.sbcs) then
            it.leading_kern=pair_kern(it.sfont,32,nx.head)
            if P.compat~=15 and P.nogrid and not P.justify and prev and prev.kind==3
              and prev.tailfont~=it.sfont then it.leading_kern=devtrunc(it.leading_kern/10)*10 end
            sk = sk + it.leading_kern
          end
        end
        if ctx then
          
          
          local half = P.half_space and P.half_space + (it.size - P.em) / 2
            or (it.size + P.excess) / 2
          local R=docxlike.run
          local tracking=it.sfont and R and R.wadd and R.wadd[it.sfont] or 0
          half=half+1.5*tracking
          it.nw = (it.sbcs and it.w or half) + sk; it.rigid = true
        else
          local width=it.w
          if printer_spaces and it.sfont then
            local f=font.getfont(it.sfont)
            if f and f.format=='truetype' and f.size and f.size>0 then
              local pixel=.12*P.bp
              width=width*math.floor((f.size+1)/pixel+.5)*pixel/f.size
            end
          end
          it.nw = width + P.space_add + sk; it.rigid = false
        end
      end
      it.spot = false
    end
    if prev and prev.kind == 3 and it.kind == 0 and not it.symbol and is_alnum(prev.tail) and auto_ok(P, prev.tail)
      and not raised(prev) and not raised(it) then
      gap = auto_at(P, prev.size, false, prev.font)
    end
    it.gap = gap
  end
end


local function split_run(items, k, g, P)
  local it = items[k]
  local a = {}
  for key, v in pairs(it) do a[key] = v end
  local b = {}
  for key, v in pairs(it) do b[key] = v end
  local ga, gb = {}, {}
  for i, n in ipairs(it.glist) do if i <= g then ga[#ga + 1] = n else gb[#gb + 1] = n end end
  a.glist, b.glist = ga, gb
  
  
  if not it.gindex then
    it.gindex, it.gstart = {}, 0
    for i, n in ipairs(it.glist) do it.gindex[n] = i end
  end
  a.gindex, a.gstart = it.gindex, it.gstart
  b.gindex, b.gstart = it.gindex, it.gstart + g
  local function in_first(n)
    local f = n.next
    while f and f.id ~= GLYPH do f = f.next end
    local i = f and it.gindex[f]
    return i ~= nil and i - it.gstart <= g
  end
  a.hyphen_disc, a.hyphen_delta = nil, nil
  a.native_disc, a.native_post_width, a.native_delta, a.native_discs = nil, nil, nil, nil
  a.last = ga[#ga]; a.core = a.last; a.gn = #ga
  b.first = gb[1]; b.core = gb[#gb]; b.gn = #gb
  local function sumw(list) local w = 0; for _, n in ipairs(list) do w = w + n.width end; return w end
  a.gw, b.gw = sumw(ga), sumw(gb)
  a.tail = a.last.char; a.tail_w = a.last.width; a.tail_hang = ascii_close[a.tail] and a.tail_w or 0
  b.head = b.first.char; b.head_w = b.first.width; b.c = b.head
  b.second_w = (#gb >= 2) and gb[2].width or 0
  a.second_w = (#ga >= 2) and ga[2].width or 0
  local ka, kb = {}, {}
  for _, e in ipairs(it.kerns or {}) do
    if in_first(e[1]) then ka[#ka + 1] = e else kb[#kb + 1] = e end
  end
  a.kerns, b.kerns = ka, kb
  a.kw, b.kw = 0, 0
  for _, e in ipairs(ka) do a.kw = a.kw + e[2] end
  for _, e in ipairs(kb) do b.kw = b.kw + e[2] end
  local da, db = {}, {}
  for _, d in ipairs(it.discs or {}) do
    if in_first(d) then da[#da + 1] = d else db[#db + 1] = d end
  end
  a.discs, b.discs = da, db
  a.w, b.w = a.gw + a.kw, b.gw + b.kw
  local ladd = (it.code and 0 or P.latin_add) + (it.fb or 0)
  local logical_grid_add=P.grid and not P.balance and not it.code
    and (P.char_grid_extra or 0)-(P.grid_extra or 0) or 0
  a.logical_grid_add,b.logical_grid_add=logical_grid_add,logical_grid_add
  ladd=ladd+logical_grid_add
  a.nw, b.nw = a.w + ladd * a.gn, b.w + ladd * b.gn
  a.terminal_grid_drop = nil
  if b.terminal_grid_drop then b.nw=b.nw-b.terminal_grid_drop end
  b.gap = 0
  a.emergency = true
  items[k] = a
  table.insert(items, k + 1, b)
end

local soft_sep = set_of("/.-")
local assignment_operator = set_of("=!<>:+-*/%&|^")
local function soft_split(items, P)
  local k, quote, escaped = 1, nil, false
  while k <= #items do
    local it = items[k]
    local marked = it.code or (M.code_attr and (node.get_attribute(it.core or it.first, M.code_attr) or 0) > 0)
    if not marked then quote, escaped = nil, false end
    if it.kind == 3 and it.glyphs and it.gn >= 1 and #it.glist == it.gn then
      local n = it.gn
      local cuts = {}
      for i = 1, n do
        local c = it.glist[i].char
        local pc = i > 1 and it.glist[i - 1].char
        local ppc = i > 2 and it.glist[i - 2].char
        local cost, kind
        local previous_cluster = i > 1 and M.cluster_attr and node.get_attribute(it.glist[i-1],M.cluster_attr)
        local next_cluster = M.cluster_attr and node.get_attribute(it.glist[i],M.cluster_attr)
        M.wordwrap_attr = M.wordwrap_attr or luatexbase.attributes["docxlike@wordwrap@attr"]
        
        local anywhere = i > 1 and P.compat ~= 15 and M.wordwrap_attr and node.get_attribute(it.glist[i], M.wordwrap_attr) == 1
          and c > 32 and pc > 32 and c < 0x2E80 and pc < 0x2E80
        if pc == 0x200B then cost, kind = 0, "explicit"
        elseif anywhere then cost, kind = 0, "word-wrap"
        elseif it.code and P.compat == 15 and pc == 45 and c ~= 45 then
          cost, kind = 20, "native-hyphen"
        end
        if it.code and P.code_overhang and i > 1 and not quote and kind ~= "explicit" then
          if pc == 44 then cost, kind = 0, "comma"
          elseif pc == 61 and c ~= 61 and c ~= 62 and not assignment_operator[ppc] then
            cost, kind = 10, "assignment"
          elseif n > 16 and i >= 5 and i <= n - 4 then
            if pc == 45 and c ~= 45 and ppc ~= 45 then
              cost, kind = 20, kind or "hyphen"
            elseif soft_sep[c] and not soft_sep[pc] and pc ~= 58
                and not (c == 46 and n - i <= 5) then
              cost, kind = 30, "path"
            end
          end
        end
        if cost then
          local g = it.glist[i - 1].next
          while g and g ~= it.glist[i] do
            if g.id == PENALTY and g.penalty >= 10000 then cost = nil; break end
            g = g.next
          end
        end
        if cost and i > 1 and not (previous_cluster and previous_cluster == next_cluster) then
          cuts[#cuts + 1] = { offset = i - 1, cost = cost, kind = kind }
        end
        if marked then
          if escaped then escaped = false
          elseif quote and c == 92 then escaped = true
          elseif quote then if c == quote then quote = nil end
          elseif c == 34 or c == 39 then quote = c end
        end
      end
      local base = 0
      for _, cut in ipairs(cuts) do
        split_run(items, k, cut.offset - base, P)
        items[k].emergency = nil
        items[k].soft = true
        items[k].break_cost = cut.cost
        items[k].break_kind = cut.kind
        base = cut.offset
        k = k + 1
      end
    end
    k = k + 1
  end
end


local function width_of(items, first, last)
  local w = 0
  for k = first, last do
    local it = items[k]
    local skipit = it.kind == 4 and not it.user and ((k == first and first > 1) or k == last)
    if not skipit then
      w = w + ((it.paired and k == last) and it.full or it.nw)
      if k > first then w = w + it.gap end
    end
  end
  return w
end

local function balanced_latin_line(items,first,last,P)
  if P.compat~=15 or not P.balance then return false end
  for k=first,last do
    local it=items[k]
    if it.kind<=2 or it.rigid or it.kind==3 and it.glyphs and not device_latin_run(it) then return false end
  end
  return true
end

local function decide(items, P, shape, indent)
  natural(items, P)
  local n = #items
  local p = P.cell
  local half = p / 2
  local compat = P.compat
  local eps = P.eps
  local bp = P.bp
  
  local tight_eps = 0.002 * bp
  local ex = P.excess
  local auto = auto_at(P, p - ex)
  local scale = auto / (3.09 * bp)
  local justify = P.justify or compat ~= 15
  local measure = 0

  local function text_start(first)
    local k = first
    while k + 1 <= n and items[k].kind == 4 do k = k + 1 end
    return k
  end
  
  local function spots(first, last)
    local start = text_start(first)
    local c = 0
    for k = first, last - 1 do
      local it = items[k]
      if it.spot and not (it.kind == 2 and k == start) then c = c + 1 end
    end
    return c
  end
  local function autos_in(first, upto)
    local c = 0
    for k = first + 1, upto do if items[k].gap > 0 then c = c + 1 end end
    return c
  end
  
  local function penalty(k, gaps)
    if gaps <= 0 or k == 0 then return 0 end
    local base = 1.35 * bp * (math.log(1 + gaps) / math.log(3))
    local factor = (k == 1) and 0.5 or (math.max(1.5 - 0.07 * k, 0.6) / 1.36)
    return base * factor
  end
  
  local function auto_cap(gaps, adjacent)
    if gaps == 0 and adjacent then return 0.5 * bp
    elseif gaps == 0 then return 0
    elseif adjacent then return auto
    else return math.min(auto / 2 + (gaps - 1) * bp, auto) end
  end
  local function run_before(first, j)
    if j <= first or j < 2 then return nil end
    local pk = items[j - 1].kind
    if pk ~= 3 and pk ~= 4 then return nil end
    local b = j - 1
    while b > first and (items[b - 1].kind == 3 or items[b - 1].kind == 4) do b = b - 1 end
    return b
  end
  local function has_cjk(first, m)
    for i = first, m do if items[i].kind == 0 then return true end end
    return false
  end
  local function unrelated_auto_credit(first,j,core,latin)
    if not P.nogrid then return 0 end
    
    local related = run_before(first,j)
    local boundary=first
    for i=core-1,first,-1 do
      if items[i].kind==1 or items[i].kind==2 then boundary=i; break end
    end
    local count, width, stack, groups, group_count = 0, 0, {}, {}, 0
    for i=1,core do
      local it=items[i]
      if closing_for[it.c] then stack[#stack+1]=closing_for[it.c]
      elseif #stack>0 and it.c==stack[#stack] then stack[#stack]=nil end
      if i>first and i~=core and i~=related and it.gap>0 and #stack==0 then
        local owner=run_before(first,i) or i
        if not groups[owner] then groups[owner]=true; group_count=group_count+1 end
        if i<=boundary then count=count+1; width=width+it.gap end
      end
    end
    if latin then
      local spaces=0
      if related then
        for i=related+1,core-1 do
          if items[i].kind==4 and not items[i].user and not items[i].rigid then spaces=spaces+1 end
        end
      end
      return width/(math.max(1,spaces)*math.max(1,group_count))
    end
    return math.min(width/2,auto_cap(count,false))/math.max(1,group_count)
  end
  
  
  local function unit_width(first, j, m)
    local u = items[j].gap
    for k = j, m do
      local it = items[k]
      u = u + ((it.paired and k == m) and it.full or it.nw)
      if k > j then u = u + it.gap end
    end
    local tj = items[j]
    local b = j
    while b > first + 1 and items[b - 1].kind == 4 do
      b = b - 1
      u = u + items[b].nw
    end
    if tj.kind == 3 and tj.glyphs and tj.gap > 0 and m == j and (tj.tail_hang or 0) == 0 then u = u + 0.4 * bp end
    return u
  end
  
  local function space_give(k)
    local t = items[k]
    if t.kind ~= 4 or t.user or t.rigid then return 0 end
    local in_run = (k > 1 and items[k - 1].kind == 4) or (k < n and items[k + 1].kind == 4)
    if in_run then return 0 end
    local after_punct = k > 1 and (items[k - 1].kind == 1 or items[k - 1].kind == 2) and not items[k - 1].symbol
    if after_punct then return t.nw end
    return t.nw * 0.25
  end
  local function slop(k, first_line)
    if not first_line then return 0 end
    if k == 1 then return 0.45 * bp end
    return 0.65 * bp
  end
  local POOL_C = { [0] = 0, 1.55, 2.75, 3.15, 3.45, 3.55, 3.75, 3.75, 3.75 }
  local POOL_L = { [0] = 0, 1.6, 3.0, 3.2, 3.3, 3.3, 3.3, 3.4, 3.4 }
  local function pool(g, latin)
    local t = latin and POOL_L or POOL_C
    local reference=P.nogrid and P.balance and 3 or 3.09
    return t[math.min(g, 8)] * bp * auto/(reference*bp)
  end
  local G_TAB = { [0] = 0, 0.29, 0.54, 0.73, 0.9, 1.1, 1.29, 1.4, 1.5 }
  local NOGRID_GAP_TAB = { [0] = 0, 0.296, 0.52, 0.703, 0.835, 0.99, 1.06, 1.12, 1.18 }
  
  
  local REMOTE15 = { [0] = 0, 1.2, 2.716, 3.02, 3.32, 3.42, 3.524, 3.61, 3.69 }
  local REMOTE15_BAL = { [0] = 0, 1.5, 2.816, 3.12, 3.42, 3.52, 3.624, 3.66, 3.69 }

  
  local function budget15(first, j0, j, core, m, isfirst)
    local openers_n = 0
    local opener_spots = 0
    if items[j].kind == 2 and j > text_start(first) then
      for i = j, core - 1 do
        if items[i].kind == 2 then
          openers_n = openers_n + 1
          if items[i].spot then opener_spots = opener_spots + 1 end
        end
      end
    end
    local tc = items[core]
    local latin = tc.kind == 3
    local ascii_tail = 0
    if m > core and items[m].kind == 3 then ascii_tail = items[m].tail_hang or 0
    elseif m == core and latin then ascii_tail = tc.tail_hang or 0 end
    local paired_bracket = m == core and latin and ascii_bracket_close[tc.tail] and ascii_open[tc.head]
    local closers_n = (m > core and items[m].kind == 3) and 0 or (m - core)
    local k = spots(first, j) + opener_spots
    for i = core + 1, m - 1 do if items[i].spot then k = k + 1 end end
    local adjacent = (not latin) and tc.gap > 0 and core == j
    local n_all = autos_in(first, core)
    local gaps = n_all
    if tc.gap > 0 and core == j then
      gaps = gaps - 1
      if not latin then
        local b = run_before(first, j)
        if b and items[b].gap > 0 and k > 0 then gaps = gaps - 1 / k end
      end
    end
    local u = unit_width(first, j0, m)
    if P.nogrid and openers_n>1 then u=math.max(u-half,0) end
    if P.nogrid and openers_n > 0 and j > first
        and items[j-1].kind == 1 and items[j-1].paired then
      u = math.max(u - half * openers_n, 0)
    end
    local bare = closers_n == 0 and openers_n == 0 and m == core
    local cjk_char = (not latin) and bare and not adjacent
    local glued_latin = latin and bare and j == j0 and tc.gap > 0 and ascii_tail == 0 and k >= 1

    
    
    
    if cjk_char then
      if k == 0 then return pool(n_all, false) end
      local uc = tc.nw
      local own_spaces = 0
      local b = j
      while b > first + 1 and items[b - 1].kind == 4 and items[b - 1].rigid do b = b - 1; own_spaces = own_spaces + items[b].nw end
      local ts = text_start(first)
      local g = math.max(j - ts - 1, 0)
      local pure = true
      for q = ts, j - 1 do
        if items[q].kind == 3 or items[q].kind == 4 then pure = false; break end
      end
      local a
      local rigid_space = false
      for q = ts, j - 1 do
        if items[q].kind == 4 and items[q].rigid then rigid_space = true; break end
      end
      
      local has_space = false
      for q = ts, j - 1 do
        if items[q].kind == 4 then has_space = true; break end
      end
      local local_gap = false
      for q = j - 1, ts, -1 do
        if items[q].spot then break end
        if items[q].gap and items[q].gap > 0 then local_gap = true; break end
      end
      if P.nogrid and not pure and not has_space and n_all > 0 and not local_gap then
        local cjk = 0
        for q = ts, j - 1 do
          if items[q].kind ~= 3 then cjk = cjk + 1 end
        end
        local an = math.max(cjk - 1, 0) / 32 + n_all / 32
        local gam = NOGRID_GAP_TAB[math.min(n_all, 8)] * ((k == 1) and 0.4 or (k + 3) / 5)
        local t = math.min(uc * k / (k + an + gam), half * k)
        trace("  b15 cjk-char-latin j=%d k=%d n_all=%d cjk=%d a=%.3f gamma=%.3f t=%.2f", j, k, n_all, cjk, an, gam, t / bp)
        return t
      end
      if pure then a = g / 32
      elseif P.nogrid and n_all == 0 and not rigid_space then a = math.max(0, width_of(items, ts, m) / (32 * p))
      else a = math.max(0, math.min(width_of(items, ts, m) / measure, 1.5)) end
      local gamma = G_TAB[math.min(n_all, 8)] * ((k == 1) and 0.4 or (k + 3) / 5)
      local denom = k + a + gamma
      local base = ((uc + own_spaces) * k + unrelated_auto_credit(first,j,core)) / denom
      local blocks = 0
      if k >= 2 then
        local i = first + 1
        local function space(q) return items[q].kind == 4 and items[q].rigid and not items[q].user end
        while i < b do
          if items[i].kind == 3 and items[i].glyphs then
            local e = i
            local alnum = false
            while e < b and items[e].kind == 3 and items[e].glyphs do
              if is_alnum(items[e].head) or is_alnum(items[e].tail) then alnum = true end
              e = e + 1
            end
            if alnum and i > first + 1 and space(i - 1) and e < b and space(e) then blocks = blocks + 1 end
            i = e
          else
            i = i + 1
          end
        end
      end
      local bonus = 0.2 * bp * blocks * scale
      local t = math.min(base, half * k) + bonus
      trace("  b15 cjk-char j=%d core=%d m=%d k=%d n_all=%d u=%.2f g=%d pure=%s a=%.3f t=%.2f", j, core, m, k, n_all, uc / bp, g, tostring(pure), a, t / bp)
      return t
    end

    
    if glued_latin then
      local g_other = math.max(n_all - 1, 0)
      local c = half * k + auto / 2 * n_all
      local wm = math.max(0, math.min(width_of(items, text_start(first), m) / measure, 1.5))
      local t = ((u * 1.031 - 2.85 * bp) * k / (k + wm) + 1.7 * bp * scale) * (1 - 0.136 * math.log(1 + g_other))
      t=t+unrelated_auto_credit(first,j,core,true)/(k+wm)
      trace("  b15 glued-latin j=%d core=%d m=%d k=%d n_all=%d u=%.2f c=%.2f t=%.2f", j, core, m, k, n_all, u / bp, c / bp, t / bp)
      return math.min(c, t)
    end

    if P.nogrid and bare and latin and k > 0 and j > first
        and items[j-1].kind == 4 and not items[j-1].rigid and has_cjk(first,j-1) then
      local a = math.max(0, math.min(width_of(items, text_start(first), m) / measure, 1.5))
      local gamma = G_TAB[math.min(n_all, 8)] * ((k == 1) and 0.4 or (k + 3) / 5)
      local cap = half * k + auto / 2 * n_all
      for i = first + 1, m - 1 do cap = cap + space_give(i) end
      return math.min((u * k + unrelated_auto_credit(first,j,core,true)) / (k + a + gamma), cap)
    end

    
    local pen
    if latin and k >= 2 then
      pen = math.min(0.85 * bp * math.max(gaps, 0) * ((closers_n > 0) and 2 or 1), u * k / (k + 1) * 0.25)
    elseif latin and k == 1 then
      pen = penalty(k, gaps) * 2
    else
      pen = penalty(k, gaps)
    end
    if closers_n > 0 and k == 1 then
      local g = math.max(gaps, 0)
      if closers_n == 1 and not latin then pen = bp * (g * math.max(1.12 - 0.047 * g, 0.7))
      else pen = 0.5 * bp * g end
    elseif closers_n > 0 and not (latin and k >= 2) then
      pen = pen * 2
    end
    local ex2 = P.latin_add
    local hang_cap
    if P.table_cell then
      hang_cap = (closers_n > 0) and items[m].full / 2 or 0
    elseif closers_n > 0 then
      hang_cap = items[m].full
    elseif ascii_tail > 0 then
      hang_cap = ascii_tail + ex2
    else
      hang_cap = 0
    end
    local hang = paired_bracket and 0 or hang_cap
    local auto_part
    if latin then
      local rb = run_before(first, j)
      local own = (tc.gap > 0 or (rb and items[rb].gap > 0)) and auto / 2 or 0
      local part
      if k == 0 then part = own + pool(math.max(n_all - ((own > 0) and 1 or 0), 0), true)
      else part = math.min(auto / 2 * n_all, auto * 2.5) end
      if tc.gap == 0 and k == 0 then auto_part = math.min(part, u * 0.17) else auto_part = part end
    else
      auto_part = auto_cap(n_all - (adjacent and 1 or 0), adjacent)
    end
    local cap = half * k + hang_cap + auto_part
    if k == 0 and closers_n == 1 and not latin then
      local CREDIT = { [0] = 0, 1.55, 2.17, 0.93, 0.43, 0.05 }
      local credit = (n_all <= 5) and CREDIT[n_all] or -0.33
      if adjacent then credit = credit + 0.9 end
      return hang_cap + credit * bp
    end
    if k == 0 then
      return cap - (latin and 0 or pen)
    end
    if latin then
      for i = first + 1, m - 1 do cap = cap + space_give(i) end
    end
    local forgiven = 0
    if closers_n == 0 and (k >= 2 or adjacent or latin) then
      local s = slop(k, isfirst)
      forgiven = (gaps > 0) and math.min(s, 0.5 * bp) or s
    end
    local quota = 1
    if P.nogrid and not latin and closers_n == 1 and openers_n == 0 and n_all == 0 and k > 0 then
      local preceding = width_of(items,text_start(first),j-1)
      quota = math.max(0,(preceding / p - 1) / 32)
    end
    local t_f = (u * k + hang + forgiven) / (k + quota)
    local deficit = 0
    if closers_n == 1 then
      local sym = false
      if latin and k == 1 then
        for i = math.max(j0 - 1, first + 1), core do if items[i].symbol then sym = true end end
      end
      if sym then deficit = 0.9 * bp
      elseif k <= 1 then deficit = 0
      elseif k == 2 then deficit = 0.5 * bp
      elseif k == 3 then deficit = 0.75 * bp
      else deficit = 0.8 * bp end
    elseif closers_n >= 2 then
      deficit = 0.25 * bp * math.max(k - 2, 0)
    end
    local budget
    if P.nogrid and tc.kind == 0 and not tc.symbol and closers_n > 0 and openers_n == 0 and k > 0 then
      local related = tc.gap > 0 and 1 or 0
      local rb = run_before(first,j)
      if rb and items[rb].gap > 0 then related = related + 1 end
      if n_all > related then
        local ts = text_start(first)
        local a = math.max(0,math.min(width_of(items,ts,m)/measure,1.5))
        local gamma = G_TAB[math.min(n_all,8)] * ((k == 1) and 0.4 or (k+3)/5)
        return math.min((u*k+hang)/(k+a+gamma),cap)
      end
    end
    if latin then budget = math.min(t_f - deficit - pen, cap)
    else budget = math.min(t_f - deficit, cap) - pen end
    local g = n_all
    local fine = 0
    if bare and latin then
      fine = (-0.24 * math.max(k - 3, 0) - 0.018 * g * ((k >= 3) and 1 or 0)) * bp
    elseif bare and k >= 3 then
      fine = (-0.047 * g - 0.007 * g * k) * bp
    end
    trace("  b15 j0=%d j=%d core=%d m=%d k=%d gaps=%.2f n_all=%d pen=%.2f auto_part=%.2f cap=%.2f u=%.2f hang=%.2f t_f=%.2f deficit=%.2f",
      j0, j, core, m, k, gaps, n_all, pen / bp, auto_part / bp, cap / bp, u / bp, hang / bp, t_f / bp, deficit / bp)
    return budget + fine
  end

  
  local function budget_old(first, j, core, m)
    local k = spots(first, j)
    local tc = items[core]
    if m == core and j == core and tc.kind == 1 and tc.symbol then
      if compat == 12 or compat == 14 then return p + P.latin_add end
      return half
    end
    local opener = items[j].kind == 2 and core > j
    local latin = tc.kind == 3
    local gaps = autos_in(first, core)
    local after_latin_space,after_latin_closers=false,false
    if j>first and items[j-1].kind==4 and not items[j-1].user and j>=3 then
      local b=j-2
      if P.nogrid then
        while b>first and items[b].kind==1 do b=b-1; after_latin_closers=true end
      end
      after_latin_space=items[b].kind==3 and items[b].glyphs
    end
    local own
    if opener and latin and m == core and P.ari then
      local u_core = 0
      for i = j + 1, m do u_core = u_core + items[i].nw end
      local phys = half * (k + 1) + auto / 2 * gaps
      own = math.min(phys, u_core + half + 0.3 * bp)
    elseif opener then
      
      own = half + half * math.min(k, latin and 3 or 2)
      if P.nogrid and not latin then
        for q=j+1,core-1 do
          if items[q].kind==2 and items[q].paired then own=own+items[q].nw end
        end
      end
    elseif latin then
      if P.nogrid and tc.gn==1 and legacy_dashes[tc.c] then return 0 end
      local b = j
      while b > first + 1
        and (items[b - 1].kind == 4
             or (P.ari and ((items[b - 1].kind == 3 and items[b - 1].glyphs
                              and not (P.nogrid and items[b-1].gn==1 and legacy_dashes[items[b-1].c]))
                            or (items[b - 1].symbol and items[b - 1].nw < half * 1.5)))) do
        b = b - 1
      end
      local u = 0
      for i = b, m do u = u + items[i].nw end
      if P.ari then
        local u2 = 0
        for i = b, core do u2 = u2 + items[i].nw end
        local cjk_line = has_cjk(first, m)
        local inner_space = nil
        for i = b + 1, core - 1 do if items[i].kind == 4 then inner_space = i; break end end
        local spaces = 0
        for i = first + 1, m do
          local t = items[i]
          
          
          local between_letters = items[i - 1] and items[i + 1] and items[i - 1].kind == 3 and items[i + 1].kind == 3
            and is_latin_letter(items[i - 1].tail) and is_latin_letter(items[i + 1].head)
          if i < b and cjk_line and t.kind == 4 and not t.user and t.nw < half - 0.1 * bp and not between_letters then
            spaces = spaces + 1
          end
        end
        if P.nogrid and items[b].kind==3 and items[b].gn==1 and ascii_close[items[b].head] then spaces=0 end
        local phys = half * k + auto / 2 * (gaps + spaces)
        local glyphs = 0
        for i = b, core do glyphs = glyphs + (items[i].gn or 0) end
        local cap
        if m == core and tc.gn == 1 and tc.c == 62 then
          if compat ~= 11 then return half + tc.w end
          cap = half * 2
        elseif inner_space then
          local s = 0
          for i = b, inner_space - 1 do s = s + items[i].nw end
          cap = u2 - s
        elseif glyphs <= 1 then
          cap = u2 - 0.3 * bp
        elseif items[b].kind == 3 then
          cap = u2 - (items[b].head_w or 0) - P.latin_add
        elseif P.nogrid and items[b].kind==4 and not items[b].user then
          cap = u2
        else
          cap = u2 - items[b].nw
        end
        trace("  lat b=%d core=%d m=%d k=%d phys=%.2f cap=%.2f u=%.2f", b, core, m, k, phys / bp, cap / bp, u2 / bp)
        if m == core then
          local ascii = (compat == 11 and tc.tail == 37) and 0 or (tc.tail_hang or 0)
          return math.min(phys + ascii, cap)
        end
        local closes = P.nogrid and (width_of(items,first,m)-width_of(items,first,core)) or 0
        return math.min(phys, cap+closes)
      else
        local cap
        if m == core and tc.gn == 1 and tc.c == 62 then cap = half * 2 else cap = u / 2 end
        own = math.min(half * k + auto / 2 * gaps, cap)
        if m == core then
          local ascii = (tc.tail_hang or 0)
          if compat == 11 then ascii = math.min(ascii, 3 * bp) end
          return own + ascii + ((ascii > 0) and P.latin_add or 0)
        end
      end
    elseif k == 0 then
      
      own = math.min((auto / 2 + 0.05 * bp) * gaps, half)
    elseif after_latin_space then
      own = half * (after_latin_closers and math.min(k,3) or k)
    elseif P.ari and j > first and items[j - 1].kind == 3 and items[j - 1].glyphs then
      own = ((items[j - 1].tail_w or 0) + P.latin_add + tc.gap) / 2
    else
      local near = 0
      if tc.gap > 0 then
        near = 1
        local rb = run_before(first, j)
        if rb and items[rb].gap > 0 then near = 2 end
      end
      own = half - penalty(k, near)
    end
    if own == nil then own = 0 end
    if opener and j > 1 and items[j - 1].kind == 1 and items[j - 1].paired and m == core and P.ari then
      own = own - 3 * bp
    end
    if m == core then
      local ascii = (tc.kind == 3) and (tc.tail_hang or 0) or 0
      if compat == 11 then ascii = math.min(ascii, 3 * bp) end
      return own + ascii + ((ascii > 0) and P.latin_add or 0)
    end
    if items[m].kind == 3 and P.ari and compat == 11 then
      if P.nogrid and tc.kind==0 and m==core+1 and items[m].gn==1 and ascii_close[items[m].head] then
        return math.min(half*spots(first,m)+auto/2*gaps,own+items[m].nw)
      end
      return half * spots(first, m) + auto / 2 * gaps
    end
    local hang
    if P.table_cell then hang = half
    elseif never_compressed[items[m].c] then hang = (compat == 11) and 0 or p
    elseif items[m].symbol then hang = 0
    else hang = half end
    local k_all = spots(first, m)
    local gap_credit = auto / 2 * gaps
    local chain
    if compat == 11 then chain = hang + half * k_all + gap_credit
    else chain = half * k_all + math.max(p, hang) + gap_credit end
    if opener and latin and tc.gn == 1 and m == core + 1 and j > 1 and items[j - 1].kind == 1 and items[j - 1].paired then
      chain = math.min(chain, hang + half * math.min(k_all, 2) + ((k_all >= 3) and 2.9 * bp or 0))
    end
    local closers_w = width_of(items, first, m) - width_of(items, first, core)
    local budget = math.min(chain, own + closers_w)
    trace("  b11 j=%d core=%d m=%d k=%d k_all=%d gaps=%d own=%.2f hang=%.2f chain=%.2f closers_w=%.2f",
      j, core, m, k, k_all, gaps, own / bp, hang / bp, chain / bp, closers_w / bp)
    if j > first and items[j - 1].symbol and items[j - 1].nw < half * 1.5 and tc.symbol then
      return budget - 3 * bp
    end
    return budget
  end

  local function toc_budget(value,first,m)
    if not P.toc then return value end
    
    local cap=0
    for q=first,m do
      local it=items[q]
      if it.spot then cap=cap+(it.full or it.nw)/2 end
      if q>first then cap=cap+(it.gap or 0)/2 end
    end
    return math.min(value,cap)
  end
  local function unit_budget(first, j0, j, core, m, isfirst)
    if P.toc_legacy_tail and items[m].toc_tail then
      
      return math.max(0,items[m].nw-.12*bp)
    end
    
    if P.toc and (not P.justify or has_cjk(first,m)) then return 0 end
    if not justify or not P.compress then return 0 end
    if P.cjk_compress == false and has_cjk(first,m) then
      local gaps = 0
      if P.nogrid and compat == 15 and P.justify then
        if items[core].gap>0 then
          for q=first+1,core do gaps=gaps+(items[q].gap or 0)/2 end
        else
          
          local n_remote=autos_in(first,core)
          if n_remote<=1 then gaps=auto_cap(n_remote,false)
          else gaps=(P.balance and REMOTE15_BAL or REMOTE15)[math.min(n_remote,8)]*bp*p/(12*bp) end
          if P.balance then
            local available=0
            for q=first+1,core do available=available+(items[q].gap or 0)/2 end
            gaps=math.min(available,gaps)
          end
        end
      end
      if m > core and items[m].kind == 1 then
        
        local budget=P.nogrid and P.balance and compat==15 and math.max(gaps,items[m].full) or gaps+items[m].full
        return toc_budget(budget,first,m)
      end
      return toc_budget(gaps,first,m)
    end
    if compat ~= 15 and P.align == "left" and not P.justify
        and m == core and items[j].kind ~= 2
        and (items[core].tail_hang or 0) == 0 then
      
      return 0
    end
    if compat == 15 then return toc_budget(budget15(first, j0, j, core, m, isfirst),first,m) end
    return toc_budget(budget_old(first, j, core, m),first,m)
  end

  
  local function space_shrink(first, j0, j, core, m, k, base)
    if not P.justify or not P.compress then return 0 end
    
    
    
    local older = compat ~= 15 and P.nogrid and P.cjk_compress ~= false and P.cjk_compress_given
    if compat ~= 15 and not older then return 0 end
    
    if compat ~= 15 and P.balance and not has_cjk(first, m) then return 0 end
    
    
    
    if (P.nogrid or balanced_latin_line(items,first,m,P)) and k == 0 and m == core
        and items[j].kind == 3 and not has_cjk(first, m) then
      local n_sp, s_w = 0, 0
      for q = first + 1, j - 1 do
        local it = items[q]
        if it.kind == 4 and not it.user then n_sp = n_sp + 1; s_w = s_w + it.nw end
      end
      if n_sp > 0 then
        
        local hang = (items[m].kind == 3) and (items[m].tail_hang or 0) or 0
        if hang > 0 then hang = hang + P.latin_add end
        
        local u = (unit_width(first, j0, m) - hang) / (M.par_scale or 1)
        return math.min(0.25 * s_w, u * n_sp / (3 * n_sp - 2)) + math.min(hang, base) - base
      end
    end
    if compat ~= 15 and not older then return 0 end
    local start
    if items[j].kind == 3 then start = run_before(first, j) or j
    else start = run_before(first, j) or (m + 1) end
    local sp = {}
    for q = math.max(start, first + 1), m - 1 do
      if items[q].kind == 4 and not items[q].user then sp[#sp + 1] = q end
    end
    local far = 0
    for q = first + 1, math.max(start, first + 1) - 1 do
      if items[q].kind == 4 and not items[q].user and not items[q].rigid then far = far + 1 end
    end
    far = math.min(0.5 * bp * far, 1 * bp)
    
    if compat ~= 15 and k > 0 then return 0 end
    if #sp == 0 then
      if P.nogrid and k==0 then
        local remote=0
        for q=first+1,math.max(start,first+1)-1 do remote=remote+space_give(q) end
        
        return autos_in(first,core)>0 and math.min(remote,auto/2) or (compat == 15 and 0 or remote)
      end
      if P.nogrid and k>0 and m==core and items[core].kind==0 then
        local remote=0
        for q=first+1,math.max(start,first+1)-1 do
          local it=items[q]
          if it.kind==4 and not it.user and not it.rigid then remote=remote+1 end
        end
        return -.25*bp*math.max(remote-1,0)
      end
      return (k == 0) and far or 0
    end
    if k > 0 then
      if items[j].kind == 3 then return 0 end
      return -0.25 * bp * (#sp - 1)
    end
    local per = 0
    for _, q in ipairs(sp) do per = per + space_give(q) end
    
    per = math.min(per, 1.85 * items[sp[1]].nw)
    if m > core then return per end
    local cap
    if items[j].kind == 3 then
      if items[start].gap > 0 then
        local s = 0
        for i = j0, j do s = s + items[i].nw end
        cap = s / 3
      else
        cap = unit_width(first, j0, m) / 3 + 0.5 * bp
      end
    else
      cap = unit_width(first, j, m) / 3
    end
    local hang = 0
    if items[m].kind == 3 and m == core then
      hang = (items[m].tail_hang or 0)
      if hang > 0 then hang = hang + P.latin_add end
    end
    local b2 = base - math.min(hang, base)
    return math.min(b2 + per, math.max(cap, b2)) - b2 + far
  end

  
  
  
  local function breakpoint_after(k)
    if k >= n then return nil end
    local core = items[k].core
    if not core then return nil end
    
    
    
    if core.id == DISC then
      if native_controls() and (core.penalty or 0)>=10000 then return nil end
      local hy = false
      for r in traverse(core.replace) do if r.id == GLYPH and r.char == 45 then hy = true end end
      if hy and items[k].code and compat ~= 15 then return nil end
      return core.next
    end
    if core.id == GLYPH and core.char == 45 then
      if compat == 15 or not items[k].code then return core.next end
      return nil
    end
    
    if core.id == GLYPH and core.char == 0x2014 and items[k + 1].c == 0x2014 then
      return items[k + 1].first
    end
    local stop = items[k + 1].first
    
    local allow_backend_starter=P.nogrid and (items[k+1].c==0x30FC or items[k+1].word_loose_start)
    if allow_backend_starter then
      local probe=core.next
      while probe and probe~=stop do
        if probe.id==PENALTY and probe.penalty>=10000 and not is_kinsoku(probe) then
          allow_backend_starter=false; break
        end
        probe=probe.next
      end
    end
    local prev = core
    local g = core.next
    while g do
      local id = g.id
      if id == GLUE then
        local pid = prev.id
        if pid ~= GLUE and pid ~= KERN and pid ~= PENALTY and pid ~= MATH then return g end
      elseif id == PENALTY then
        if g.penalty < 10000 or (allow_backend_starter and is_kinsoku(g)) then return g end
      elseif id == KERN or id == MATH then
        if g.next and g.next.id == GLUE then return (id == KERN) and g or g.next end
      elseif id == DISC then
        if not native_controls() or (g.penalty or 0)<10000 then return g.next end
      end
      if g == stop then break end
      prev = g; g = g.next
    end
    return nil
  end
  
  local function mandatory_after(k)
    if k >= n then return false end
    if items[k].native_disc and (items[k].native_disc.penalty or 0)<=-10000 then return true end
    local g = items[k].core and items[k].core.next
    local stop = items[k + 1].first
    while g and g ~= stop do
      if g.id == PENALTY and g.penalty <= -10000 then return true end
      g = g.next
    end
    return false
  end
  
  local function legal_after(k)
    if k >= n then return true end
    if items[k].emergency or items[k].soft then return true end
    if breakpoint_after(k) == nil then return false end
    local a, b = items[k], items[k + 1]
    if b.kind == 1 then return false end
    if a.kind == 2 then return false end
    if b.kind == 3 and b.glyphs and no_line_start[b.head] then return false end
    
    if b.kind == 0 and b.c and no_line_start[b.c] then return false end
    if a.kind == 3 and a.glyphs and no_line_end[a.tail] then return false end
    return true
  end

  local function bad_end(k)
    local t = items[k]
    return (t.kind == 4 and not t.user) or t.kind == 2
      or (t.kind == 3 and t.glyphs and (ascii_open[t.tail] or no_line_end[t.tail]))
  end

  local function scan_line(i, li, collect)
    local candidates = collect and {} or nil
    local previous=i>1 and items[i-1]
    local post_disc=previous and previous.native_disc
    local post_width=post_disc and previous.native_post_width or 0
    local isfirst = li == 1
    local first_text = text_start(i)
    local token = items[first_text]
    local needed = token and token.kind == 3 and token.glyphs
      and width_of(items, i, first_text) + post_width + (isfirst and math.max(0, indent) or 0) or 0
    local sh = shape(li, needed)
    measure = sh.width
    
    local full = tex.hsize
    local cellcap = measure
    if P.grid and P.cell0 and P.cell0 > 0 then
      local cells = math.floor((full + eps) / P.cell0)
      cellcap = P.cell0 * cells - (full - measure)
    end
    local snaps = P.grid and compat ~= 15 and P.ari and not P.table_cell
    local capacity = snaps and cellcap or measure
    local code_limit = capacity
    if P.code_right and sh.shift + measure >= tex.hsize - eps then
      code_limit = math.max(0, P.code_right - sh.shift)
    end
    local first = i
    local last = i
    local j = i
    local deep = false
    local forced_end = false
    local have = false
    local first_unit = nil

    local function make_line(k, line_deep, line_end, line_forced)
      local w = width_of(items, first, k) + post_width + (isfirst and indent or 0)
      local hyphen = k < n and items[k].hyphen_disc
      if hyphen then w = w + items[k].hyphen_delta end
      local over = w - capacity
      local tail = k
      while tail > first and items[tail].kind == 4 do tail = tail - 1 end
      local extended = P.code_overhang and items[tail].code and over > eps or false
      return { first = first, last = k, width = w, over = over,
        
        deep = items[k].kind == 1 and (line_deep or over > eps), forced = line_forced or false,
        ragged = line_end or k >= n or extended, code_overhang = extended,
        bp = (k < n) and ((items[k].emergency or items[k].soft)
          and items[k + 1].first or breakpoint_after(k)) or nil,
        measure = measure, capacity = capacity, cellcap = cellcap, shift = sh.shift,
        hyphen_disc = hyphen, hyphen_delta = hyphen and items[k].hyphen_delta or 0,
        post_disc=post_disc, post_width=post_width,
        code_limit = code_limit, isfirst = isfirst, forced_end = line_end or false,
        wrap_row = sh.wrap_row, wrap_skip = sh.wrap_skip }
    end
    local function offer(k, line_deep, line_end)
      if candidates and (line_end or (not bad_end(k) and legal_after(k))) then
        candidates[#candidates + 1] = make_line(k, line_deep, line_end)
      end
    end

    while j <= n do
      local it = items[j]
      
      local m = j
      if it.kind == 2 then
        while m + 1 <= n and items[m + 1].kind == 2 do m = m + 1 end
        if m + 1 <= n and items[m + 1].kind ~= 1 and items[m + 1].kind ~= 4 then m = m + 1 end
      end
      local core = m
      while true do
        local before = m
        while m + 1 <= n and items[m + 1].kind == 1 do m = m + 1 end
        
        local nxt = items[m + 1]
        
        if nxt and nxt.kind == 3 and nxt.glyphs and nxt.gn == 1
            and (ascii_close[nxt.head] or (P.nogrid and compat == 15 and m == core and items[core].kind == 3
                 and items[core].glyphs and connectors[nxt.head])) then
          m = m + 1
        end
        if m == before then break end
      end
      
      if P.nogrid and it.kind == 2 and core == j and m > core then
        core = core + 1
      end
      local w = width_of(items, first, m) + post_width + (isfirst and indent or 0)
      local spacing = it.kind == 4
      if not spacing and first_unit == nil then first_unit = m end
      local code_unit = P.code_overhang and items[m].code
      local limit = code_unit and code_limit or capacity
      if P.code_overhang and w > code_limit + eps and code_unit then
        break
      elseif w <= limit + eps then
        last = m
        have = have or not spacing
        offer(m, deep, mandatory_after(m))
        if mandatory_after(m) then forced_end = true; break end
        j = m + 1
      else
        
        if P.code_overhang and not code_unit and have
            and width_of(items, first, last) + (isfirst and indent or 0) > capacity + eps then break end
        local need = w - (snaps and math.min(cellcap, capacity) or capacity)
        if it.kind == 1 then break end
        if it.kind == 3 and it.glyphs and ascii_close[it.head]
          and not (j > first and items[j - 1].kind == 4 and not items[j - 1].user) then
          break
        end
        if it.kind == 2 and core == j then break end
        local j0 = j
        if spacing and m > core and items[core + 1].kind == 3 and items[core + 1].glyphs and ascii_close[items[core + 1].head] then
          core = core + 1
          local b = j
          while b > first and items[b - 1].kind == 4 do b = b - 1 end
          if b > first and items[b - 1].kind == 3 and items[b - 1].glyphs then j0 = b - 1 end
        end
        local t = unit_budget(first, j0, j, core, m, isfirst)
        t = t + space_shrink(first, j0, j, core, m, spots(first, j) + ((it.kind == 2 and core > j) and 1 or 0), t)
        if M.trace then
          local txt = {}
          for q = j, m do local x = items[q]; txt[#txt + 1] = x.c and trace_char(x.c) or (x.kind == 4 and "_" or "[]") end
          trace("unit %d..%d kind=%d %s need=%.3f budget=%.3f k=%d autos=%d", j, m, it.kind, table.concat(txt), need / bp, t / bp, spots(first, j), autos_in(first, j))
        end
        if need <= t + (compat == 15 and tight_eps or eps) then
          last = m
          have = true
          deep = m > core
          offer(m, deep, mandatory_after(m))
          if mandatory_after(m) then forced_end = true; break end
          j = m + 1
        else
          break
        end
      end
    end
    if not have then
      last = first_unit or first
      
      local ts = text_start(first)
      local it = items[ts]
      if (last == ts or (P.code_overhang and it.code)) and it.kind == 3
          and it.glyphs and it.gn >= 2 and it.nw > measure / 2 then
        local w0 = post_width + (isfirst and indent or 0)
        for k = first, ts - 1 do local x = items[k]; if not (x.kind == 4 and not x.user and first > 1) then w0 = w0 + x.nw end end
        local g = 0
        local acc = w0
        for i, gn in ipairs(it.glist) do
          local extra = (it.hangul and is_hangul(gn.char) and is_jfont(gn.font)) and P.excess
            or (it.code and 0 or P.latin_add)
          local add = gn.width + extra + (it.fb or 0)
          local limit = P.code_overhang and it.code and code_limit or capacity
          if acc + add <= limit + eps then acc = acc + add; g = i else break end
          if g == i and i < #it.glist and M.cluster_attr and node.get_attribute(gn,M.cluster_attr)
              and node.get_attribute(gn,M.cluster_attr) == node.get_attribute(it.glist[i+1],M.cluster_attr) then
            g = 0
            for previous = i-1,1,-1 do
              if node.get_attribute(it.glist[previous],M.cluster_attr) ~= node.get_attribute(gn,M.cluster_attr) then
                g = previous; break
              end
            end
          end
        end
        if P.code_overhang and it.code and last > ts and g == #it.glist then g = g - 1 end
        if g >= 1 and g < #it.glist then
          split_run(items, ts, g, P)
          n = #items
          last = ts
        end
      end
    end

    
    local function optional_hyphen_fits(k)
      if not items[k].hyphen_disc or k>=n then return true end
      local reserve=items[k].hyphen_delta
      
      
      
      if compat<15 and P.nogrid and not P.rtl and not items[k].code and not native_controls()
          and (node.getproperty(items[k].hyphen_disc) or {}).docxlike_word_host_auto then
        local fid=items[k].tailfont or items[k].font
        if fid then reserve=reserve+fspace(fid) end
      end
      local need=width_of(items,first,k)+post_width+(isfirst and indent or 0)+reserve-capacity
      if need<=eps then return true end
      if P.nogrid and P.justify and P.compress and compat==15 then
        local pool=0
        for q=first,k do
          if items[q].kind<=2 then return false end
          if q>first and q<k then pool=pool+space_give(q) end
        end
        return need<=pool+eps
      end
      return false
    end
    if not forced_end then
      while last > first and (bad_end(last) or not legal_after(last)
          or not optional_hyphen_fits(last)) do
        last = last - 1
      end
    end
    local forced = false
    if not forced_end and not legal_after(last) then
      while last + 1 <= n and not legal_after(last) do last = last + 1 end
      forced = true
    end
    
    if not forced_end and last + 1 <= n then
      local k = last + 1
      while k <= n and items[k].kind == 4 do k = k + 1 end
      if k > n then last = n end
    end
    local w = width_of(items, first, last) + (isfirst and indent or 0)
    local over = w - capacity
    local line = make_line(last, deep, forced_end, forced)
    if candidates then candidates[#candidates + 1] = line end
    if M.trace then
      local txt = {}
      for k = first, last do local it = items[k]; txt[#txt+1] = it.c and trace_char(it.c) or (it.kind == 4 and "_" or "[" .. (it.head and trace_char(it.head) or "?") .. "]") end
      trace("LINE w=%.2f/%.2f over=%.2f deep=%s forced=%s %s", w / bp, capacity / bp, over / bp, tostring(deep), tostring(forced), table.concat(txt))
      if M.trace_items then
        for k = first, last do
          local it = items[k]
          trace("  it %d kind=%d %s nw=%.2f gap=%.2f w=%.2f gn=%s rigid=%s", k, it.kind,
            it.c and trace_char(it.c) or (it.head and trace_char(it.head) or "?"), it.nw / bp, it.gap / bp, (it.w or 0) / bp, tostring(it.gn), tostring(it.rigid))
        end
      end
    end
    return line, candidates
  end

  local function greedy()
    local lines, i = {}, 1
    while i <= n do
      local line = scan_line(i, #lines + 1)
      lines[#lines + 1] = line
      if P.wrap_next then P.wrap_next(line) end
      i = line.last + 1
    end
    return lines
  end

  local lines
  if P.code_overhang and M.code_optimal and not P.wrap_next then
    local ps = tex.parshape
    local stable = 2
    if type(ps) == "table" and #ps > 0 then stable = math.max(stable, #ps)
    elseif tex.hangindent ~= 0 then stable = math.max(stable, math.abs(tex.hangafter) + 1) end
    local function score(line)
      if line.code_overhang then
        if line.width > line.code_limit + eps then return math.huge end
        for k = line.first, line.last do
          if items[k].kind ~= 4 and not items[k].code
              and width_of(items, line.first, k) + (line.isfirst and indent or 0) > line.capacity + eps then
            return math.huge
          end
        end
      end
      local cost = 10
      if line.code_overhang then
        local room = math.max(P.em, line.code_limit - line.capacity)
        cost = cost + 20 + 100 * (line.over / room)^2
      elseif line.last < n and not line.forced_end then
        local elasticity = 0
        for k = line.first, line.last do
          local it = items[k]
          if it.kind == 4 and not it.user then elasticity = elasticity + it.nw end
          if k > line.first then
            if it.gap > 0 then elasticity = elasticity + it.gap end
            if it.kind <= 2 and items[k - 1].kind <= 2 then elasticity = elasticity + P.em / 10 end
          end
          if it.spot then elasticity = elasticity + P.em / 4 end
        end
        local ratio = math.abs(line.over) / math.max(P.em / 4, elasticity)
        cost = cost + 100 * ratio^2
      elseif line.last == n and not line.isfirst then
        local fraction = line.width / math.max(P.em, line.capacity)
        cost = cost + 200 * (math.max(0, .2 - fraction) / .2)^2
      end
      if line.last < n and items[line.last].soft then cost = cost + (items[line.last].break_cost or 5) end
      if line.forced then cost = cost + 100000 end
      return cost
    end
    local function emergency(line)
      return line.last < n and items[line.last].emergency and 1 or 0
    end
    local function better(a, b)
      return not b or a.emergency < b.emergency
        or (a.emergency == b.emergency and a.cost < b.cost)
    end
    local function total(path)
      local state = { cost = 0, emergency = 0 }
      for _, line in ipairs(path) do
        state.cost = state.cost + score(line)
        state.emergency = state.emergency + emergency(line)
      end
      return state
    end
    local changed, best, baseline, audit
    repeat
      changed = false
      lines = greedy()
      baseline = total(lines)
      best = nil
      audit = M.check_optimal and n <= 14 and {} or nil
      local states = { [1] = { [1] = { cost = 0, emergency = 0, li = 1 } } }
      for first = 1, n do
        for _, state in pairs(states[first] or {}) do
          local before = n
          local _, candidates = scan_line(first, state.li, true)
          if n ~= before then changed = true; break end
          local edges
          if audit then
            audit[first] = audit[first] or {}
            edges = {}
            audit[first][math.min(state.li, stable)] = edges
          end
          for _, line in ipairs(candidates) do
            local line_cost, line_emergency = score(line), emergency(line)
            if edges then edges[#edges + 1] = { last = line.last, cost = line_cost, emergency = line_emergency } end
            local candidate = { cost = state.cost + line_cost,
              emergency = state.emergency + line_emergency, li = state.li + 1,
              previous = state, line = line }
            if candidate.cost < math.huge then
              if line.last == n then
                if better(candidate, best) then best = candidate end
              else
                local nextfirst = line.last + 1
                local phase = math.min(candidate.li, stable)
                states[nextfirst] = states[nextfirst] or {}
                if better(candidate, states[nextfirst][phase]) then states[nextfirst][phase] = candidate end
              end
            end
          end
        end
        if changed then break end
      end
    until not changed
    if best then
      lines = {}
      local state = best
      while state.line do table.insert(lines, 1, state.line); state = state.previous end
      trace("OPTIMAL lines=%d cost=%.3f greedy=%.3f emergency=%d/%d", #lines,
        best.cost, baseline.cost, best.emergency, baseline.emergency)
      if M.check_optimal then
        M.check_optimal({ cost = best.cost, emergency = best.emergency,
          greedy_cost = baseline.cost, greedy_emergency = baseline.emergency, lines = lines,
          graph = audit, stable = stable, count = n })
      end
    end
  else
    lines = greedy()
  end
  if #lines > 0 then lines[#lines].islast = true end
  return lines
end




local IMAGE_RULE = 2
local function is_picture(g)
  if g.id == RULE then return g.subtype == IMAGE_RULE end
  return g.id == HLIST and M.picture_attr ~= nil and node.get_attribute(g, M.picture_attr) == 1
end
local function scan_image(list)
  local img, txt = false, false
  for g in traverse(list) do
    if is_picture(g) then img = true
    elseif g.id == GLYPH then txt = true
    elseif (g.id == HLIST or g.id == VLIST) and g.list then
      local i, t = scan_image(g.list)
      img = img or i; txt = txt or t
    end
  end
  return img, txt
end
local function has_image(list)
  local img, txt = scan_image(list)
  return img and not txt
end
local function image_hd(list)
  local h, d = 0, 0
  for g in traverse(list) do
    if is_picture(g) or ((g.id == HLIST or g.id == VLIST) and g.list and has_image(g.list)) then
      local sh = (g.id == HLIST or g.id == VLIST) and g.shift or 0
      if g.height - sh > h then h = g.height - sh end
      if g.depth + sh > d then d = g.depth + sh end
    end
  end
  return h, d
end
local function image_line(ih, id, pitch)
  local tot = ih + id
  local n = math.max(1, math.ceil(tot / pitch - 0.001))
  local total = n * pitch
  local asc = ih + (total - tot) / 2
  return asc, total - asc
end
local function image_line_free(ih, id, ctx)
  local size = ctx.natpara / (ctx.latin and ctx.nat_latin or ctx.nat_cjk)
  local extra = (ctx.k - 1) * ctx.nat_latin * size
  if extra < 0 then extra = 0 end
  return ih, math.max(id, extra)
end

local function mark_math_objects(head)
  
  local inside = false
  for n in traverse(head) do
    if n.id == MATH then inside = n.subtype == 0 end
    if inside or n.id == MATH then
      local p = node.getproperty(n) or {}
      p.docxlike_math_object = true
      node.setproperty(n, p)
    end
  end
end
local inline_math_metrics_attr=luatexbase.attributes['docxlike@math@metrics@attr']
local inline_math_font_attr=luatexbase.attributes['docxlike@math@font@attr']


local function native_table_hd(head)
  local h, d = 0, 0
  local attribute = M.table_attr
  if not attribute then return h, d end
  for n in traverse(head) do
    if (n.id == VLIST or (n.id == HLIST and not is_packed(n)))
        and node.get_attribute(n, attribute) == 1 then
      local _, nh, nd = node.dimensions(n, n.next)
      h, d = math.max(h, nh), math.max(d, nd)
    end
  end
  return h, d
end

local function linebox(box, ctx, strut_h, strut_d)
  local properties = node.getproperty(box) or {}
  properties.docxlike_line_leading = 0
  node.setproperty(box, properties)
  if not ctx.exact then
    local ih, id = image_hd(box.list)
    if ih > 0 then
      if ctx.snap and ctx.pitch > 0 then
        box.height, box.depth = image_line(ih, id, ctx.pitch)
      else
        local height, depth = image_line_free(ih, id, ctx)
        box.height, box.depth = height, id
        properties.docxlike_line_leading = math.max(0, depth - id)
      end
      return
    end
  end
  local H, A, D = 0, 0, 0
  local mathH, mathA, mathD = 0, 0, 0
  local math_font_error=false
  local objA, objD = 0, 0
  local function glyph_metrics(g)
    local f = font.getfont(g.font)
    
    local sz = docxlike.run and docxlike.run.metric_size[g.font] or f and f.size or 0
    if sz == 0 then return end
    local h, a
    if ctx.mono and M.code_attr and (node.get_attribute(g, M.code_attr) or 0) > 0 then
      h, a = ctx.natpara, ctx.asc_para
    else
      local metrics = docxlike and docxlike.metrics and docxlike.metrics.for_font(g.font)
      if metrics and metrics.math then
        
        
        h, a = metrics.natural * sz, metrics.ascent * sz
      elseif is_wide(g.char) or is_jfont(g.font) then
        
        
        h, a = ctx.nat_cjk * sz, ctx.asc_cjk * sz
      else h, a = ctx.nat_latin * sz, ctx.asc_latin * sz end
    end
    
    M.pos_attr = M.pos_attr or luatexbase.attributes["docxlike@pos@attr"]
    local r = M.pos_attr and node.has_attribute(g, M.pos_attr) or 0
    if h > H then H = h end
    if a + r > A then A = a + r end
    if h - a - r > D then D = h - a - r end
  end
  local function object_metrics(g)
    local _, height, depth = node.dimensions(g, g.next)
    if height > objA then objA = height end
    if depth > objD then objD = depth end
  end
  local function word_math_metrics(g)
    if not inline_math_metrics_attr or node.has_attribute(g,inline_math_metrics_attr)~=1 then return end
    local fid=inline_math_font_attr and node.has_attribute(g,inline_math_font_attr)
    if not fid and g.id==GLYPH then fid=g.font end
    if fid and fid>0 then
      local f=font.getfont(fid)
      local metrics=docxlike.metrics.for_math_font(fid)
      if metrics and f then
        local h,a=metrics.natural*f.size,metrics.ascent*f.size
        mathH=math.max(mathH,h);mathA=math.max(mathA,a);mathD=math.max(mathD,h-a)
      elseif not math_font_error then
        math_font_error=true
        tex.error('docxlike inline-math-metrics=word requires an OpenType MATH font',
          {'Select a math font with unicode-math, or use inline-math-metrics=latex.'})
      end
    elseif g.id==HLIST and g.head then
      for child in traverse(g.head) do word_math_metrics(child) end
    end
  end
  local function page_metrics(list)
    for g in traverse(list) do
      if g.id==GLYPH then glyph_metrics(g)
      elseif g.id==HLIST and g.head then page_metrics(g.head) end
    end
  end
  for g in traverse(box.list) do
    local id = g.id
    if (node.getproperty(g) or {}).docxlike_math_object then
      word_math_metrics(g)
      if id == GLYPH or id == HLIST or id == VLIST or id == RULE then
        object_metrics(g)
      end
    elseif id == GLYPH then
      glyph_metrics(g)
    elseif id == HLIST and is_packed(g) then
      for m in traverse(g.list) do if m.id == GLYPH then glyph_metrics(m) end end
    elseif id==HLIST and toc_tail_attr and node.get_attribute(g,toc_tail_attr)==1 and not ctx.snap then
      for page in traverse(g.head) do
        if page.id==HLIST and node.get_attribute(page,toc_tail_attr)==2 then page_metrics(page.head) end
      end
    elseif id == HLIST or id == VLIST or (id == RULE and g.width ~= 0) then
      object_metrics(g)
    end
  end
  
  if H == 0 then
    H, A = ctx.natpara, ctx.asc_para
    D = H - A
  end
  local max_run_height = H
  H = A + D
  if not ctx.exact and not ctx.snap and max_run_height>ctx.natpara+1 then
    local pixel=.12*65781.76
    A=math.min(H,math.ceil((A-1)/pixel)*pixel)
    D=H-A
  end
  max_run_height=math.max(max_run_height,mathH)
  A,D=math.max(A,mathA),math.max(D,mathD)
  H=A+D
  local asc, desc
  if ctx.exact then
    asc, desc = strut_h, strut_d
    local th, td = native_table_hd(box.list)
    asc, desc = math.max(asc, th), math.max(desc, td)
  elseif ctx.snap and ctx.pitch > 0 then
    local n = math.ceil(H / ctx.pitch - 0.001)
    local total = math.max(ctx.bls, n * ctx.pitch)
    asc = A + (total - H) / 2
    desc = total - asc
  elseif ctx.minimum then
    local total = math.max(ctx.minimum, H)
    asc, desc = A + total - H, H - A
  else
    asc, desc = A, D
    
    properties.docxlike_line_leading = math.max(0, ctx.k - 1) * max_run_height
  end
  
  if not ctx.exact then
    if objA > asc then asc = objA end
    if objD > desc then desc = objD end
  end
  box.height = asc; box.depth = desc
  M.last_text_ascent = A
  
  
  M.talign_attr = M.talign_attr or luatexbase.attributes["docxlike@talign@attr"]
  local mode
  for g in traverse(box.list) do
    local v = M.talign_attr and node.has_attribute(g, M.talign_attr)
    if v then mode = v; break end
  end
  if mode == 1 or mode == 2 then
    local function each(list, fn)
      for g in traverse(list) do
        if g.id == GLYPH then fn(g)
        elseif g.id == HLIST and is_packed(g) then each(g.list, fn) end
      end
    end
    local function ad(g)
      local a, d = docxlike.metrics.win(g.font)
      local f = font.getfont(g.font)
      if not a or not f then return nil end
      local sz = docxlike.run and docxlike.run.metric_size[g.font] or f.size
      return a * sz, d * sz
    end
    local LA, LD = 0, 0
    each(box.list, function(g) local a, d = ad(g); if a then LA = math.max(LA, a); LD = math.max(LD, d) end end)
    each(box.list, function(g)
      local a, d = ad(g)
      if a then
        local shift = mode == 1 and (LA - a) or ((LA - LD) - (a - d)) / 2
        g.yoffset = g.yoffset + math.floor(shift + 0.5)
      end
    end)
  end
  if ctx.exact then
    local ea = luatexbase.attributes["docxlike@exact@attr"]
    if ea then node.set_attribute(box, ea, 1) end
  end
  trace("BOX H=%.2f A=%.2f obj=%.2f+%.2f k=%.3f %s -> %.2f+%.2f", H / 65536, A / 65536, objA / 65536, objD / 65536, ctx.k,
    ctx.exact and "exact" or (ctx.snap and "snap" or "auto"), asc / 65536, desc / 65536)
end



local function append_list(list, inner)
  if list then
    local t = node.tail(list); t.next = inner; inner.prev = t
    return list
  end
  return inner
end
local function move_out(box)
  local moved, pre = nil, nil
  local g = box.list
  while g do
    local nx = g.next
    if g.id == INS or g.id == MARK or g.id == ADJUST then
      box.list = node.remove(box.list, g)
      g.prev = nil; g.next = nil
      if g.id == ADJUST then
        
        local inner = g.list; g.list = nil
        local is_pre = g.subtype == 1
        node.free(g)
        if inner then
          if is_pre then pre = append_list(pre, inner) else moved = append_list(moved, inner) end
        end
      else
        moved = moved and node.insert_after(moved, node.tail(moved), g) or g
      end
    end
    g = nx
  end
  return moved, pre
end

local function balance_line_directions(head, P)
  local stack = P.direction_stack or {}
  local incoming = {}
  for i,entry in ipairs(stack) do incoming[i] = entry end
  for n in traverse(head) do
    if n.id == node.id("dir") then
      if n.subtype == 0 then stack[#stack+1] = n
      elseif #stack > 0 then stack[#stack] = nil end
    end
  end
  P.direction_stack = stack
  
  for i = #incoming,1,-1 do
    head = node.insert_before(head,head,node.copy(incoming[i]))
  end
  for i = #stack,1,-1 do
    local cancel = node.copy(stack[i]); cancel.dir = "-" .. stack[i].dir:sub(-3)
    head = node.insert_after(head,node.tail(head),cancel)
  end
  return head
end

local function render(items, line, P, strut_h, strut_d, indent, isfirst, ctx, headnode)
  local p = P.cell
  local half = p / 2
  local compat = P.compat
  local bp = P.bp
  local eps = P.eps
  local measure = line.measure
  local first, last = line.first, line.last
  local a, b = items[first], items[last]
  local head = headnode or a.first
  local nxt = line.bp or b.last.next
  
  if nxt and nxt.prev then
    nxt.prev.next = nil
    nxt.prev = nil
  end
  head.prev = nil
  head = balance_line_directions(head,P)
  
  if not isfirst then
    local g = head
    while g and (g.id == GLUE or g.id == KERN or g.id == PENALTY or g.id == node.id("dir")) do
      if g.id == GLUE then g.width = 0; g.stretch = 0; g.shrink = 0
      elseif g.id == KERN then g.kern = 0 end
      g = g.next
    end
  end
  if line.post_disc and line.post_disc.post then
    local post=node.copy_list(line.post_disc.post)
    local t=node.tail(post); t.next=head; head.prev=t; head=post
    for g in traverse(post) do
      if g==t.next then break end
      if g.id==GLYPH then
        local kn=node.new(KERN); kn.kern=P.latin_add+(fake_bold(g) or 0)
        node.insert_after(head,g,kn)
      end
      if g==t then break end
    end
  end
  
  local hasfil = false
  for g in traverse(head) do
    if g.id == GLUE then
      if P.nogrid and g.subtype == 15 then
        
        g.stretch = 0; g.stretch_order = 0; g.shrink = 0
      elseif g.stretch_order > 0 then hasfil = true; g.shrink = 0
      else g.stretch = 0; g.stretch_order = 0; g.shrink = 0 end
    end
  end
  
  local function base_of(k)
    local it = items[k]
    if it.paired and k == last then
      if P.nogrid and P.compat ~= 15 and not line.deep and not line.forced then return it.nw end
      return it.full
    end
    return it.nw
  end
  local first_text=first
  while first_text<last and items[first_text].kind==4 do first_text=first_text+1 end
  for k = first, last do
    local it = items[k]
    it.gapkern = nil; it.adj = nil; it.pre = nil; it.afterkern = nil
    if k > first and it.gap ~= 0 then
      local kn = node.new(KERN); kn.kern = it.gap
      local pv = items[k - 1]
      node.insert_after(head, pv.core or pv.last, kn)
      it.gapkern = kn
    end
    if it.kind == 4 and it.user then
      
    elseif it.kind == 4 then
      it.core.width = ((k == first and first > 1) or k == last) and 0 or it.nw
      local g = it.core.next
      while g and g ~= it.last.next do if g.id == GLUE and g.subtype < 100 then g.width = 0 end; g = g.next end
    elseif it.rigid then
      
      local g = it.core and it.core.next
      while g and g ~= it.last.next do if g.id == GLUE and g.subtype < 100 then g.width = 0 end; g = g.next end
    elseif it.kind == 3 then
      
      for _, e in ipairs(it.kerns) do e[1].kern = e[2] end
      local g = it.first
      while g do
        if g.id == GLUE and g.subtype < 100 then g.width = 0 end
        if g == it.last then break end
        g = g.next
      end
      local add = (latinish[it.c] and it.w >= it.size * 0.9) and (it.nw - it.w)
        or ((it.code and 0 or P.latin_add) + (it.fb or 0))
      add=add+(it.logical_grid_add or 0)
      for _, g in ipairs(it.glist) do
        local kn = node.new(KERN)
        kn.kern = (it.hangul and is_hangul(g.char) and is_jfont(g.font)) and (P.excess + (it.fb or 0)) or add
        if g==it.glist[#it.glist] and it.terminal_grid_drop then
          kn.kern=kn.kern-it.terminal_grid_drop
        end
        node.insert_after(head, g, kn)
        if g == it.last then it.last = kn end
      end
      for _, d in ipairs(it.discs or {}) do
        local kn = node.new(KERN); kn.kern = add
        node.insert_after(head, d, kn)
        if d == it.last then it.last = kn end
      end
      for _, d in ipairs(it.native_discs or {}) do
        for g in traverse(d.replace) do
          if g.id==GLYPH then
            local kn=node.new(KERN); kn.kern=add
            d.replace=node.insert_after(d.replace,g,kn)
          end
        end
      end
    else
      local w = 0
      local g = it.first
      while g do w = w + nodewidth(g); if g == it.last then break end; g = g.next end
      it.spanw = w
      local kn = node.new(KERN); kn.kern = base_of(k) - w
      if it.kind == 2 then
        
        local grid_pad=P.grid and (P.char_grid_extra or 0) or 0
        local tracking_pad=P.nogrid and (P.spacing or 0) or 0
        kn.kern = base_of(k) - it.full + (it.w - w) + grid_pad
        kn.kern=kn.kern+tracking_pad
        node.insert_before(head, it.first, kn)
        if it.first == head then head = kn end
        it.pre = kn
        local kn2 = node.new(KERN); kn2.kern = it.full - w - grid_pad
        kn2.kern=kn2.kern-tracking_pad
        if P.nogrid and compat~=15 and k==first_text and it.paired then
          local shift=it.full-base_of(k)
          kn.kern=kn.kern+shift; kn2.kern=kn2.kern-shift
        end
        node.insert_after(head, it.core or it.last, kn2)
        it.adj = kn2
      else
        node.insert_after(head, it.core or it.last, kn)
        it.adj = kn
        if it.midpad then
          local pre = node.new(KERN); pre.kern = (base_of(k) - it.midpad) / 2
          node.insert_before(head, it.first, pre)
          if it.first == head then head = pre end
          it.pre = pre
          kn.kern = kn.kern - pre.kern
        end
      end
    end
  end
  local geometry
  if type(M._geometry_observer)=='function' then
    local observed={line={measure_bp=measure/bp,shift_bp=(line.shift or 0)/bp,
      indent_bp=(isfirst and indent or 0)/bp,isfirst=isfirst,islast=line.islast==true,
      deep=line.deep==true,forced=line.forced==true,align=P.align,nogrid=P.nogrid==true,
      balance=P.balance==true,cjk_compress=P.cjk_compress~=false,compat=compat,
      horizontal_stages_exact=(P.align=='left' or P.align=='justify') and not hasfil and not P.rtl},items={}}
    for k=first,last do
      local it=items[k]
      observed.items[#observed.items+1]={index=k,kind=it.kind,char=it.c or it.head,
        natural_bp=base_of(k)/bp,gap_before_bp=(k>first and it.gap or 0)/bp,
        glyph_count=it.gn or 0,rigid=it.rigid==true,paired=it.paired==true}
    end
    observed.natural=geometry_snapshot(head,(line.shift or 0)+(isfirst and indent or 0))
    if M._geometry_observer('natural',observed) then geometry=observed end
  end
  local count = last - first + 1
  local delta, after = {}, {}
  for k = first, last do delta[k] = 0; after[k] = 0 end
  local start = first
  while start < last and items[start].kind == 4 do start = start + 1 end
  
  local shift_return = line.forced_end and not hasfil and not line.islast and not P.no_expand_shift_return
  
  
  local section_last = line.islast and P.section_end and not P.no_expand_shift_return
  local ragged = not P.distributed and ((line.ragged and not shift_return and not section_last)
    or (line.islast and not section_last) or P.align ~= "justify")
  local pure_latin = P.justify and (P.nogrid or balanced_latin_line(items,first,last,P))
  for k = first, last do
    if items[k].kind <= 2 then pure_latin = false; break end
  end
  local latin_text=pure_latin
  if latin_text then
    for k=first,last do
      if items[k].kind==3 and items[k].glyphs and not device_latin_run(items[k]) then latin_text=false;break end
    end
  end
  local hinted_latin=latin_text and not P.balance and not ragged and not line.forced and not hasfil and not P.rtl
  local legacy_gap_delta=0
  local legacy_gaps={}
  if hinted_latin then
    for k=first,last do
      local it=items[k]
      if it.kind==4 and not it.user and k>first and k<last then
        if compat~=15 and it.leading_kern and it.leading_kern~=0 then
          local extra=-it.leading_kern
          legacy_gaps[k]=extra
          legacy_gap_delta=legacy_gap_delta+extra
        end
      end
    end
  end

  
  
  
  local target = line.capacity
  if M.compat < 15 and P.ari and P.justify and not P.table_cell and not P.nogrid
    and M.grid_on and P.cell0 and P.cell0 > 0 then
    local full = tex.hsize
    target = math.min(target, math.floor(full / P.cell0 + 1e-6) * P.cell0 - (full - measure))
  end
  local over = line.over + line.capacity - target + legacy_gap_delta
  if P.toc_legacy_tail and items[last].toc_tail and line.over>0 then
    
    over=line.width-items[last].nw-target
  end
  
  if line.code_overhang then over = math.min(over, 0) end
  local uncompressed_hang=P.cjk_compress==false
  local final_hang_limit=uncompressed_hang and items[last].nw or half
  if P.nogrid and P.justify and (compat~=11 or uncompressed_hang) and line.islast and line.deep
      and not line.forced and not hasfil and over>eps and over<=final_hang_limit+eps
      and not items[last].symbol and (uncompressed_hang or not never_compressed[items[last].c]) then
    ragged = false
  end

  
  local older_shrink = P.nogrid and compat ~= 15 and P.cjk_compress ~= false and P.cjk_compress_given
  if older_shrink then
    for k = first, last do
      if items[k].spot then older_shrink = false; break end
    end
  end

  
  
  local function give(k)
    local t = items[k]
    
    if t.kind ~= 4 or t.user or t.rigid then return 0 end
    local in_run = (k > 1 and items[k - 1].kind == 4) or (k < #items and items[k + 1].kind == 4)
    if in_run then return 0 end
    local after_punct = k > 1 and (items[k - 1].kind == 1 or items[k - 1].kind == 2) and not items[k - 1].symbol
    if after_punct then return t.nw end
    return t.nw * 0.25
  end
  local ascii_hang = 0
  do
    local lt = items[last]
    if over > 0 and not line.forced and not line.deep and not P.table_cell and not P.toc
      and lt.kind == 3 and (lt.tail_hang or 0) > 0 then
      local room, spaces, first_space = 0, 0, nil
      for k = first, last do
        if items[k].spot and not (items[k].kind == 2 and k == start) then room = room + half end
        if k < last and items[k + 1].gap > 0 then room = room + items[k + 1].gap / 2 end
        if (compat == 15 or older_shrink) and P.justify and k > first and k < last then
          local g = give(k)
          if g > 0 then spaces = spaces + g; first_space = first_space or items[k].nw end
        end
      end
      if first_space then room = room + (pure_latin and spaces or math.min(spaces, 1.85 * first_space)) end
      if over > room + eps then ascii_hang = lt.tail_hang + P.latin_add end
    end
  end

  local whole_hang, paired_hang, in_place, cap_last = false, false, false, false
  if over - ascii_hang > 0 and not line.forced then
    local spot_idx = {}
    for k = first, last do
      local it = items[k]
      if it.spot and not (it.kind == 2 and k == start) and not (line.deep and k == last) then spot_idx[#spot_idx + 1] = k end
    end
    local need = over - ascii_hang
    
    if (compat == 15 or older_shrink) and P.justify then
      local sp, cap = {}, 0
      for k = first + 1, last - 1 do
        local g = give(k)
        if g > 0 then sp[#sp + 1] = { k, g }; cap = cap + g end
      end
      if cap > 0 then
        local take = math.min(need, cap, pure_latin and cap or 1.85 * items[sp[1][1]].nw)
        if take > 0 then
          for _, e in ipairs(sp) do delta[e[1]] = delta[e[1]] - e[2] * (take / cap) end
          need = need - take
        end
      end
    end
    local k = #spot_idx
    local cap = half
    local hang = 0
    local inline = need
    if line.deep and need>eps then
      local lt = items[last]
      if P.toc then
        hang=0
      elseif P.nogrid and P.cjk_compress == false and not lt.symbol then
        
        local gap_room=0
        if compat==15 and P.justify then
          for q=first+1,last do gap_room=gap_room+items[q].gap/2 end
        end
        if need<=gap_room+eps then
          inline=need
        else
          hang = lt.nw
          inline = math.max(need - hang, 0)
          whole_hang = true
        end
      elseif compat == 11 then
        
        local h = (never_compressed[lt.c] or lt.symbol) and 0 or half
        paired_hang=P.nogrid and lt.paired and h>0
        hang = paired_hang and h or math.min(h,need)
        inline = math.max(need - hang,0)
        cap_last = hang > 0
      elseif never_compressed[lt.c] or lt.symbol then
        
        hang = lt.nw
        inline = math.max(need - hang, 0)
        whole_hang = not lt.symbol
      else
        
        
        if need <= half + eps and P.justify and not ragged and not hasfil then
          delta[last] = delta[last] - half
          inline = 0
          in_place = true
          cap_last = true
        elseif need <= cap * k + eps then
          inline = need
        elseif need - half <= cap * k + eps then
          delta[last] = delta[last] - half
          inline = need - half
          in_place = true
          cap_last = true
        else
          hang = p
          inline = math.max(need - p, 0)
          whole_hang = true
          cap_last = true
        end
      end
    end
    if k > 0 then
      local each = math.min(inline / k, cap)
      for _, s in ipairs(spot_idx) do
        local take=each
        local it=items[s]
        if P.nogrid and compat~=15 and it.kind==1 then
          local _,right=punctuation_ink(it)
          if right then take=math.min(take,math.max(0,it.full-right)) end
        end
        delta[s]=delta[s]-take
        inline=inline-take
      end
    end
    
    if inline > eps then
      local open = {}
      for k2 = first, last - 1 do if items[k2 + 1].gap > 0 then open[#open + 1] = k2 end end
      local left = inline
      while left > eps and #open > 0 do
        local each = left / #open
        local nextopen = {}
        for _, k2 in ipairs(open) do
          local gap=items[k2+1].gap
          local room = ((P.nogrid and compat==15 and P.cjk_compress==false) and gap/2 or gap) + after[k2]
          if room <= each then
            after[k2] = after[k2] - room; left = left - room
          else
            after[k2] = after[k2] - each; left = left - each
            nextopen[#nextopen + 1] = k2
          end
        end
        if #nextopen == #open then break end
        open = nextopen
      end
      inline = left
    end
  end

  local symbol_hang = line.deep and items[last].symbol and over > 0 and compat ~= 11
  local natural_w = width_of(items, first, last) + legacy_gap_delta + (isfirst and indent or 0) + (line.hyphen_delta or 0)
    +(line.post_width or 0)
  if items[last].paired then natural_w = natural_w - (items[last].full-base_of(last)) end
  if symbol_hang or whole_hang then natural_w = natural_w - items[last].nw end
  if paired_hang then natural_w=natural_w-half end
  natural_w = natural_w - ascii_hang
  local compressed = 0
  for k = first, last do compressed = compressed + delta[k] end
  local slack = target - (natural_w + compressed)
  if P.nogrid and (in_place or whole_hang) and slack>0 then
    
    local shrink=0
    for k=first+1,last-1 do
      local it=items[k]
      if it.kind==4 and not it.user and not it.rigid and delta[k]<0 then
        shrink=shrink-delta[k]
      end
    end
    if shrink>0 then
      local refund=math.min(shrink,slack)
      for k=first+1,last-1 do
        local it=items[k]
        if it.kind==4 and not it.user and not it.rigid and delta[k]<0 then
          delta[k]=delta[k]*(1-refund/shrink)
        end
      end
      compressed=compressed+refund
      slack=slack-refund
    end
  end
  
  if ascii_hang > 0 and slack > 0 and not P.distributed and not line.forced and not hasfil
      and (P.align == "left" or (P.justify and ragged)) then
    local sp, cjk = {}, false
    for k = first, last do
      local it = items[k]
      if it.kind <= 2 then cjk = true end
      if it.kind == 4 and not it.user and not it.rigid and k > first and k < last then sp[#sp + 1] = k end
    end
    if not cjk and #sp > 0 then
      for _, k in ipairs(sp) do delta[k] = delta[k] + slack / #sp end
      slack = 0
    end
  end
  if P.justify and not P.distributed and not ragged and not line.forced and not hasfil and slack > 0
    and (over <= 0 or symbol_hang or whole_hang or paired_hang or in_place or ascii_hang > 0) then
    local autos, spaces, cjkgaps, halves = {}, {}, {}, {}
    for k = first, last do
      local it = items[k]
      if k > first and it.gap > 0 then autos[#autos + 1] = k - 1 end
      if it.kind == 4 and not it.user and k > first and k < last then
        if it.rigid then halves[#halves + 1] = k else spaces[#spaces + 1] = k end
      end
      if k < last and (it.kind <= 2 or (P.nogrid and it.kind == 3 and it.glyphs
          and items[k+1].kind <= 2 and items[k+1].gap == 0)) then
        cjkgaps[#cjkgaps + 1] = k
      end
    end
    
    if #spaces > 0 then
      local cap, total = 0, 0
      
      local word_space_limit = P.nogrid and (compat~=15 and (P.balance and 1 or 2/3) or 0.5) or 5/6
      for _, k in ipairs(spaces) do cap = cap + items[k].w * word_space_limit; total = total + items[k].w end
      local take = (#autos == 0 and #cjkgaps == 0) and slack or math.min(slack, cap)
      if total > 0 then
        for _, k in ipairs(spaces) do after[k] = after[k] + take * (items[k].w / total) end
        slack = slack - take
      end
    end
    if slack > 0 and #autos > 0 then
      local cap, weights = 0, {}
      for _, k in ipairs(autos) do
        weights[k] = P.grid and not P.balance and items[k].size/5 or items[k+1].gap
        cap = cap + weights[k]
      end
      local take = (#cjkgaps == 0) and slack or math.min(slack, cap)
      if cap > 0 then
        if P.nogrid and not P.balance and compat~=15 and take<cap then
          
          local pending={table.unpack(autos)}
          local left=take
          while left>0 and #pending>0 do
            local total=0
            for _,k in ipairs(pending) do total=total+(items[k].size or p)*(items[k].kind==0 and 2 or 1) end
            local next_pending={}
            local saturated=false
            for _,k in ipairs(pending) do
              local weight=(items[k].size or p)*(items[k].kind==0 and 2 or 1)
              if left*weight/total>=weights[k] then
                after[k]=after[k]+weights[k]
                saturated=true
              else next_pending[#next_pending+1]=k end
            end
            if not saturated then
              for _,k in ipairs(pending) do
                local weight=(items[k].size or p)*(items[k].kind==0 and 2 or 1)
                after[k]=after[k]+left*weight/total
              end
              left=0
            else
              local remaining=0
              for _,k in ipairs(next_pending) do remaining=remaining+weights[k] end
              local previous=0
              for _,k in ipairs(pending) do previous=previous+weights[k] end
              left=math.max(0,left-(previous-remaining))
              pending=next_pending
            end
          end
        else
          for _, k in ipairs(autos) do after[k] = after[k] + take * (weights[k] / cap) end
        end
        slack = slack - take
      end
    end
    if slack > 0 and #cjkgaps > 0 then
      local nslots = #cjkgaps + #spaces + #autos + #halves
      local slots
      local doubled={}
      if P.nogrid then
        
        slots={}
        for _,pool in ipairs({cjkgaps,spaces,autos,halves}) do
          for _,k in ipairs(pool) do slots[k]=true end
        end
        nslots=0
        for _ in pairs(slots) do nslots=nslots+1 end
        if P.balance and P.cjk_compress==false then
          for _,k in ipairs(autos) do
            if items[k].kind==0 then
              local next_cjk=k+2
              while next_cjk<=last and items[next_cjk].kind==3 and items[next_cjk].glyphs do next_cjk=next_cjk+1 end
              if next_cjk<=last and items[next_cjk].kind==0 and items[next_cjk].gap>0 then
                doubled[#doubled+1]=k
                nslots=nslots+1
              end
            end
          end
        end
      end
      if P.nogrid and compat~=15 and P.cjk_compress~=false and over<=0 then
        local cjk_only=true
        for k=first,last do
          local it=items[k]
          if it.kind>2 then cjk_only=false; break end
        end
        if cjk_only then
          for k=first,last do
            local it=items[k]
            if it.spot then
              local left,right=punctuation_ink(it)
              local blank=right and (it.full-(right-left)) or it.full/2
              nslots=nslots+math.max(0,blank)/p
            end
          end
        else
          local label=start
          while label<last and items[label].kind==2 do label=label+1 end
          local it=items[label]
          if it.kind==3 and it.glyphs and it.nw<p then
            local tail=label+1
            if items[tail] and items[tail].kind==4 and not items[tail].user then tail=tail+1 end
            local cjk_tail=true
            for k=tail,last do if items[k].kind>2 then cjk_tail=false; break end end
            if cjk_tail and isfirst then nslots=nslots+math.max(indent,0)/p end
          end
        end
      end
      local each = slack / nslots
      if slots then
        for k in pairs(slots) do after[k]=after[k]+each end
        for _,k in ipairs(doubled) do after[k]=after[k]+each end
      else
        for _, k in ipairs(cjkgaps) do after[k] = after[k] + each end
        for _, k in ipairs(spaces) do after[k] = after[k] + each end
        for _, k in ipairs(autos) do after[k] = after[k] + each end
        for _, k in ipairs(halves) do after[k] = after[k] + each end
      end
      slack = slack - each * nslots
    end
    if slack > 0 then
      local pool = (#spaces > 0) and spaces or autos
      if #pool > 0 then
        local each = slack / #pool
        for _, k in ipairs(pool) do after[k] = after[k] + each end
        slack = 0
      end
    end
  end

  if hinted_latin then
    for k=first,last do
      if items[k].kind==4 and not items[k].user and after[k]>0 then
        after[k]=compat==15 and devtrunc(after[k]) or math.floor(after[k]/(.05*bp)+1e-6)*(.05*bp)
      end
    end
  end
  if P.nogrid and not P.balance and compat==15 and not ragged and not line.forced and not hasfil then
    local cjk_only=true
    for k=first,last do if items[k].kind>2 then cjk_only=false;break end end
    if cjk_only then
      for k=first,last do
        if after[k]>0 then after[k]=devround(math.floor(after[k]/(.05*bp)+1e-6)*(.05*bp)) end
      end
    end
  end

  for k = first, last do
    local it = items[k]
    local extra = after[k]
    if it.kind <= 2 then
      local base = base_of(k)
      local target = base + delta[k] + extra
      
      if k == last and cap_last then target = math.min(target, it.full / 2) end
      if it.kind == 2 then
        it.pre.kern = it.pre.kern + delta[k]
        it.adj.kern = target - it.spanw - it.pre.kern
        trace('OPENER-PLACE char=%X paired=%s width=%.6f full=%.6f span=%.6f pre=%.6f delta=%.6f extra=%.6f target=%.6f',
          it.c or 0,tostring(it.paired),it.w/bp,it.full/bp,it.spanw/bp,it.pre.kern/bp,delta[k]/bp,extra/bp,target/bp)
      elseif it.midpad then
        it.pre.kern = (target - it.midpad) / 2
        it.adj.kern = target - it.spanw - it.pre.kern
      else
        it.adj.kern = target - it.spanw
      end
    elseif it.kind == 3 then
      if extra ~= 0 then
        local kn = node.new(KERN); kn.kern = extra
        node.insert_after(head, it.last, kn)
        it.last = kn
      end
    else
      if it.user then
        if extra ~= 0 then
          local kn = node.new(KERN); kn.kern = extra
          node.insert_after(head, it.last, kn)
        end
      elseif not ((k == first and first > 1) or k == last) then
        it.core.width = it.nw + delta[k] + extra + (legacy_gaps[k] or 0)
      end
    end
  end
  if M.trace_items then
    
    for k = first, last do
      local it = items[k]
      local startn = it.pre or it.first
      if k == first and it.kind ~= 2 then startn = head end
      local stopn = (k < last) and (items[k + 1].pre or items[k + 1].first) or nil
      local span = node.dimensions(startn, stopn)
      local expect = base_of(k) + delta[k] + after[k] + ((k < last) and items[k + 1].gap or 0)
      if it.kind == 4 and not it.user and ((k == first and first > 1) or k == last) then expect = expect - it.nw end
      if math.abs(span - expect) > 200 then
        trace("  SPAN k=%d kind=%d %s span=%.3f expect=%.3f", k, it.kind, it.c and trace_char(it.c) or (it.head and trace_char(it.head) or "?"), span / bp, expect / bp)
      end
    end
  end
  local t = node.tail(head)
  while t and t ~= head and (t.id == GLUE or t.id == PENALTY) do
    local pr = t.prev; node.remove(head, t); node.free(t); t = pr
  end
  if (P.align == "center" or P.align == "right") and not hasfil then
    
    local lead = node.new(GLUE); lead.stretch = 65536; lead.stretch_order = 2
    lead.next = head; head.prev = lead; head = lead
    if P.align == "center" then
      local fil = node.new(GLUE); fil.stretch = 65536; fil.stretch_order = 2
      node.insert_after(head, node.tail(head), fil)
    end
    local area = measure
    if M.compat < 15 and P.ari and not P.nogrid and M.grid_on and not P.table_cell
        and P.cell0 and P.cell0 > 0 then
      area = math.floor(measure / P.cell0 + 1e-6) * P.cell0
    end
    if area < measure then
      local kn = node.new(KERN); kn.kern = measure - area
      node.insert_after(head, node.tail(head), kn)
    end
  elseif ragged and not hasfil then
    local fil = node.new(GLUE); fil.subtype = 15; fil.stretch = 65536; fil.stretch_order = 2
    node.insert_after(head, node.tail(head), fil)
  elseif target < measure and not hasfil then
    local rest = measure - math.max(target, natural_w + compressed)
    if rest > 0 then
      local kn = node.new(KERN); kn.kern = rest
      node.insert_after(head, node.tail(head), kn)
    end
  end
  if isfirst and indent ~= 0 then
    local ib = node.new(HLIST); ib.subtype = 3; ib.width = indent
    ib.next = head; head.prev = ib; head = ib
  end
  
  local tail = items[last]
  if not line.forced and line.over > 0 and tail.kind == 3 and (tail.tail_hang or 0) > 0 then
    local dw = node.dimensions(head)
    if dw > measure and dw - measure <= tail.tail_hang + P.latin_add + P.eps then
      local kn = node.new(KERN); kn.kern = measure - dw
      node.insert_after(head, node.tail(head), kn)
    end
  end
  if line.code_overhang then
    local dw = node.dimensions(head)
    if dw > measure then
      local kn = node.new(KERN); kn.kern = measure - dw
      node.insert_after(head, node.tail(head), kn)
    end
  end
  if P.toc and items[last].toc_tail then
    local tail=items[last].toc_tail
    local prefix=node.dimensions(head,tail)
    local goal=math.max(items[last].nw,measure-prefix)
    if P.toc_legacy_tail and measure-prefix<items[last].nw-P.eps then
      goal=items[last].nw+.12*bp
    end
    local leader
    for g in traverse(tail.head) do
      if g.id==GLUE and g.leader then leader=g; break end
    end
    if leader and leader.leader.width>0 then
      local pitch=leader.leader.width
      local device_delta=0
      for g in traverse(head) do
        if g==tail then break end
        if g.id==GLYPH then device_delta=device_delta+g.width-devtrunc(g.width)
        elseif g.id==HLIST and is_packed(g) then
          for q in traverse_id(GLYPH,g.head) do device_delta=device_delta+q.width-devtrunc(q.width) end
        elseif g.id==GLUE then device_delta=device_delta+g.width-devtrunc(g.width)
        elseif g.id==KERN then device_delta=device_delta+g.kern-devtrunc(g.kern) end
      end
      local phase=pitch-((P.toc_origin+line.shift+prefix-device_delta)%pitch)-device_delta
      if P.grid then
        
        local cursor=prefix
        local pixel=.12*bp
        for k=last-1,first,-1 do
          local it=items[k]
          if it.kind~=0 then break end
          local advance=base_of(k)+delta[k]+after[k]
          cursor=cursor+math.floor(advance/pixel+.5)*pixel-advance
        end
        for k=first,last-1 do
          local it=items[k]
          cursor=cursor-(it.logical_grid_add or 0)*(it.gn or 0)
        end
        while prefix+phase<cursor-1 do phase=phase+pitch end
        while prefix+phase-pitch>=cursor-1 do phase=phase-pitch end
      end
      trace('TOC-TAIL prefix=%.6f pitch=%.6f delta=%.6f phase=%.6f page=%.6f',
        prefix/bp,pitch/bp,device_delta/bp,phase/bp,items[last].nw/bp)
      if phase>pitch-tex.sp('.001pt') then phase=0 end
      local edge=math.max(0,phase)
      if leader.prev and leader.prev.id==GLUE then leader.prev.width=-edge end
      if leader.next and leader.next.id==GLUE then
        local ink=pitch
        for g in traverse(leader.leader.head) do
          if g.id==HLIST then ink=g.width; break end
        end
        
        leader.next.width=edge-math.max(0,pitch-ink)
      end
      for g in traverse(leader.leader.head) do
        if g.id==GLUE then g.width=phase; break end
      end
    end
    local packed=node.hpack(tail.head,goal,'exactly')
    tail.head=packed.head; packed.head=nil
    tail.width,tail.height,tail.depth=packed.width,packed.height,packed.depth
    tail.glue_set,tail.glue_sign,tail.glue_order=packed.glue_set,packed.glue_sign,packed.glue_order
    node.free(packed)
  end
  if line.hyphen_disc then
    local disc = line.hyphen_disc
    local replaced = disc.replace
    local soft = M.soft_hyphen_attr and node.get_attribute(disc,M.soft_hyphen_attr) == 1
    local hyphens, other = 0, false
    for g in traverse(disc.pre) do
      soft = soft or (M.soft_hyphen_attr and node.get_attribute(g,M.soft_hyphen_attr) == 1)
      if g.id == GLYPH then
        if g.char == 45 or g.char == 0x2010 then hyphens = hyphens+1 else other = true end
      end
    end
    soft = soft or (disc.subtype <= 1 and hyphens == 1 and not other)
    line.soft_hyphen = soft
    trace("OPTIONAL-HYPHEN rtl=%s soft=%s pardir=%s",tostring(P.rtl),tostring(soft),tostring(tex.pardir))
    if P.rtl and soft then
      
      local reserve = node.new(KERN)
      for g in traverse(disc.pre) do reserve.kern = reserve.kern + nodewidth(g) end
      disc.replace = reserve
    else
      disc.replace = node.copy_list(disc.pre)
      if items[last].native_disc then
        for g in traverse(disc.replace) do
          if g.id==GLYPH then
            local kn=node.new(KERN); kn.kern=P.latin_add+(fake_bold(g) or 0)
            disc.replace=node.insert_after(disc.replace,g,kn)
          end
        end
      end
    end
    if replaced then node.flush_list(replaced) end
  end
  head = tag_cluster_controls(head)
  if P.distributed and not hasfil then
    local units={}
    for k=first,last do
      local it=items[k]
      if it.kind==3 and it.glist and #it.glist>0 then
        for _,g in ipairs(it.glist) do
          local cluster=M.cluster_attr and node.get_attribute(g,M.cluster_attr)
          local previous=units[#units]
          if cluster and previous and previous.cluster==cluster then previous.anchor=g
          else units[#units+1]={anchor=g,cluster=cluster} end
        end
      elseif it.kind~=4 or (not it.user and it.core.width>0) then
        units[#units+1]={anchor=it.adj or it.core or it.last}
      end
    end
    local spare=math.max(0,measure-node.dimensions(head))
    if #units>1 then
      
      for k=first,last do
        local it=items[k]
        if spare>0 and it.kind==4 and not it.user and not it.rigid and k>first and k<last then
          local take=math.min(spare,it.nw*.5);it.core.width=it.core.width+take;spare=spare-take
        end
        if spare>0 and it.gapkern and it.gap>0 then
          local take=math.min(spare,it.gap);it.gapkern.kern=it.gapkern.kern+take;spare=spare-take
        end
      end
      local each=spare/(#units-1)
      for i=1,#units-1 do
        local kn=node.new(KERN);kn.kern=each
        head=node.insert_after(head,units[i].anchor,kn)
      end
    elseif #units==1 and spare>0 then
      local before=node.new(KERN);before.kern=spare/2;head=node.insert_before(head,head,before)
      local after=node.new(KERN);after.kern=spare/2;head=node.insert_after(head,node.tail(head),after)
    end
  end
  if geometry then
    geometry.allocated=geometry_snapshot(head,line.shift or 0)
    for k=first,last do
      geometry.items[k-first+1].compression_bp=delta[k]/bp
      geometry.items[k-first+1].stretch_bp=after[k]/bp
    end
    M._geometry_observer('allocated',geometry)
  end
  if not P.rtl and (hinted_latin and compat==15 or P.grid) then
    local shift,paint_font=0,nil
    for k=first,last do
      local it=items[k]
      if it.toc_tail then break end
      if it.kind==3 and device_latin_run(it) and not it.code and not raised(it) then
        for _,g in ipairs(it.glist) do
          if paint_font~=g.font then paint_font,shift=g.font,0 end
          g.xoffset=g.xoffset+shift
          local advance=device_advance(g)
          if advance then shift=shift+advance-g.width end
          shift=shift-(it.logical_grid_add or 0)
        end
      elseif it.kind~=4 then
        paint_font,shift=nil,0
      end
    end
    if hinted_latin and compat==15 then
      local position=0
      for g in traverse(head) do
        if g.id==GLYPH then g.xoffset=devtrunc(position+g.xoffset)-position end
        position=position+nodewidth(g)
      end
    end
  end
  if P.grid and not P.rtl then
    
    local extra=P.char_grid_extra or 0
    local tracking=(P.balance and devround(extra) or devtrunc(extra))-extra
    local run_font,shift=nil,0
    for k=first,last do
      local it=items[k]
      local glyph=it.core
      if glyph and glyph.id==HLIST then
        glyph=glyph.head
        while glyph and glyph.id~=GLYPH do glyph=glyph.next end
      end
      if it.kind<=2 and not it.symbol and glyph and glyph.id==GLYPH and not raised(it) then
        if run_font~=glyph.font then run_font,shift=glyph.font,0 end
        glyph.xoffset=glyph.xoffset+shift
        shift=shift+tracking
      else
        run_font,shift=nil,0
      end
    end
  end
  if P.nogrid and P.balance and P.cjk_compress==false and P.justify and not P.rtl and not P.toc then
    local expanding=false
    for k=first,last do if items[k].kind<=2 and after[k]>0 then expanding=true;break end end
    if expanding then
      local selected={}
      local nearest=false
      local function select_text(n)
        if n and n.id==GLYPH then
          local f=font.getfont(n.font)
          if f and f.format=='truetype' then selected[node.direct.todirect(n)]=nearest and 2 or 1 end
        elseif n and n.id==HLIST and is_packed(n) then
          for child in traverse(n.head) do select_text(child) end
        end
      end
      for k=first,last do
        local it=items[k]
        
        
        
        
        
        if compat==15 and it.kind==4 and it.rigid and not it.user and not it.boundary then nearest=true end
        if it.kind<=2 and not it.symbol and not raised(it) then select_text(it.core)
        elseif it.kind==3 and device_latin_run(it) and not it.code and not raised(it) then
          for _,g in ipairs(it.glist) do select_text(g) end
        end
      end
      local pixel=.12*bp
      local function place(list,position)
        for g in traverse(list) do
          if selected[node.direct.todirect(g)] then
            local x=position+g.xoffset
            g.xoffset=(selected[node.direct.todirect(g)]==2 and math.floor(x/pixel+.5)
              or math.ceil((x-1)/pixel))*pixel-position
          elseif g.id==HLIST and is_packed(g) then place(g.head,position) end
          position=position+nodewidth(g)
        end
      end
      place(head,line.shift or 0)
    end
  end
  local box = node.hpack(head, measure, "exactly")
  for glyph in traverse_id(GLYPH,box.list) do
    local data = font.getfont(glyph.font)
    if data and data.hb then box.subtype = 1; break end
  end
  box.shift = line.shift
  if M.trace then
    local dw = node.dimensions(box.list)
    if math.abs(dw - measure) > P.eps and not line.forced and not ragged then
      trace("WIDTH content=%.2f measure=%.2f natural=%.2f compressed=%.2f slack=%.2f", dw / bp, measure / bp, natural_w / bp, compressed / bp, (target - (natural_w + compressed)) / bp)
    end
  end
  if ctx then
    linebox(box, ctx, strut_h, strut_d)
  else
    
    if box.height < strut_h then box.height = strut_h end
    if box.depth < strut_d then box.depth = strut_d end
  end
  
  local properties=node.getproperty(box) or {}
  properties.docxlike_device_fonts=true
  properties.docxlike_latin_device_fonts=P.nogrid and not P.rtl and not P.toc and not P.distributed
  properties.docxlike_latin_device_allocate=P.align~='justify' or hinted_latin and compat==15
  properties.docxlike_latin_device_single_gap=P.align=='justify' and not line.hyphen_disc
  properties.docxlike_latin_device_word_widths=P.align=='justify' and compat==15 and not ragged and not P.balance and not line.forced and not hasfil and not P.rtl
  properties.docxlike_latin_device_normalize=P.align~='justify' and compat==15 and not P.balance and not P.rtl
  if geometry then properties.docxlike_geometry_trace=geometry end
  node.setproperty(box,properties)
  local moved, pre = move_out(box)
  return box, moved, nxt, pre
end

local function skip(why)
  trace("SKIP %s", why)
  return true
end


getbool = function(name)
  local ok, t = pcall(token.create, name)
  if not ok or not t or t.cmdname ~= "char_given" then return nil end
  return t.mode ~= 0
end
local function getfactor(name)
  local ok, v = pcall(token.get_macro, name)
  if not ok or not v then return nil end
  return tonumber(v)
end
function M.linectx(strut_h, strut_d)
  local exact = getbool("l_docxlike_format_strut_exact_bool")
  local snap = getbool("l_docxlike_format_line_snap_bool")
  local latin = getbool("l_docxlike_format_strut_latin_bool")
  if exact == nil or snap == nil then return nil end
  local ok, natpara = pcall(tex.getdimen, "l__docxlike_format_nat_dim")
  if not ok or not natpara or natpara <= 0 then return nil end
  local nat_cjk = getfactor("l__docxlike_format_strut_natural_tl") or 1.296875
  local nat_latin = getfactor("l_docxlike_format_natural_latin_tl") or 1.1499
  local asc_cjk = getfactor("l_docxlike_format_ascent_tl") or 1.0078125
  local asc_latin = getfactor("l_docxlike_format_ascent_latin_tl") or 0.93359375
  local ok3, pitch = pcall(tex.getdimen, "g_docxlike_page_lead_dim")
  if not ok3 or not pitch then pitch = 0 end
  local bls = tex.baselineskip.width
  local total = strut_h + strut_d
  local asc_para = strut_h
  if not exact and snap then asc_para = strut_h - (total - natpara) / 2 end
  local k = bls / natpara
  if k < 1 then k = 1 end
  local rule = token.get_macro('l_docxlike_format_line_unit_tl')
  local minimum = rule == 'atLeast' and bls or nil
  if minimum then
    k = 1
    
    
    
    if not exact and not snap then asc_para = strut_h - math.max(0, total - natpara) end
  end
  return { exact = exact, snap = snap, latin = latin, natpara = natpara, asc_para = asc_para,
           mono = getbool("g__docxlike_mono_scale_bool") == true,
           nat_cjk = nat_cjk, nat_latin = nat_latin, asc_cjk = asc_cjk, asc_latin = asc_latin,
            pitch = pitch, bls = bls, k = k, minimum = minimum }
end

function M.shape()
  local hsize = tex.hsize
  local rtl = tex.pardir == "TRT"
  local ls, rs = tex.getskip("leftskip"), tex.getskip("rightskip")
  local lw, rw = ls.width, rs.width
  
  
  local okS, slack = pcall(tex.getdimen, "g_docxlike_page_slack_dim")
  local okR, rsl = pcall(tex.getdimen, "l_docxlike_format_right_slack_dim")
  local okT, rtot = pcall(tex.getdimen, "l_docxlike_format_right_total_dim")
  local toc=getbool('l__docxlike_toc_word_par_bool')==true
  if not toc and okR and okT and rsl and rtot and rw > 0 and math.abs(rw - rtot) <= 2 and rw >= rsl then
    rw = rw - rsl
    if rw <= 2 then rw = 0 end
  
  elseif not toc
      and rw > 0 and (rw <= 6 * 65536 or (okS and slack and math.abs(rw - slack) <= 2)) then
    rw = 0
  end
  local ps = tex.parshape
  local hi, ha = tex.hangindent, tex.hangafter
  return function(li)
    local ind, wd = 0, hsize
    if type(ps) == "table" and #ps > 0 then
      local e = ps[math.min(li, #ps)]
      ind, wd = e[1], e[2]
    elseif hi ~= 0 then
      local hang = (ha >= 0 and li > ha) or (ha < 0 and li <= -ha)
      if hang then
        if hi > 0 then ind, wd = hi, hsize - hi else wd = hsize + hi end
      end
    end
    return { width = wd - lw - rw, shift = rtl and (hsize - ind - wd + rw) or (ind + lw) }
  end
end


local function code_right_limit()
  local width = tex.hsize
  trace("CODE context nest=%d hsize=%.2f textwidth=%.2f list=%d", tex.nest.ptr,
    width / 65781.76, tex.getdimen("textwidth") / 65781.76, tex.getcount("@listdepth"))
  if tex.nest.ptr ~= 0 or M.cell or tex.getcount("@listdepth") > 0
      or math.abs(width - tex.getdimen("textwidth")) > 2 then return nil end
  local left = tex.getdimen("oddsidemargin")
  if token.create("if@twoside").mode == token.create("iftrue").mode then
    left = math.max(left, tex.getdimen("evensidemargin"))
  end
  left = left + tex.getdimen("hoffset") + tex.sp("1in")
  local available = tex.getdimen("paperwidth") - left
  local inset = tex.getdimen("l__docxlike_code_overhang_page_inset_dim")
  if getbool("l__docxlike_code_overhang_relative_bool") then
    inset = math.max(0, available - tex.getdimen("textwidth"))
      * getfactor("l__docxlike_code_overhang_ratio_tl")
  end
  return math.max(0, available - inset)
end



local function align_of(ls, rs)
  if ls.stretch == 0 and rs.stretch == 0 and ls.shrink == 0 and rs.shrink == 0 then
    return "justify"
  elseif ls.stretch ~= 0 and rs.stretch ~= 0 then
    return "center"
  elseif ls.stretch ~= 0 then
    return "right"
  end
  return "left"
end





local function latin_adds(inc, hsnap, nogrid)
  local pre = "l_docxlike_format_par_"
  local balance = getbool("g_docxlike_format_balance_bool") ~= false
  local okS, spacing = pcall(tex.getdimen, pre .. "char_spacing_dim")
  if not okS or not spacing then spacing = 0 end
  local ari = getbool(pre .. "adjust_right_bool") ~= false
  local lsnap = getbool("l_docxlike_format_line_snap_bool")
  local whole = (ari or lsnap) and hsnap and not nogrid and not M.cell
  local half_inc = whole and devround(inc / 2) or inc / 2
  local full_inc = whole and devtrunc(inc) or inc
  local latin_add = (hsnap and (balance and half_inc or full_inc) or 0) + spacing
  local space_add = (whole and (balance and half_inc or full_inc) or ((inc > 0) and 0.25 * 65781.76 or 0)) + spacing
  return { latin = latin_add, space = space_add, ari = ari, balance = balance, spacing = spacing }
end




local function done(n)
  return M.done_attr and node.get_attribute(n, M.done_attr) == 1
end
local function mark_done(n)
  if M.done_attr then node.set_attribute(n, M.done_attr, 1) end
end

local function grid_latin(head, only_attr)
  fold_lastskip(head)
  local ok, cell = pcall(tex.getdimen, "g_docxlike_page_char_dim")
  local ok2, body = pcall(tex.getdimen, "g_docxlike_body_size_dim")
  if not ok2 or not body or body <= 0 then return end
  local snap = ok and cell and cell ~= 0
    and getbool("l_docxlike_format_par_snap_horizontal_bool") ~= false
  local inc = snap and cell - body or 0
  local a = latin_adds(inc, snap, not snap)
  local sp2 = a.balance and 2 * a.spacing or a.spacing
  local function half(fid) return (fsize(fid) + inc) / 2 + sp2 end
  
  local function transparent(x)
    return x.id == KERN or x.id == PENALTY or x.id == WHATSIT or x.id == MARK or x.id == INS or x.id == ADJUST
      or (x.id == RULE and x.width == 0)
      or ((x.id == HLIST or x.id == VLIST) and invisible_box(x))
      or (x.id == GLUE and x.subtype == 0 and math.abs(x.width) <= SP_NOISE and x.stretch == 0 and x.shrink == 0)
  end
  local function is_space(x)
    return x and x.id == GLUE and (x.subtype == 13 or x.subtype == 14)
  end
  
  local function cjk_tail(g)
    if g and inc + sp2 ~= 0 then
      local kn = node.new(KERN); kn.kern = inc + sp2
      node.insert_after(head, g, kn)
    end
  end
  local inmath, lastg, cjkg, widep, spacep = false, nil, nil, false, false
  for n in traverse(head) do
    local id = n.id
    if id == GLYPH and (done(n) or (only_attr and node.get_attribute(n, only_attr) ~= 1)) then
      lastg, cjkg, widep, spacep = nil, nil, true, false
    elseif id == MATH then
      inmath = n.subtype == 0
      lastg, cjkg, widep, spacep = nil, nil, not inmath, false
    elseif not inmath then
      if id == GLYPH and not is_jfont(n.font) then
        if a.latin ~= 0 and not (M.code_attr and (node.get_attribute(n, M.code_attr) or 0) ~= 0) then
          local kn = node.new(KERN); kn.kern = a.latin
          node.insert_after(head, n, kn)
        end
        mark_done(n)
        lastg, cjkg, widep, spacep = n, nil, false, false
      elseif id == GLYPH then
        mark_done(n)
        lastg, cjkg, widep, spacep = nil, n, true, false
      elseif (id == HLIST or id == VLIST) and not invisible_box(n) then
        lastg, cjkg, widep, spacep = nil, nil, true, false
      elseif id == GLUE and is_jfmglue(n) then
        
        local p, q = n.prev, n.next
        while p and (p.id == PENALTY or (p.id == RULE and p.width == 0)) do p = p.prev end
        while q and (q.id == PENALTY or (q.id == RULE and q.width == 0)) do q = q.next end
        local function ks(x) return x and x.id == GLUE and (is_kanjiskip(x) or is_xkanjiskip(x)) end
        local after_char = p and ((p.id == GLYPH and is_jfont(p.font))
          or (p.id == HLIST and p.subtype ~= 3 and p.width > 0))
        if inc + sp2 ~= 0 and after_char and not ks(p) and not ks(q) and q
            and (q.id == GLYPH or q.id == HLIST) then
          local kn = node.new(KERN); kn.kern = inc + sp2
          node.insert_after(head, n, kn)
        end
        lastg, cjkg, spacep = nil, nil, false
      elseif id == GLUE and (is_space(n)
          or (n.subtype == 0 and n.width > SP_NOISE and not is_kanjiskip(n) and not is_xkanjiskip(n))) then
        if cjkg and inc + sp2 ~= 0 then
          local kn = node.new(KERN); kn.kern = inc + sp2
          node.insert_after(head, cjkg, kn)
        end
        if n.subtype ~= 0 then
          local nx = n.next
          while nx and transparent(nx) do nx = nx.next end
          local wide_next = nx and ((nx.id == GLYPH and is_jfont(nx.font)) or nx.id == HLIST
            or nx.id == VLIST or (nx.id == MATH and nx.subtype == 0))
          if a.balance and (widep or wide_next or spacep or is_space(nx)) then
            local ref = (cjkg and cjkg.font) or (nx and nx.id == GLYPH and nx.font) or font.current()
            n.width = half(ref)
          elseif not (widep or wide_next) then
            local sf = M.spacefont_attr and node.get_attribute(n, M.spacefont_attr)
            if not sf or sf <= 0 then sf = lastg and lastg.font end
            local w = sf and fspace(sf) or 0
            if w > 0 then
              n.width = w
              if kern_enabled(n) then
                if lastg and lastg.font == sf then
                  n.width = n.width + pair_kern(sf, lastg.char, 32)
                end
                if nx and nx.id == GLYPH and nx.font == sf then
                  n.width = n.width + pair_kern(sf, 32, nx.char)
                end
              end
            end
            n.width = n.width + a.space
          end
          spacep = true
        else
          spacep = false
        end
        lastg, cjkg, widep = nil, nil, false
      elseif id == GLUE and (n.subtype == 15 or n.subtype >= 100 or n.stretch_order > 0) then
        cjk_tail(cjkg)
        lastg, cjkg, widep, spacep = nil, nil, false, false
      elseif not transparent(n) then
        lastg, cjkg, widep, spacep = nil, nil, false, false
      end
    end
  end
  cjk_tail(cjkg)
end


local function grid_box(head)
  if not M.cell_attr then return end
  local any = false
  for g in node.traverse_id(GLYPH, head) do
    if node.get_attribute(g, M.cell_attr) == 1 and not done(g) then any = true; break end
  end
  if not any then return end
  local saved = M.cell
  M.cell = true
  head = legacy_kern(head)
  grid_latin(head, M.cell_attr)
  M.cell = saved
end

local function to_tex(head, why)
  if why ~= "attr" and getbool("g__docxlike_linebreak_rigid_bool") then
    for g in node.traverse_id(GLUE, head) do
      if g.shrink_order == 0 then g.shrink = 0 end
    end
  end
  if why == "skips" then
    head = legacy_kern(head)
    grid_latin(head)
  end
  return skip(why)
end





local function snap_nosnap(it)
  local a = M.nosnap_attr
  if not a then return false end
  local g = it.first
  while g do
    if g.id == GLYPH or g.id == GLUE or g.id == HLIST or g.id == MATH then
      local v = node.get_attribute(g, a)
      return v ~= nil and v > 0
    end
    if g == it.last then break end
    g = g.next
  end
  return false
end
local function snap_units(items)
  local units = {}
  local k, n = 1, #items
  while k <= n do
    if snap_nosnap(items[k]) then
      local j = k
      while j + 1 <= n and snap_nosnap(items[j + 1]) do j = j + 1 end
      units[#units + 1] = { cjk = false, nosnap = true, from = k, to = j }
      k = j + 1
    elseif items[k].kind <= 2 then
      units[#units + 1] = { cjk = true, from = k, to = k }
      k = k + 1
    else
      local j = k
      while j + 1 <= n and items[j + 1].kind >= 3 do j = j + 1 end
      units[#units + 1] = { cjk = false, from = k, to = j }
      k = j + 1
    end
  end
  return units
end
local function snap_space_w(items, k, P)
  local it = items[k]
  if it.user then return it.w end
  local pv = items[k - 1]
  if P.balance and pv and pv.kind <= 2 then return (it.size or tex.sp("1em")) / 2 end
  return it.w
end

local function snap_item_w(it)
  if it.kind == 3 and it.glist then
    local w = it.kw or 0
    for _, g in ipairs(it.glist) do w = w + devtrunc(g.width) end
    return w
  end
  return it.w or 0
end
local function snap_latin_w(items, a, b, P)
  local w = 0
  for k = a, b do
    if items[k].kind == 4 then w = w + devtrunc(snap_space_w(items, k, P)) else w = w + snap_item_w(items[k]) end
  end
  return w
end

local function snap_nosnap_gap(items, k)
  local a, b = items[k - 1], items[k]
  if not a or not b then return 0 end
  if (a.kind == 0 and not a.symbol and b.kind == 3 and b.glyphs and is_alnum(b.head))
    or (a.kind == 3 and a.glyphs and is_alnum(a.tail) and b.kind == 0 and not b.symbol) then
    return (a.size or 0) / 4
  end
  return 0
end
local function snap_natural_w(items, a, b)
  local w = 0
  for k = a, b do
    local it = items[k]
    w = w + ((it.kind == 3) and snap_item_w(it) or (it.w or 0))
    if k > a then w = w + snap_nosnap_gap(items, k) end
  end
  return w
end
local function snap_forced(items, k)
  local it = items[k]
  local g = it.first
  while g do
    if g.id == PENALTY and g.penalty <= -10000 then return true end
    if g == it.last then break end
    g = g.next
  end
  return false
end
local function snap_decide(items, P, shape, indent)
  local cell, eps = P.cell0, P.eps
  local units = snap_units(items)
  local function cells_of(w) return math.max(1, math.ceil((w - eps) / cell)) end
  local function starts_bad(ui, ustart)
    local u = units[ui]
    if not u then return false end
    local it = items[ustart or u.from]
    return it.kind == 1 or (it.kind == 3 and it.glyphs and no_line_start[it.head]) or false
  end
  
  local lead_w = 0
  if items[1] then
    local g = items[1].first
    while g and g.id ~= GLYPH and g.id ~= HLIST and g.id ~= GLUE and g.id ~= MATH do
      if g.id == KERN then lead_w = lead_w + g.kern end
      if g == items[1].last then break end
      g = g.next
    end
  end
  local lines = {}
  local ui, ustart = 1, nil
  while ui <= #units do
    local li = #lines + 1
    local from = ustart or units[ui].from
    local last = from
    while last < units[ui].to and items[last + 1].kind ~= 4 do last = last + 1 end
    local needed = not units[ui].cjk and not units[ui].nosnap
      and cells_of(snap_latin_w(items, from, last, P)) * cell or 0
    local sh = shape(li, needed + (li == 1 and math.max(0, indent + lead_w) or 0))
    local isfirst = (li == 1)
    local cap = math.floor((sh.width - (isfirst and (indent + lead_w) or 0) + eps) / cell)
    local used, parts, forced = 0, {}, false
    while ui <= #units do
      local u = units[ui]
      local from = ustart or u.from
      if u.cjk then
        if used + 1 > cap and #parts > 0 then break end
        parts[#parts + 1] = { ui = ui, from = from, to = u.to, cells = 1, cjk = true }
        used = used + 1; ui = ui + 1; ustart = nil
      elseif u.nosnap then
        local c = cells_of(snap_natural_w(items, from, u.to))
        if used + c > cap and #parts > 0 then break end
        parts[#parts + 1] = { ui = ui, from = from, to = u.to, cells = c, nosnap = true }
        used = used + c; ui = ui + 1; ustart = nil
      else
        local c = cells_of(snap_latin_w(items, from, u.to, P))
        if used + c <= cap then
          parts[#parts + 1] = { ui = ui, from = from, to = u.to, cells = c }
          used = used + c; ui = ui + 1; ustart = nil
        else
          local best, bestc = nil, nil
          for s = u.to - 1, from + 1, -1 do
            if items[s].kind == 4 then
              local cs = cells_of(snap_latin_w(items, from, s, P))
              if used + cs <= cap then best, bestc = s, cs; break end
            end
          end
          if not best and #parts == 0 then
            best = from
            while best < u.to and items[best + 1].kind ~= 4 do best = best + 1 end
            if best < u.to then best = best + 1 end
            bestc = cells_of(snap_latin_w(items, from, best, P))
          end
          if not best then break end
          local nx = best + 1
          while nx <= u.to and items[nx].kind == 4 and not items[nx].user do nx = nx + 1 end
          parts[#parts + 1] = { ui = ui, from = from, to = nx - 1, wto = best, cells = bestc,
                                split = true }
          used = used + bestc
          if nx > u.to then ui = ui + 1; ustart = nil else ustart = nx end
          break
        end
      end
      if snap_forced(items, parts[#parts].to) then forced = true; break end
    end
    if not forced and ui <= #units then
      local guard = 0
      while #parts > 1 and guard < 3
        and (starts_bad(ui, ustart) or (parts[#parts].cjk and items[parts[#parts].from].kind == 2)) do
        local pt = table.remove(parts)
        ui = pt.ui
        ustart = (pt.from ~= units[pt.ui].from) and pt.from or nil
        guard = guard + 1
      end
    end
    lines[#lines + 1] = { first = parts[1].from, last = parts[#parts].to, parts = parts,
                           measure = sh.width, capacity = sh.width, shift = sh.shift, isfirst = isfirst,
                           forced = forced, width = 0, over = 0,
                           wrap_row = sh.wrap_row, wrap_skip = sh.wrap_skip }
    if P.wrap_next then P.wrap_next(lines[#lines], forced) end
    if M.trace then
      local txt, c = {}, 0
      for _, pt in ipairs(parts) do
        c = c + pt.cells
        for k = pt.from, pt.to do
          local it = items[k]
          txt[#txt + 1] = it.c and trace_char(it.c) or (it.kind == 4 and "_" or "[" .. (it.head and trace_char(it.head) or "?") .. "]")
        end
      end
      trace("SNAPLINE cells=%d/%d %s", c, cap, table.concat(txt))
    end
  end
  if #lines > 0 then lines[#lines].islast = true end
  return lines
end
local function snap_render(items, line, P, strut_h, strut_d, indent, isfirst, ctx)
  local cell = P.cell0
  local measure = line.measure
  local head = items[line.first].first
  local stop = items[line.last].last
  local nxt = stop.next
  if nxt then stop.next = nil; nxt.prev = nil end
  head.prev = nil
  for _, pt in ipairs(line.parts) do
    if pt.nosnap then pt.natural = snap_natural_w(items, pt.from, pt.to) end
  end
  for g in traverse(head) do
    if g.id == GLUE then
      if g.stretch_order == 0 then g.width = 0; g.stretch = 0; g.shrink = 0 else g.shrink = 0 end
    elseif g.id == DISC and g.replace then
      for r in traverse(g.replace) do if r.id == KERN and r.subtype == 0 then r.kern = 0 end end
    end
  end
  local function kern(w) local kn = node.new(KERN); kn.kern = w; return kn end
  for _, pt in ipairs(line.parts) do
    if pt.nosnap then
      for k = pt.from, pt.to do
        local it = items[k]
        if it.kind == 4 then
          it.core.width = it.w
        elseif it.kind == 3 and it.kerns then
          for _, e in ipairs(it.kerns) do e[1].kern = e[2] end
          for _, g in ipairs(it.glist or {}) do
            local d = devtrunc(g.width) - g.width
            if d ~= 0 then node.insert_after(head, g, kern(d)) end
          end
        end
        local g = (k > pt.from) and snap_nosnap_gap(items, k) or 0
        if g > 0 then head = node.insert_before(head, it.first, kern(g)) end
      end
      local pre = (pt.cells * cell - pt.natural) / 2
      head = node.insert_before(head, items[pt.from].first, kern(pre))
      node.insert_after(head, items[pt.to].last, kern(pt.cells * cell - pt.natural - pre))
    elseif pt.cjk then
      local it = items[pt.from]
      local core = it.first
      while core and core.id ~= GLYPH and core.id ~= HLIST and core ~= it.last do core = core.next end
      if core then
        local cw = core.width
        local em = it.symbol and it.w or ((it.kind == 0) and cw or it.size)
        local pre = (cell - em) / 2
        if it.kind == 2 and not it.symbol then pre = pre + (em - cw) end
        head = node.insert_before(head, core, kern(pre))
        node.insert_after(head, core, kern(cell - pre - cw))
      end
    else
      local wto = pt.wto or pt.to
      for k = pt.from, pt.to do
        local it = items[k]
        if it.kind == 4 then
          it.core.width = (k <= wto) and devtrunc(snap_space_w(items, k, P)) or 0
        elseif it.kind == 3 and it.kerns then
          for _, e in ipairs(it.kerns) do e[1].kern = e[2] end
          for _, g in ipairs(it.glist or {}) do
            local d = devtrunc(g.width) - g.width
            if d ~= 0 then node.insert_after(head, g, kern(d)) end
          end
        end
      end
      local w = snap_latin_w(items, pt.from, wto, P)
      local pre = (pt.cells * cell - w) / 2
      if pt.split and pt == line.parts[1] then pre = 0 end
      head = node.insert_before(head, items[pt.from].first, kern(pre))
      node.insert_after(head, items[pt.to].last, kern(pt.cells * cell - w - pre))
    end
  end
  local fil = node.new(GLUE); fil.stretch = 65536; fil.stretch_order = 2
  node.insert_after(head, node.tail(head), fil)
  if isfirst and indent ~= 0 then
    local ib = node.new(HLIST); ib.subtype = 3; ib.width = indent
    ib.next = head; head.prev = ib; head = ib
  end
  local box = node.hpack(head, measure, "exactly")
  box.shift = line.shift
  if ctx then
    linebox(box, ctx, strut_h, strut_d)
  else
    if box.height < strut_h then box.height = strut_h end
    if box.depth < strut_d then box.depth = strut_d end
  end
  local moved, pre = move_out(box)
  return box, moved, nxt, pre
end



local function shade_line(box, color, first, ctx, measure, P)
  local runm = docxlike and docxlike.run
  local data = runm and runm.colors and runm.colors[color]
  if not data then return end
  local area = measure
  if M.compat < 15 and P.ari and not P.nogrid and M.grid_on and not P.table_cell
      and P.cell0 and P.cell0 > 0 then
    area = math.floor(measure / P.cell0 + 1e-6) * P.cell0
  end
  local ext = math.floor(1.5 * P.bp + 0.5)
  local up = box.height
  if first and not ctx.exact and M.last_text_ascent and M.last_text_ascent > 0 then
    up = math.min(box.height, M.last_text_ascent)
  end
  local function cs(cmd, d)
    local w = node.new(WHATSIT, "pdf_colorstack"); w.stack = 0; w.command = cmd
    if d then w.data = d end
    return w
  end
  local r = node.new(RULE)
  r.width, r.height, r.depth = area + 2 * ext, math.floor(up + 0.5), box.depth
  local k1, k2 = node.new(KERN), node.new(KERN)
  k1.kern = -ext; k2.kern = -(area + ext)
  local h = box.head
  h = node.insert_before(h, h, k2)
  h = node.insert_before(h, h, cs(2))
  h = node.insert_before(h, h, r)
  h = node.insert_before(h, h, cs(1, data))
  h = node.insert_before(h, h, k1)
  box.head = h
end



function M.wrap_init()
  local directory = ""
  for i, value in ipairs(arg or {}) do
    local path = value:match("^%-%-?output%-directory=(.*)$")
    if value == "-output-directory" or value == "--output-directory" then path = arg[i + 1] end
    if path then directory = path .. "/" end
  end
  M.wrap_path = directory .. tex.jobname .. ".docxlike-wrap"
  M.wrap_old, M.wrap_new, M.wrap_objects, M.wrap_pending = {}, {}, {}, {}
  M.wrap_page, M.wrap_par = 0, 0
  local file = io.open(M.wrap_path, "r")
  if file then
    for line in file:lines() do
      local key, page, x, y, height, skipped = line:match("^([fp][%d:]+) (%d+) (%-?%d+) (%-?%d+) (%-?%d+)%s*(%d*)$")
      if key then M.wrap_old[key] = {tonumber(page), tonumber(x), tonumber(y), tonumber(height), tonumber(skipped) or 0} end
    end
    file:close()
  end
end

function M.wrap_add(id, object)
  
  if object.wrap == "around" and (M.compat or 15) < 15 then
    object.top, object.bottom = 0, 0
    object.legacy_frame_block = object.xalign == "center"
  end
  M.wrap_objects[id] = object
  M.wrap_pending[#M.wrap_pending + 1] = id
end

function M.wrap_record(key, height, shift)
  local x, y = pdf.getpos()
  M.wrap_new[key] = {M.wrap_page, math.floor(x - (shift or 0) + .5),
    math.floor(tex.getdimen("paperheight") - y - (height or 0) + .5), height or 0}
end

function M.wrap_offsets(id)
  local object = M.wrap_objects[id]
  local anchor = M.wrap_old["f" .. id]
  local x, y = object.x, object.y
  if anchor then
    if object.xrel == "page" then
      x = object.x + object.page_left - anchor[2]
    end
    if object.yrel == "page" then y = object.y - anchor[3]
    elseif object.yrel == "margin" then y = object.y + object.page_top - anchor[3] end
  end
  return x, y
end

function M.wrap_place(id)
  local x, y = M.wrap_offsets(id)
  tex.setdimen("l__docxlike_shape_x_dim", math.floor(x + .5))
  tex.setdimen("l__docxlike_frame_y_dim", math.floor(y + .5))
end

function M.wrap_begin(is_display)
  if tex.nest.ptr ~= 0 or not next(M.wrap_objects) then return nil end
  if is_display or getbool("g__docxlike_cols_open_bool") or M.cell then
    tex.error("docxlike rectangular wrapping requires single-column body paragraphs",
      {"Display math, columns and table-cell floats are not supported."})
    return nil
  end
  M.wrap_par = M.wrap_par + 1
  local pending = M.wrap_pending
  M.wrap_pending = {}
  local full = tex.getdimen("textheight")
  local goal = math.min(tex.pagegoal, full)
  local room = goal - tex.pagetotal - tex.pagedepth
  local must_break = false
  for _, id in ipairs(pending) do
    local object = M.wrap_objects[id]
    object.par = M.wrap_par
    if object.yrel == "paragraph" then
      local extent = object.y + object.h + object.bottom
      if extent > full then
        tex.error("docxlike floating rectangle exceeds the text-area height",
          {"Reduce the object height or use an inline object."})
      elseif (M.compat or 15) >= 15 and extent > room + 2 and tex.pagetotal > 0 then must_break = true end
    end
  end
  return {id = M.wrap_par, must_break = must_break}
end

function M.wrap_shape(base, paragraph, height, indent)
  if not paragraph then return base end
  local row, part, slots, current, previous = 1, 1, nil, nil, nil
  local page_top = tex.sp("1in") + tex.getdimen("voffset") + tex.getdimen("topmargin")
                   + tex.getdimen("headheight") + tex.getdimen("headsep")
  local full = tex.getdimen("textheight")
  
  local minimum = tex.sp("18bp")
  local function build_row(needed)
    local shape = base(row)
    local old = M.wrap_old["p" .. paragraph.id .. ":" .. row]
    local position = old and {old[1], old[2], old[3] - old[5], old[4]} or nil
    if previous then
      local recorded_break = old and previous.old and old[1] ~= previous.old[1]
        and previous.page == previous.old[1] and math.abs(previous.actual_y - previous.old[3]) <= 2
        and math.abs(previous.height - previous.old[4]) <= 2
      if not recorded_break then
        position = {previous.page, old and old[2] or previous.x,
                    previous.actual_y + previous.height, old and old[4] or height}
        if position[3] + position[4] > page_top + full + 2 then
          position[1], position[3] = position[1] + 1, page_top
        end
      end
    end
    if not position then
      current = {old = old, skip = 0}
      return {{shift = shape.shift, width = shape.width, shortened = false}}
    end
    local hanging = row == 1 and math.min(0, indent) or 0
    local left, right = position[2] + shape.shift + hanging, position[2] + shape.shift + shape.width
    local natural_y, y = position[3], position[3]
    local intervals, split, clipped
    local required = math.max(minimum, math.min(needed or 0, right - left))
    while true do
      intervals, split, clipped = {{left, right}}, false, false
      local clear_to
      for id, object in pairs(M.wrap_objects) do
        local anchor = M.wrap_old["f" .. id]
        if anchor and anchor[1] == position[1] then
          local x, offset = M.wrap_offsets(id)
          local top, bottom = anchor[3] + offset - object.top, anchor[3] + offset + object.h + object.bottom
          if y < bottom - 2 and y + position[4] > top + 2 then
            local a, b = anchor[2] + x - object.left, anchor[2] + x + object.w + object.right
            if object.wrap == "top-and-bottom" or object.legacy_frame_block then a, b = left, right
            elseif object.side == "left-only" then b = right
            elseif object.side == "right-only" then a = left end
            if a < right and b > left then
              clear_to = math.min(clear_to or bottom, bottom)
              split = split or object.side == "both-sides"
              clipped = true
            end
            local remaining = {}
            for _, interval in ipairs(intervals) do
              if a >= interval[2] or b <= interval[1] then remaining[#remaining + 1] = interval
              else
                if a > interval[1] then remaining[#remaining + 1] = {interval[1], a} end
                if b < interval[2] then remaining[#remaining + 1] = {b, interval[2]} end
              end
            end
            intervals = remaining
          end
        end
      end
      local usable = {}
      for _, interval in ipairs(intervals) do
        if not clipped or interval[2] - interval[1] + 2 >= required then usable[#usable + 1] = interval end
      end
      intervals = usable
      if #intervals > 0 then break end
      if not clear_to or clear_to <= y then
        tex.error("docxlike wrapping has no usable paragraph width")
        intervals = {{left, right}}; break
      end
      y = clear_to
      if row == 1 and y - natural_y + position[4] > full + 2 then
        tex.error("docxlike rectangle and anchor line cannot fit on one text page",
          {"Reduce the object height or use an inline/page-sized object."})
        intervals = {{left, right}}; break
      end
    end
    if not split then
      local best = intervals[1]
      for _, interval in ipairs(intervals) do
        if interval[2] - interval[1] > best[2] - best[1] then best = interval end
      end
      intervals = {best}
    end
    current = {old = old, page = position[1], x = position[2], actual_y = y,
               height = position[4], skip = y - natural_y}
    local result = {}
    for index, interval in ipairs(intervals) do
      local compensation = index == 1 and hanging or 0
      result[#result + 1] = {shift = interval[1] - position[2] - compensation,
                            width = interval[2] - interval[1] + compensation,
                            available = interval[2] - interval[1], shortened = clipped}
    end
    return result
  end
  local function shape(_, needed)
    if not slots then slots = build_row(needed) end
  
    while slots[part].shortened and slots[part].available + 2 < (needed or 0) do
      part = part + 1
      if part > #slots then
        if current.page then previous = current end
        row, part = row + 1, 1
        slots = build_row(needed)
      end
    end
    local result = slots[part]
    result.wrap_row, result.wrap_skip = row, current.skip
    return result
  end
  local function advance(line, forced)
    if forced or line.forced_end or part == #slots then
      if current.page then previous = current end
      row, part, slots = row + 1, 1, nil
    else part = part + 1 end
  end
  return shape, advance
end

function M.wrap_mark_line(box, paragraph, li, skipped)
  if not paragraph then return end
  local properties = node.getproperty(box) or {}
  local height, total, shift = box.height, box.height + box.depth + (properties.docxlike_line_leading or 0), box.shift
  local marker = node.new(WHATSIT, "late_lua")
  marker.data = function()
    M.wrap_record("p" .. paragraph.id .. ":" .. li, height, shift)
    M.wrap_new["p" .. paragraph.id .. ":" .. li][4] = math.floor(total + .5)
    if skipped and skipped > 0 then M.wrap_new["p" .. paragraph.id .. ":" .. li][5] = math.floor(skipped + .5) end
  end
  box.head = node.insert_before(box.head, box.head, marker)
end

function M.wrap_finish()
  if not next(M.wrap_objects) then return end
  local keys, rows = {}, {}
  for key in pairs(M.wrap_new) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local p = M.wrap_new[key]
    rows[#rows + 1] = string.format("%s %.0f %.0f %.0f %.0f\n", key, p[1], p[2], p[3], p[4])
    if p[5] and p[5] > 0 then
      rows[#rows] = rows[#rows]:sub(1, -2) .. string.format(" %.0f\n", p[5])
    end
  end
  local file = io.open(M.wrap_path, "r")
  local old = file and file:read("*a") or ""
  if file then file:close() end
  local data = table.concat(rows)
  file = assert(io.open(M.wrap_path, "w"))
  file:write(data); file:close()
  if data ~= old then
    texio.write_nl("term and log", "LaTeX Warning: Rectangular positions changed. Rerun to get wrapping right.")
  end
end

M.after_display = false
local function previous_body_line()
  
  local function last_box(tail)
    if type(tail) == "number" then tail = node.direct.tonode(tail) end
    while tail do
      if tail.id == HLIST or tail.id == VLIST then return tail end
      tail = tail.prev
    end
  end
  local line = last_box(tex.nest.top.tail)
  if line or tex.nest.ptr ~= 0 then return line end
  local page = tex.lists.page_head
  if type(page) == "number" then page = node.direct.tonode(page) end
  return page and last_box(node.tail(page))
end
local function previous_body_leading()
  local line = previous_body_line()
  local p = line and node.getproperty(line) or {}
  return not p.docxlike_leading_consumed and p.docxlike_line_leading or 0
end
function M.native_boundary_state()
  if not M.native_append_base or getbool("g_docxlike_word_layout_bool") == false
      or getbool("g__docxlike_linebreak_word_bool") == false then return "inactive", 0, "" end
  local box = previous_body_line()
  if not box then return "empty", 0, "" end
  local properties = node.getproperty(box) or {}
  local word = properties.docxlike_line_leading ~= nil
  local leading = not properties.docxlike_leading_consumed and properties.docxlike_line_leading or 0
  return word and "word" or "native", leading, properties.docxlike_native_owner or ""
end
function M.native_boundary_mark(tag)
  if M.native_boundary_state() == "inactive" then return end
  local box = previous_body_line()
  if box then
    local properties = node.getproperty(box) or {}
    properties.docxlike_native_owner = tag
    node.setproperty(box, properties)
  end
end
local function consume_body_leading()
  local line = previous_body_line()
  if not line then return 0 end
  local p = node.getproperty(line) or {}
  if p.docxlike_leading_consumed then return 0 end
  local leading = p.docxlike_line_leading or 0
  if leading > 0 then
    p.docxlike_leading_consumed = true
    node.setproperty(line, p)
  end
  return leading
end
local function paragraph_boundary(head, leading)
  local first
  for line in traverse_id(HLIST, head) do
    local properties = node.getproperty(line)
    if line.subtype == 1 or properties and properties.docxlike_line_leading ~= nil then
      first = line; break
    end
  end
  if not first then return head end
  local properties = node.getproperty(first) or {}
  if properties.docxlike_boundary_done then return head end
  properties.docxlike_boundary_done = true
  node.setproperty(first, properties)
  if leading > 0 then
    local glue = node.new(GLUE)
    glue.width = leading
    head = node.insert_before(head, head, glue)
  end
  return head
end

function M.parmark_boundary()
  local leading = consume_body_leading()
  if leading > 0 then
    local glue = node.new(GLUE)
    glue.width = leading
    node.write(glue)
  end
end
local native_keep_boundary, flush_held_keep_note
local function install_native_boundary()
  if M.native_append_base then return end
  
  
  local name = "append_to_vlist_filter"
  local descriptions = luatexbase.callback_descriptions(name)
  if #descriptions ~= 1 then return end
  local description = descriptions[1]
  local base = luatexbase.remove_from_callback(name, description)
  M.native_append_base = {base, description}
  luatexbase.add_to_callback(name, function(box, location, prevdepth, mirrored)
    if docxlike and docxlike.page then docxlike.page.tag(box) end
    local leading = 0
    local word_blank = false
    if location == "box" and not getbool("l__docxlike_linebreak_output_bool") then
      local prior = previous_body_line()
      local p = prior and node.getproperty(prior) or {}
      word_blank = box.id == VLIST and prior and prior.id == HLIST
        and p.docxlike_para_last and p.docxlike_strut_only
      leading = consume_body_leading()
      trace("NATIVE ptr=%d leading=%.4f box=%.4f+%.4f", tex.nest.ptr,
        leading / 65536, box.height / 65536, box.depth / 65536)
    end
    local result, depth, check_depth = base(box, location, prevdepth, mirrored)
    if box.id == HLIST and box.subtype == 1
        and not getbool("l__docxlike_linebreak_output_bool") then
      local th, td = native_table_hd(box.list)
      local prior = previous_body_line()
      local ph, pd = 0, 0
      if prior and prior.id == HLIST then ph, pd = native_table_hd(prior.list) end
      if (th > 0 or td > 0 or ph > 0 or pd > 0) and result and result.id == GLUE
          and (result.subtype == 1 or result.subtype == 2) and result.width < 0 then
        result.width = 0
      end
    end
    if word_blank and result and result.id == GLUE and result.subtype == 1 then
      
      trace("NATIVE Word-blank fallback=%.4f -> 0", result.width / 65536)
      result.width, result.stretch, result.shrink = 0, 0, 0
    end
    if leading > 0 and result then
      local glue = node.new(GLUE)
      glue.width = leading
      result = node.insert_before(result, result, glue)
    end
    if location == "box" and not getbool("l__docxlike_linebreak_output_bool") then
      local p = node.getproperty(box) or {}
      if box.id == VLIST then
        result = flush_held_keep_note(result, box)
      elseif not (p.docxlike_para_last and p.docxlike_para_keep) then
        result = flush_held_keep_note(result)
      end
    end
    if location == "box" and box.id == VLIST
        and not getbool("l__docxlike_linebreak_output_bool") then
      result = native_keep_boundary(result, box)
    end
    if location == "box" and box.id == VLIST and not getbool("l__docxlike_linebreak_output_bool") then
      
      local last = box.list and node.tail(box.list)
      while last and last.id ~= HLIST and last.id ~= VLIST do last = last.prev end
      local p = last and node.getproperty(last) or {}
      if p.docxlike_line_leading and not p.docxlike_leading_consumed then
        local bp = {}
        for key, value in pairs(node.getproperty(box) or {}) do bp[key] = value end
        bp.docxlike_line_leading = p.docxlike_line_leading
        bp.docxlike_leading_consumed = nil
        if p.docxlike_para_last then
          bp.docxlike_block_last_keep = p.docxlike_para_keep == true
        elseif p.docxlike_block_last_keep ~= nil then
          bp.docxlike_block_last_keep = p.docxlike_block_last_keep
        end
        node.setproperty(box, bp)
      end
    end
    return result, depth, check_depth
  end, "docxlike.native-boundary")
end
function M.parmark_box(n, leading, keep)
  local box = tex.box[n]
  trace("PARMARK ptr=%d leading=%.4f box=%.4f+%.4f", tex.nest.ptr,
    leading / 65536, box.height / 65536, box.depth / 65536)
  local properties = node.getproperty(box) or {}
  properties.docxlike_line_leading = leading
  properties.docxlike_strut_only = true
  properties.docxlike_para_first, properties.docxlike_para_last = true, true
  properties.docxlike_para_keep = keep == 1
  local previous = previous_body_line()
  local prior = previous and node.getproperty(previous) or {}
  properties.docxlike_blank_keep_relaxed = (M.compat or 15) < 15 and keep == 1
    and prior.docxlike_keep_released and prior.docxlike_para_keep
  node.setproperty(box, properties)
end
function M.parmark_end()
  local line = previous_body_line()
  if line and (node.getproperty(line) or {}).docxlike_blank_keep_relaxed then
    local penalty = node.new(PENALTY)
    penalty.penalty = 0
    node.write(penalty)
  end
end
local function legacy_relaxed_blank(head)
  if (M.compat or 15) >= 15 or tex.nest.ptr ~= 0
      or not getbool("l__docxlike_format_keep_next_bool") then return head end
  local previous = previous_body_line()
  local prior = previous and node.getproperty(previous) or {}
  local incoming = prior.docxlike_keep_released and prior.docxlike_para_keep
  for line in traverse_id(HLIST, head) do
    for rule in traverse_id(RULE, line.list) do
      if (node.getproperty(rule) or {}).docxlike_incoming_keep_released then incoming = true end
    end
  end
  if not incoming then return head end
  local function has_content(list)
    for n in traverse(list) do
      if n.id == GLYPH and n.char ~= 32 then return true end
      if (n.id == HLIST or n.id == VLIST) and has_content(n.list) then return true end
      if n.id == RULE and n.width ~= 0 then return true end
    end
    return false
  end
  local count = 0
  for line in traverse_id(HLIST, head) do
    count = count + 1
    if has_content(line.list) then return head end
  end
  if count == 1 then
    local penalty = node.new(PENALTY)
    penalty.penalty = 0
    head = append_list(head, penalty)
  end
  return head
end
local function tag_paragraph(head)
  local lines = {}
  for line in traverse_id(HLIST, head) do
    local p = node.getproperty(line)
    if line.subtype == 1 or p and p.docxlike_line_leading ~= nil then
      lines[#lines + 1] = line
    end
  end
  for index, line in ipairs(lines) do
    local p = node.getproperty(line) or {}
    p.docxlike_para_first, p.docxlike_para_last = index == 1, index == #lines
    p.docxlike_para_keep = getbool("l__docxlike_format_keep_next_bool") == true
    p.docxlike_para_together = tex.interlinepenalty >= 10000
    for rule in traverse_id(RULE, line.list) do
      if (node.getproperty(rule) or {}).docxlike_strut_only then
        p.docxlike_strut_only = true; break
      end
    end
    node.setproperty(line, p)
  end
end
local function body_kept_height()
  local head = tex.lists.page_head
  if type(head) == "number" then head = node.direct.tonode(head) end
  local position, start, last_keep, chain = 0, 0, false, nil
  for n in traverse(head) do
    local p = node.getproperty(n)
    if n.id == HLIST and p and p.docxlike_para_first and not last_keep then
      start, chain = position, n
    end
    if n.id == HLIST or n.id == VLIST or n.id == RULE then position = position + n.height + n.depth
    elseif n.id == GLUE then position = position + n.width
    elseif n.id == KERN then position = position + n.kern end
    if n.id == HLIST and p and p.docxlike_para_last then last_keep = p.docxlike_para_keep end
    if n.id == VLIST and p and p.docxlike_block_last_keep ~= nil then
      last_keep = p.docxlike_block_last_keep
    end
  end
  if last_keep then return position - start, start, chain end
  return 0, position, nil
end
native_keep_boundary = function(head, box)
  
  
  if not head or tex.nest.ptr ~= 0 or M.cell
      or getbool("g__docxlike_cols_open_bool")
      or next(M.deferred_notes or {}) then return head end
  local full = tex.getdimen("textheight")
  if box.height + box.depth > full + 2 then return head end
  local height, start, chain = body_kept_height()
  if not chain or height <= 0 then return head end
  local added = 0
  for n in traverse(head) do
    if n.id == HLIST or n.id == VLIST or n.id == RULE then added = added + n.height + n.depth
    elseif n.id == GLUE then added = added + n.width
    elseif n.id == KERN then added = added + n.kern end
  end
  if height + added <= full + 2 then return head end
  local page = tex.lists.page_head
  if type(page) == "number" then page = node.direct.tonode(page) end
  for n in traverse(page) do if n.id == INS then return head end end
  for n in traverse(head) do if n.id == INS then return head end end
  local last = previous_body_line()
  if last then
    local p = node.getproperty(last) or {}
    p.docxlike_para_keep = false
    p.docxlike_native_keep_released = true
    node.setproperty(last, p)
  end
  local boundary = node.new(PENALTY)
  boundary.penalty = 0
  head = node.insert_before(head, head, boundary)
  local p = node.getproperty(chain) or {}
  if start > 2 and not p.docxlike_native_keep_retry and chain.prev then
    p.docxlike_native_keep_retry = true
    node.setproperty(chain, p)
    local before = chain.prev
    before.next, chain.prev = nil, nil
    tex.lists.page_head = page
    tex.pagetotal, tex.pagedepth = start, 0
    head = append_list(chain, head)
    local fresh = node.new(PENALTY)
    fresh.penalty = -10000
    head = node.insert_before(head, head, fresh)
  end
  trace("NATIVE keep release chain=%.4f block=%.4f full=%.4f", height / 65536, added / 65536, full / 65536)
  return head
end
M.deferred_notes = {}
function M.restore_note_limit()
  local limit = M.note_page_limit
  if limit then
    tex.setdimen("global", limit.index, limit.original)
    M.note_page_limit = nil
  end
end
flush_held_keep_note = function(head, box)
  local pending = M.held_keep_note
  if not pending or tex.nest.ptr ~= 0 then return head end
  if box and (M.cell or getbool("g__docxlike_cols_open_bool")) then box = nil end
  M.held_keep_note = nil
  local insertion = pending.insertion
  
  if box and not M.note_page_limit then
    local page = tex.lists.page_head
    if type(page) == "number" then page = node.direct.tonode(page) end
    local body, foreign = 0, false
    for n in traverse(page) do
      if n.id == INS then foreign = true end
      if n.id == HLIST or n.id == VLIST or n.id == RULE then body = body + n.height + n.depth
      elseif n.id == GLUE then body = body + n.width
      elseif n.id == KERN then body = body + n.kern end
    end
    for n in traverse(head) do
      if n.id == INS then foreign = true end
      if n.id == HLIST or n.id == VLIST or n.id == RULE then body = body + n.height + n.depth
      elseif n.id == GLUE then body = body + n.width
      elseif n.id == KERN then body = body + n.kern end
    end
    local index = insertion.subtype
    local room = tex.getdimen("textheight") - body - tex.getskip(index).width
    local original = tex.getdimen(index)
    if not foreign and tex.getcount(index) == 1000 and room + 2 >= pending.minimum
        and room < insertion.height - 2 and room < original then
      M.note_page_limit = {index = index, original = original}
      tex.setdimen("global", index, math.floor(room))
      trace("NOTE kept-body split budget=%.4f note=%.4f", room / 65536, insertion.height / 65536)
    end
  end
  if head then
    local prior = previous_body_line()
    if prior and (node.getproperty(prior) or {}).docxlike_para_keep then
      local keep = node.new(PENALTY)
      keep.penalty = 10000
      head = node.insert_before(head, head, keep)
    end
    return node.insert_before(head, head, insertion)
  end
  return insertion
end
function M.flush_held_keep_note()
  if M.held_keep_note and tex.nest.ptr == 0 then node.write(flush_held_keep_note(nil)) end
end
function M.note_separator_leading(index)
  local box = tex.box[index]
  if not box then return 0 end
  for n in traverse(box.list) do
    local p = node.getproperty(n)
    if n.id == GLUE and p and p.docxlike_note_story_reserve then
      return p.docxlike_note_story_reserve
    end
    if n.id == HLIST or n.id == VLIST then break end
  end
  return 0
end


function M.note_make_room(index, need, column)
  local held
  local head = tex.lists.page_head
  if type(head) == "number" then head = node.direct.tonode(head) end
  if head then
    for n in traverse_id(INS, head) do
      if n.subtype == index then held = n; break end
    end
  end
  local box = tex.box[index]
  if not held or not box or not box.list then return end
  local current = node.copy_list(tex.nest.top.head.next)
  local used = 0
  if current then
    local packed = node.vpack(current)
    used = packed.height + packed.depth
    node.flush_node(packed)
  end
  local free = column - used - box.height - box.depth
  
  
  local chunks, join = {}, nil
  while free < need do
    local line = node.tail(box.list)
    while line and line.id ~= HLIST do line = line.prev end
    if not line or (node.getproperty(line) or {}).docxlike_note_first_line ~= false then break end
    local before = line.prev
    while before and before.id ~= HLIST do before = before.prev end
    if not before then break end
    local chunk = before.next
    before.next, chunk.prev = nil, nil
    local packed = node.vpack(chunk)
    free = free + packed.height + packed.depth
    packed.list = nil
    node.free(packed)
    local dropped
    while chunk and (chunk.id == GLUE or chunk.id == KERN or chunk.id == PENALTY) do
      local following = chunk.next
      if following then following.prev = nil end
      chunk.next = nil
      if chunk.id == GLUE then
        free = free + chunk.width
        if dropped then node.free(dropped) end
        dropped = chunk
      else
        node.free(chunk)
      end
      chunk = following
    end
    if #chunks > 0 then
      
      local glue = join or node.new(GLUE)
      local tail = node.tail(chunk)
      tail.next, glue.prev = glue, tail
      glue.next, chunks[1].prev = chunks[1], glue
    end
    join = dropped
    table.insert(chunks, 1, chunk)
  end
  if #chunks == 0 then
    if join then node.free(join) end
    return
  end
  local moved = chunks[1]
  local first_moved
  for line in traverse_id(HLIST, moved) do first_moved = line; break end
  
  
  local list = held.list
  local top
  for n in traverse(list) do
    if n.id == HLIST or n.id == VLIST then break end
    if n.id == GLUE then top = n; break end
  end
  local first
  for line in traverse_id(HLIST, list) do first = line; break end
  local tail = node.tail(moved)
  if not join then join = node.new(GLUE) end
  tail.next, join.prev = join, tail
  if top then
    list = node.remove(list, top)
    top.width = top.width + (first and first.height or 0) - first_moved.height
    top.next, moved.prev = moved, top
    moved = top
  end
  join.next = list
  if list then list.prev = join end
  held.list = moved
  local packed = node.vpack(node.copy_list(held.list))
  held.height = packed.height + packed.depth
  node.flush_node(packed)
  local repacked = node.vpack(box.list)
  repacked.width = box.width
  box.list = nil
  
  
  tex.setbox("global", index, repacked)
end


function M.note_columns(index, n, sep)
  local box = tex.box[index]
  if not box or not box.list or n < 2 then return end
  local units, pending = {}, {}
  local head = box.list
  box.list = nil
  local item = head
  while item do
    local following = item.next
    item.prev, item.next = nil, nil
    if item.id == HLIST or item.id == VLIST or item.id == RULE then
      units[#units + 1] = {lead = pending, node = item, size = item.height + item.depth}
      pending = {}
    else
      pending[#pending + 1] = item
    end
    item = following
  end
  local function lead_size(u)
    local s = 0
    for _, g in ipairs(u.lead) do
      if g.id == GLUE then s = s + g.width elseif g.id == KERN then s = s + g.kern end
    end
    return s
  end
  local total = 0
  for i, u in ipairs(units) do total = total + u.size + (i > 1 and lead_size(u) or 0) end
  
  local function fits(height)
    local col, used, cuts, tallest = 1, 0, {}, 0
    for i, u in ipairs(units) do
      local add = u.size + (used > 0 and lead_size(u) or 0)
      if used > 0 and used + add > height then
        col = col + 1
        if col > n then return nil end
        cuts[#cuts + 1] = i
        used = u.size
      else
        used = used + add
      end
      tallest = math.max(tallest, used)
    end
    return cuts, tallest
  end
  local height, cuts, tallest = math.ceil(total / n), nil, nil
  repeat
    cuts, tallest = fits(height)
    if not cuts then height = height + 32768 end
  until cuts
  
  height = tallest
  local columns, start = {}, 1
  cuts[#cuts + 1] = #units + 1
  for _, stop in ipairs(cuts) do
    local list, last
    for i = start, stop - 1 do
      local u = units[i]
      if i > start then
        for _, g in ipairs(u.lead) do
          if last then last.next, g.prev = g, last else list = g end
          last = g
        end
      else
        for _, g in ipairs(u.lead) do node.free(g) end
      end
      if last then last.next, u.node.prev = u.node, last else list = u.node end
      last = u.node
    end
    local fill = node.new(GLUE)
    fill.stretch, fill.stretch_order = 65536, 2
    if last then last.next, fill.prev = fill, last else list = fill end
    columns[#columns + 1] = node.vpack(list, height, "exactly")
    start = stop
  end
  local row, last
  for i, c in ipairs(columns) do
    if i > 1 then
      local k = node.new(KERN)
      k.kern = sep
      last.next, k.prev = k, last
      last = k
    end
    if last then last.next, c.prev = c, last else row = c end
    last = c
  end
  for _, g in ipairs(pending) do node.free(g) end
  
  local packed = node.hpack(row)
  box.list = packed
  box.width, box.height, box.depth = packed.width, packed.height, packed.depth
end





function M.note_columns_split(n, room, sep, topskip, maxdepth, notes_index, body_name, notes_name, rest_name)
  local function refs_of(item)
    local count = (node.getproperty(item) or {}).docxlike_note_refs or 0
    if item.id == HLIST or item.id == VLIST then
      for inner in traverse(item.list) do
        if inner.id == HLIST or inner.id == VLIST then count = count + refs_of(inner) end
      end
    end
    return count
  end
  
  local notes = {}
  local box = tex.box[notes_index]
  local item = box and box.list
  if box then box.list = nil end
  local current, lead = nil, {}
  while item do
    local following = item.next
    item.prev, item.next = nil, nil
    if item.id == HLIST and (node.getproperty(item) or {}).docxlike_note_first_line ~= false then
      current = {lead = lead, items = {item}}
      notes[#notes + 1] = current
      lead = {}
    elseif item.id == HLIST or item.id == VLIST or item.id == RULE then
      if not current then current = {lead = {}, items = {}}; notes[#notes + 1] = current end
      for _, g in ipairs(lead) do current.items[#current.items + 1] = g end
      lead = {}
      current.items[#current.items + 1] = item
    else
      lead[#lead + 1] = item
    end
    item = following
  end
  for _, g in ipairs(lead) do node.free(g) end
  local function size(list)
    local s = 0
    for _, x in ipairs(list) do
      if x.id == HLIST or x.id == VLIST or x.id == RULE then s = s + x.height + x.depth
      elseif x.id == GLUE then s = s + x.width elseif x.id == KERN then s = s + x.kern end
    end
    return s
  end
  for _, note in ipairs(notes) do note.size, note.lead_size = size(note.items), size(note.lead) end
  
  local function notes_height(a, b)
    b = math.min(b, #notes)
    if b < a then return 0 end
    local h = sep
    for i = a, b do h = h + notes[i].size + (i > a and notes[i].lead_size or 0) end
    local last = notes[b].items[#notes[b].items]
    return h - (last and last.depth or 0)
  end
  local refs_total = 0
  local page = tex.box[255]
  local head = page.list
  page.list = nil
  for x in traverse(head) do refs_total = refs_total + refs_of(x) end
  local next_note = 1 + math.max(0, #notes - refs_total)
  local held = next_note - 1
  local function discardable(x) return x.id == GLUE or x.id == KERN or x.id == PENALTY end
  for k = 1, n do
    
    if k > 1 then
      while head and discardable(head) do
        local dropped = head
        head = head.next
        if head then head.prev = nil end
        dropped.next = nil
        node.free(dropped)
      end
      if head and (head.id == HLIST or head.id == VLIST or head.id == RULE) then
        local g = node.new(GLUE)
        g.width = math.max(0, topskip - head.height)
        head = node.insert_before(head, head, g)
      end
    end
    local first_note = next_note
    local last_note = (k == 1) and held or first_note - 1
    local t, prev_dp, refs, cut, cut_refs = 0, 0, 0, nil, 0
    local x, previous = head, nil
    local best_t = 0
    while x do
      local legal = (x.id == GLUE and previous and not discardable(previous))
        or (x.id == PENALTY and x.penalty < 10000)
      if legal then
        local height = t + math.max(0, prev_dp - maxdepth)
        local need = height + notes_height(first_note, last_note + refs)
        if height > room then break end
        if need <= room then cut, cut_refs, best_t = x, refs, height end
        if x.id == PENALTY and x.penalty <= -10000 and need <= room then break end
      end
      if x.id == HLIST or x.id == VLIST or x.id == RULE then
        t = t + prev_dp + x.height
        prev_dp = x.depth
        refs = refs + refs_of(x)
      elseif x.id == GLUE then t = t + prev_dp + x.width; prev_dp = 0
      elseif x.id == KERN then t = t + prev_dp + x.kern; prev_dp = 0 end
      previous = x
      x = x.next
    end
    local piece
    if not x and t + math.max(0, prev_dp - maxdepth) + notes_height(first_note, last_note + refs) <= room then
      piece, head, cut_refs = head, nil, refs
    elseif cut then
      local after = cut.next
      if cut.prev then cut.prev.next = nil end
      piece = (cut == head) and nil or head
      cut.prev, cut.next = nil, nil
      node.free(cut)
      head = after
      if head then head.prev = nil end
    else
      piece = nil
    end
    
    last_note = math.min(last_note + cut_refs, #notes)
    local body = node.vpack(piece or node.new(GLUE))
    tex.box[body_name .. k .. "_box"] = body
    local list, tail
    for i = first_note, last_note do
      local note = notes[i]
      if i > first_note then
        for _, g in ipairs(note.lead) do
          if tail then tail.next, g.prev = g, tail else list = g end
          tail = g
        end
      else
        for _, g in ipairs(note.lead) do node.free(g) end
      end
      for _, it in ipairs(note.items) do
        if tail then tail.next, it.prev = it, tail else list = it end
        tail = it
      end
    end
    if list then
      tex.box[notes_name .. k .. "_box"] = node.vpack(list)
    else
      tex.box[notes_name .. k .. "_box"] = nil
    end
    next_note = last_note + 1
  end
  
  page.list = head
  local list, tail
  for i = next_note, #notes do
    for _, it in ipairs(i > next_note and notes[i].lead or {}) do
      if tail then tail.next, it.prev = it, tail else list = it end
      tail = it
    end
    for _, it in ipairs(notes[i].items) do
      if tail then tail.next, it.prev = it, tail else list = it end
      tail = it
    end
  end
  tex.box[rest_name] = list and node.vpack(list) or nil
end
function M.note_separator_width(index, normal, full)
  local box = tex.box[index]
  if box then
    for line in traverse_id(HLIST, box.list) do
      if (M.compat or 15) < 15 and (node.getproperty(line) or {}).docxlike_note_first_line == false then return full end
      break
    end
  end
  return normal
end
local function note_reserve_node(insertion)
  for n in traverse(insertion.list) do
    if n.id == GLUE and (node.getproperty(n) or {}).docxlike_note_story_reserve then return n end
    if n.id == HLIST or n.id == VLIST then break end
  end
end
local function remove_note_reserve(insertion)
  local glue = note_reserve_node(insertion)
  if not glue then return end
  local p = node.getproperty(insertion) or {}
  insertion.list = node.remove(insertion.list, glue)
  insertion.height = insertion.height - glue.width
  node.free(glue)
  p.docxlike_note_leading_node = nil
  node.setproperty(insertion, p)
end
local function begin_note_story(index)
  if index ~= token.create("footins").mode or not getbool("g__docxlike_note_installed_bool") then return end
  local insertion = tex.lists.contrib_head
  if type(insertion) == "number" then insertion = node.direct.tonode(insertion) end
  if not insertion or insertion.id ~= INS or insertion.subtype ~= index then return end
  local p = node.getproperty(insertion) or {}
  local first
  for line in traverse_id(HLIST, insertion.list) do first = line; break end
  if not first then return end
  local continuation = (node.getproperty(first) or {}).docxlike_note_first_line == false
  if continuation and (node.getproperty(first) or {}).docxlike_note_paragraph_story and tex.pagetotal <= 2 then
    local body
    for line in traverse_id(HLIST, insertion.next) do body = line; break end
    local bp = body and node.getproperty(body)
    if bp and bp.docxlike_line_leading then
      local reserved = insertion.height + tex.getskip(index).width + body.height + body.depth
      if (M.compat or 15) < 15 then
        reserved = reserved - ((node.getproperty(first) or {}).docxlike_note_reference_leading or 0)
      else
        reserved = reserved + bp.docxlike_line_leading
      end
      if reserved > tex.getdimen("textheight") + 2 then
        local empty = node.new(HLIST)
        local fill = node.new(GLUE)
        fill.stretch, fill.stretch_order = 65536, 1
        local boundary = node.new(PENALTY)
        boundary.penalty = -10000
        empty.next, fill.prev, fill.next, boundary.prev = fill, empty, boundary, fill
        local following = insertion.next
        insertion.next, empty.prev = empty, insertion
        boundary.next = following
        if following then following.prev = boundary end
      end
    end
  end
  local room = tex.pagegoal - tex.pagetotal - tex.pagedepth - tex.getskip(index).width
  if p.docxlike_note_split_reserve and not continuation then
    local glue = note_reserve_node(insertion)
    if insertion.height - (glue and glue.width or 0) <= room + 2 then
      remove_note_reserve(insertion)
      insertion.width = p.docxlike_note_original_top or insertion.width
      p.docxlike_note_leading_amount = nil
      p.docxlike_note_original_top = nil
      p.docxlike_note_split_reserve = nil
      node.setproperty(insertion, p)
    end
  end
  local leading = p.docxlike_note_leading_amount or 0
  if leading <= 0 and (p.docxlike_note_reference_leading or 0) > 0 then
    if insertion.height > room + 2 then
      leading = p.docxlike_note_reference_leading
      p.docxlike_note_leading_amount = leading
      p.docxlike_note_original_top = insertion.width
      p.docxlike_note_split_reserve = true
      node.setproperty(insertion, p)
    end
  end
  if leading <= 0 or note_reserve_node(insertion) then return end
  if p.docxlike_note_original_top ~= nil then
    insertion.width = math.max(p.docxlike_note_original_top, first.height) + leading
  end
  if continuation then
    for n in traverse(insertion.list) do
      if n.id == GLUE and n.width >= leading then
        local gp = node.getproperty(n) or {}
        gp.docxlike_note_story_reserve = leading
        node.setproperty(n, gp)
        break
      end
      if n == first then break end
    end
  else
    local glue = node.new(GLUE)
    glue.width = leading
    node.setproperty(glue, {docxlike_note_story_reserve = leading})
    insertion.list = node.insert_before(insertion.list, insertion.list, glue)
    insertion.height = insertion.height + leading
    p.docxlike_note_leading_node = glue
    node.setproperty(insertion, p)
  end
end
local function relax_oversized_note_paragraphs(insertion, maximum)
  local groups, current = {}, nil
  for n in traverse(insertion.list) do
    local p = node.getproperty(n) or {}
    if n.id == HLIST and p.docxlike_para_first then
      current = {first = n, total = 0, together = p.docxlike_para_together}
      groups[#groups + 1] = current
    end
    if current then
      if n.id == HLIST or n.id == VLIST or n.id == RULE then current.total = current.total + n.height + n.depth
      elseif n.id == GLUE then current.total = current.total + n.width
      elseif n.id == KERN then current.total = current.total + n.kern end
      current.last = n
      if n.id == HLIST and p.docxlike_para_last then current = nil end
    end
  end
  local released = false
  for index, group in ipairs(groups) do
    if group.together and group.total > maximum + 2 then
      group.oversized = true
      if index > 1 then
        
        local retry = node.new(PENALTY)
        retry.penalty = -10000
        insertion.list = node.insert_before(insertion.list, group.first, retry)
      end
      local n = group.first
      while n do
        if n.id == PENALTY and n.subtype == 1 and n.penalty >= 10000 then n.penalty = n.penalty - 10000 end
        if n.id == HLIST then
          local p = node.getproperty(n) or {}
          p.docxlike_para_together = false
          p.docxlike_note_oversized = true
          node.setproperty(n, p)
        end
        if n == group.last then break end
        n = n.next
      end
      released = true
    end
  end
  return released, groups
end
local function note_body_context(head)
  if getbool("l__docxlike_format_owned_par_bool") then return true end
  if not getbool("g_docxlike_word_layout_bool") then return false end
  for line in traverse_id(HLIST, head) do
    if (not M.attr or node.get_attribute(line, M.attr) ~= 0)
        and (line.subtype == 1 or (node.getproperty(line) or {}).docxlike_line_leading ~= nil) then
      return true
    end
  end
  return false
end

local function tag_column_notes(head)
  local footnote_class = token.create("footins").mode
  local reference
  for n in traverse(head) do
    if n.id == HLIST then reference = n
    elseif n.id == INS and n.subtype == footnote_class and reference
        and not (node.getproperty(n) or {}).docxlike_note_tagged then
      local p = node.getproperty(n) or {}
      p.docxlike_note_tagged = true
      node.setproperty(n, p)
      local rp = node.getproperty(reference) or {}
      rp.docxlike_note_refs = (rp.docxlike_note_refs or 0) + 1
      node.setproperty(reference, rp)
      local first = true
      for line in traverse_id(HLIST, n.list) do
        local lp = node.getproperty(line) or {}
        lp.docxlike_note_first_line = first
        node.setproperty(line, lp)
        first = false
      end
    end
  end
end
local function coordinate_notes(head)
  if tex.nest.ptr == 0 and getbool("g__docxlike_note_installed_bool") and getbool("g__docxlike_cols_open_bool") then
    tag_column_notes(head)
  end
  if tex.nest.ptr ~= 0
      or not note_body_context(head)
      or not getbool("g__docxlike_note_installed_bool")
      or getbool("g__docxlike_cols_open_bool") or M.cell then return head end
  local incoming_notes = 0
  for incoming in traverse_id(INS, head) do incoming_notes = incoming_notes + 1 end
  if M.held_keep_note and (incoming_notes > 0 or not getbool("l__docxlike_format_keep_next_bool")) then
    head = flush_held_keep_note(head)
    incoming_notes = incoming_notes + 1
  end
  local full = tex.getdimen("textheight")
  local prior, prior_start, chain = body_kept_height()
  local prior_insertion = false
  if chain then
    for n in traverse(chain) do
      if n.id == INS then prior_insertion = true; break end
    end
  end
  local total, prefix = 0, 0
  for n in traverse(head) do
    if n.id == HLIST or n.id == VLIST or n.id == RULE then total = total + n.height + n.depth
    elseif n.id == GLUE then total = total + n.width
    elseif n.id == KERN then total = total + n.kern end
  end
  local oversized = tex.interlinepenalty >= 10000 and total > full
  local footnote_class = token.create("footins").mode
  local separator = tex.getskip(footnote_class).width
  local story_reserve = 0
  local page = tex.lists.page_head
  if type(page) == "number" then page = node.direct.tonode(page) end
  for ins in traverse_id(INS, page) do
    if ins.subtype == footnote_class then
      story_reserve = math.max(story_reserve, (node.getproperty(ins) or {}).docxlike_note_leading_amount or 0)
    end
  end
  local reference, seen_references = nil, 0
  
  
  local lone_note = incoming_notes == 1 and tex.interlinepenalty < 10000
  for line in traverse_id(HLIST, head) do
    if (node.getproperty(line) or {}).docxlike_para_together then lone_note = false; break end
  end
  local n = head
  while n do
    local next_node = n.next
    if n.id == HLIST then reference = n; prefix = prefix + n.height + n.depth
    elseif n.id == GLUE then prefix = prefix + n.width
    elseif n.id == KERN then prefix = prefix + n.kern
    elseif n.id == INS and n.subtype == footnote_class and reference
        and not (node.getproperty(n) or {}).docxlike_note_coordinated then
      
      n.depth = 0
      local first
      for line in traverse_id(HLIST, n.list) do first = line; break end
      local leading = (node.getproperty(reference) or {}).docxlike_line_leading or 0
      local properties = node.getproperty(n) or {}
      properties.docxlike_note_coordinated = true
      if docxlike and docxlike.page then docxlike.page.note(n) end
      properties.docxlike_note_reference_leading = leading
      node.setproperty(n, properties)
      local oversized_note, note_paragraphs = relax_oversized_note_paragraphs(n, full - separator)
      local kept_note = false
      for _, paragraph in ipairs(note_paragraphs) do
        if paragraph.together then kept_note = true end
      end
      if (M.compat or 15) < 15 and lone_note and not kept_note then
        
        
        local top = node.new(PENALTY)
        top.penalty = 0
        n.list = node.insert_before(n.list, n.list, top)
      end
      local oversized_first = oversized_note and note_paragraphs[1] and note_paragraphs[1].oversized
      local paragraph_story = #note_paragraphs > 1 and n.height > full - separator
      if paragraph_story then
        paragraph_story = false
        for _, paragraph in ipairs(note_paragraphs) do
          if paragraph.together then paragraph_story = true; break end
        end
      end
      local is_first = true
      for line in traverse_id(HLIST, n.list) do
        local lp = node.getproperty(line) or {}
        lp.docxlike_note_first_line = is_first
        lp.docxlike_note_paragraph_story = paragraph_story
        lp.docxlike_note_reference_leading = leading
        node.setproperty(line, lp)
        is_first = false
      end
      local minimum = first and first.height + first.depth or n.height
      local first_reference = (node.getproperty(reference) or {}).docxlike_para_first
      local impossible = prior > 0 and first_reference
        and prior + prefix + separator + minimum > full + 2
      local reserve = (M.compat or 15) >= 15 or prior > 0 and not impossible
      if reserve and leading > 0
          and getbool("g__docxlike_note_bottom_bool")
          and not properties.docxlike_note_body_leading then
        
        local glue = node.new(GLUE)
        glue.width = leading
        node.setproperty(glue, {docxlike_note_story_reserve = leading})
        properties.docxlike_note_leading_node = glue
        properties.docxlike_note_leading_amount = leading
        properties.docxlike_note_original_top = n.width
        n.list = node.insert_before(n.list, n.list, glue)
        n.height = n.height + leading
        if first then n.width = math.max(n.width, first.height) + leading end
        properties.docxlike_note_body_leading = true
        node.setproperty(n, properties)
      end
      if story_reserve > 0 and story_reserve == (properties.docxlike_note_leading_amount or 0) then
        remove_note_reserve(n)
      end
        
      if oversized_first and tex.pagetotal > 2 and (first_reference or
          seen_references > 0 and not (node.getproperty(reference) or {}).docxlike_para_together) then
        local fresh = node.new(PENALTY)
        fresh.penalty = -10000
        head = node.insert_before(head, first_reference and head or reference, fresh)
      end
      if (M.compat or 15) >= 15 and (oversized_first or next(M.deferred_notes) ~= nil) then
        head = node.remove(head, n)
        n.next, n.prev = nil, nil
        
        local entry = {insertion = n, ready = false, note_only = oversized_first or false}
        M.deferred_notes[#M.deferred_notes + 1] = entry
        local marker = node.new(WHATSIT, "late_lua")
        marker.data = function() entry.ready = true end
        reference.head = node.insert_before(reference.head, reference.head, marker)
      elseif (M.compat or 15) < 15 and impossible and not prior_insertion then
        
        local penalty = node.new(PENALTY)
        penalty.penalty = -10000
        head = node.insert_before(head, reference, penalty)
        if chain and prior_start > 2 then
          local before = chain.prev
          if before then
            before.next = nil
            chain.prev = nil
            local page = tex.lists.page_head
            if type(page) == "number" then page = node.direct.tonode(page) end
            tex.lists.page_head = page
            tex.pagetotal, tex.pagedepth = prior_start, 0
            head = append_list(chain, head)
            local fresh = node.new(PENALTY)
            fresh.penalty = -10000
            head = node.insert_before(head, head, fresh)
          end
          chain = nil
        end
      elseif (M.compat or 15) >= 15 and (oversized or impossible) then
        head = node.remove(head, n)
        n.next, n.prev = nil, nil
        local entry = {insertion = n, ready = false}
        M.deferred_notes[#M.deferred_notes + 1] = entry
        local marker = node.new(WHATSIT, "late_lua")
        marker.data = function() entry.ready = true end
        reference.head = node.insert_before(reference.head, reference.head, marker)
      elseif (M.compat or 15) >= 15 and not oversized and not M.held_keep_note
          and incoming_notes == 1
          and getbool("g__docxlike_note_bottom_bool") and getbool("l__docxlike_format_keep_next_bool")
          and tex.interlinepenalty >= 10000 and first_reference and first
          and not (node.getproperty(first) or {}).docxlike_para_together
          and n.height > minimum + leading + 2 then
        local page = tex.lists.page_head
        if type(page) == "number" then page = node.direct.tonode(page) end
        local foreign = false
        for existing in traverse(page) do if existing.id == INS then foreign = true; break end end
        if not foreign then
          head = node.remove(head, n)
          n.next, n.prev = nil, nil
          M.held_keep_note = {insertion = n, minimum = minimum + (properties.docxlike_note_leading_amount or 0)}
        end
      end
      if n.prev or n == head then
        story_reserve = math.max(story_reserve, properties.docxlike_note_leading_amount or 0)
        if paragraph_story and not (node.getproperty(reference) or {}).docxlike_para_together then
          local following = next_node
          while following and following.id ~= HLIST do following = following.next end
          if following then
            local boundary = node.new(PENALTY)
            boundary.penalty = -10000
            head = node.insert_after(head, n, boundary)
          end
        end
      end
      seen_references = seen_references + 1
    end
    n = next_node
  end
  return head
end
function M.release_deferred_notes()
  local pending, ready, note_only = {}, nil, false
  for _, entry in ipairs(M.deferred_notes) do
    if entry.ready then
      ready = append_list(ready, entry.insertion)
      note_only = note_only or entry.note_only == true
    else pending[#pending + 1] = entry end
  end
  M.deferred_notes = pending
  if ready then
    local head = tex.lists.contrib_head
    if type(head) == "number" then head = node.direct.tonode(head) end
    local first
    for line in traverse_id(HLIST, head) do
      if node.getproperty(line) then first = line; break end
    end
    
    local leading, first_insert = 0, nil
    for insertion in traverse_id(INS, ready) do
      first_insert = first_insert or insertion
      local p = node.getproperty(insertion) or {}
      local extra = p.docxlike_note_leading_amount or 0
      local glue = p.docxlike_note_leading_node
      leading = math.max(leading, extra)
      if glue then
        insertion.list = node.remove(insertion.list, glue)
        insertion.height = insertion.height - extra
        insertion.width = p.docxlike_note_original_top
        node.free(glue)
        p.docxlike_note_leading_node = nil
        node.setproperty(insertion, p)
      end
      if note_only and not first then
        p.docxlike_note_leading_amount = nil
        p.docxlike_note_reference_leading = 0
        node.setproperty(insertion, p)
      end
    end
    if note_only and not first then leading = 0 end
    if first_insert and leading > 0 then
      local glue = node.new(GLUE)
      glue.width = leading
      node.setproperty(glue, {docxlike_note_story_reserve = leading})
      first_insert.list = node.insert_before(first_insert.list, first_insert.list, glue)
      first_insert.height = first_insert.height + leading
      for line in traverse_id(HLIST, first_insert.list) do
        first_insert.width = math.max(first_insert.width, line.height) + leading
        break
      end
    end
    if first and (node.getproperty(first) or {}).docxlike_para_together then
      local height, n = 0, first
      while n do
        if n.id == HLIST or n.id == VLIST or n.id == RULE then height = height + n.height + n.depth
        elseif n.id == GLUE then height = height + n.width
        elseif n.id == KERN then height = height + n.kern end
        if (node.getproperty(n) or {}).docxlike_para_last then break end
        n = n.next
      end
      local reserved = tex.getskip(token.create("footins").mode).width
      for insertion in traverse_id(INS, ready) do reserved = reserved + insertion.height end
      if height + reserved > tex.getdimen("textheight") + 2 then
        
        local empty = node.new(HLIST)
        local fill = node.new(GLUE)
        fill.stretch, fill.stretch_order = 65536, 1
        local penalty = node.new(PENALTY)
        penalty.penalty = -10000
        empty.next, fill.prev, fill.next, penalty.prev = fill, empty, penalty, fill
        ready = append_list(ready, empty)
      end
    end
    if note_only and not first then
      local empty = node.new(HLIST)
      local fill = node.new(GLUE)
      fill.stretch, fill.stretch_order = 65536, 1
      local penalty = node.new(PENALTY)
      penalty.penalty = -10000
      empty.next, fill.prev, fill.next, penalty.prev = fill, empty, penalty, fill
      ready = append_list(ready, empty)
    end
    tex.lists.contrib_head = append_list(ready, head)
  end
end
local function prepare_toc_tails(items,P)
  for _,it in ipairs(items) do
    if it.toc_tail then
      local page,leader
      for g in traverse(it.toc_tail.head) do
        if g.id==HLIST and node.get_attribute(g,toc_tail_attr)==2 then page=g end
        if g.id==GLUE and g.leader then leader=g end
      end
      if not page or not leader then
        tex.error('docxlike Word TOC tail has no page box or leader'); return
      end
      
      leader.width=0
      local pi,ind,sh,sd=tokenize(legacy_kern(page.head),false,P.nogrid)
      if #pi==0 then tex.error('docxlike Word TOC experiment requires a nonempty page number'); return end
      local pp={}
      for k,v in pairs(P) do pp[k]=v end
      pp.align,pp.justify,pp.toc='left',false,false
      natural(pi,pp)
      local width=width_of(pi,1,#pi)+ind
      local line={first=1,last=#pi,width=width,over=0,measure=width,capacity=width,
        shift=0,isfirst=true,islast=true,ragged=true}
      local box=render(pi,line,pp,sh,sd,ind,true,nil)
      page.head=box.head; box.head=nil
      page.width,page.height,page.depth=box.width,box.height,box.depth
      page.glue_set,page.glue_sign,page.glue_order=box.glue_set,box.glue_sign,box.glue_order
      node.free(box)
      it.w=leader.width+width
    end
  end
end

local function paragraph_penalty(index, count, is_display, broken)
  if not native_controls() then
    local value=tex.interlinepenalty
    if index==1 then value=value+tex.clubpenalty end
    if index==count-1 then value=value+tex.widowpenalty end
    return value
  end
  local function value(name, position, scalar)
    
    local array=tex.get(name)
    if type(array)=="table" and #array>1 then
      return array[math.min(position,#array-1)]
    end
    return scalar
  end
  local widow=is_display and "displaywidow" or "widow"
  local result=value("interlinepenalties",index,tex.interlinepenalty)
    +value("clubpenalties",index,index==1 and tex.clubpenalty or 0)
    +value(widow.."penalties",count-index,index==count-1 and tex[widow.."penalty"] or 0)
  if broken then result=result+tex.brokenpenalty end
  return math.max(-1073741823,math.min(1073741823,result))
end





local function soft_hyphen_page_fit(head, ctx)
  if not head or (M.compat or 15) < 15 or not ctx or not ctx.exact or tex.pardir == "TRT"
      or tex.nest.ptr ~= 0 or native_controls()
      or tex.interlinepenalty >= 10000 or tex.clubpenalty >= 10000 or tex.widowpenalty >= 10000
      or getbool("l_docxlike_format_in_header_bool")
      or getbool("g__docxlike_cols_open_bool")
      or getbool("l__docxlike_format_keep_next_bool") then return head end
  local boxes, has_soft = {}, false
  for n in traverse(head) do
    if n.id == INS or n.id == VLIST
        or (n.id == PENALTY and n.penalty >= 10000) then return head end
    if n.id == HLIST then
      local properties = node.getproperty(n) or {}
      if properties.docxlike_line_leading == nil then return head end
      boxes[#boxes + 1] = n
      has_soft = has_soft or properties.docxlike_soft_hyphen_line
    end
  end
  if not has_soft or #boxes < 2 then return head end
  local full = math.min(tex.vsize, tex.getdimen("textheight"))
  local goal = math.min(tex.pagegoal, full)
  if goal <= 0 then return head end
  local position = tex.pagetotal + tex.pagedepth
  local index = 0
  for n in traverse(head) do
    if n.id == GLUE then
      if position > 0 then position = position + n.width end
    elseif n.id == KERN then
      position = position + n.kern
    elseif n.id == HLIST then
      index = index + 1
      local span = n.height + n.depth
      if position + span > goal + 2 then position = 0 end
      local following = boxes[index + 1]
      if following and (node.getproperty(n) or {}).docxlike_soft_hyphen_line
          and position > 0 and position + span + following.height + following.depth > goal + 2 then
        local penalty = node.new(PENALTY)
        penalty.penalty = -10000
        head = node.insert_before(head, n, penalty)
        position = 0
      end
      position = position + span
    elseif n.id == RULE then
      position = position + n.height + n.depth
    elseif n.id == PENALTY and n.penalty <= -10000 then
      position = 0
    end
  end
  return head
end

function M.filter(head, is_display)
  if docxlike.run and docxlike.run.scale_on then head = docxlike.run.scale(head) end
  local toc=getbool('l__docxlike_toc_word_par_bool')==true
  mark_math_objects(head)
  
  
  if getbool('l__docxlike_format_display_box_bool')==true then return skip('display-box') end
  local incoming = node.getproperty(head) or {}
  incoming.docxlike_incoming_leading = previous_body_leading()
  node.setproperty(head, incoming)
  local after_display = M.after_display
  M.after_display = false
  M.cell = getbool("l_docxlike_table_cell_bool") == true
  M.grid_on = getbool("g_docxlike_grid_bool") ~= false
  local ls, rs = tex.getskip("leftskip"), tex.getskip("rightskip")
  local align = align_of(ls, rs)
  local distributed=getbool('l__docxlike_format_distributed_bool')==true
  if distributed then align='distribute' end
  local wrapping = M.wrap_begin(is_display)
  local code_active = false
  if getbool("l__docxlike_code_overhang_bool") and M.code_attr then
    for g in node.traverse_id(GLYPH, head) do
      if (node.get_attribute(g, M.code_attr) or 0) > 0 then code_active = true; break end
    end
  end
  if M.attr and (node.get_attribute(head, M.attr) or 0) == 0 then
    if toc then tex.error('docxlike Word TOC cannot use a paragraph with Word layout disabled') end
    if wrapping then tex.error("docxlike wrapping cannot use a paragraph with Word layout disabled") end
    return skip("attr")
  end
  
  if align ~= "justify" and not getbool("l_docxlike_linebreak_align_bool")
      and not (code_active and align == "left") then
    if wrapping then tex.error("docxlike wrapping requires a paragraph selection or a Word-owned paragraph style") end
    return to_tex(head, "skips")
  end
  local ok, cell = pcall(tex.getdimen, "g_docxlike_page_char_dim")
  local em = tex.sp("1em")
  
  do
    local R = docxlike.run
    local sa = R and R.scale_attr
    if sa then
      local common
      for g in node.traverse_id(GLYPH, head) do
        local v = node.get_attribute(g, sa) or 100
        if common == nil then common = v elseif common ~= v then common = false; break end
      end
      if common and common ~= 100 then em = math.floor(em * common / 100 + 0.5); M.par_scale = common / 100 else M.par_scale = 1 end
    end
  end
  
  local nogrid = not ok or not cell or cell == 0
  if getbool('l__docxlike_linebreak_native_par_bool') then
    if toc then tex.error('docxlike Word TOC cannot use a native paragraph style') end
    if wrapping then tex.error('docxlike wrapping cannot use the native TeX paragraph backend') end
    if align == 'justify' then return skip('native') end
    return to_tex(head, nogrid and 'nocell' or 'skips')
  end
  if nogrid then
    if align == "left" and not code_active and not wrapping
        and not getbool('l__docxlike_format_owned_par_bool')
        and not getbool('l_docxlike_linebreak_align_bool') then return to_tex(head, "nocell") end
    cell = em
  end
  local wrap_pre
  do
    
    local g = head
    while g do
      local nxt = g.next
      if g.id == ADJUST and g.subtype == 1 then
        head = node.remove(head, g)
        local list = g.list; g.list = nil
        if list then wrap_pre = append_list(wrap_pre, list) end
        node.free(g)
      elseif g.id == GLYPH or (g.id == HLIST and g.subtype ~= 3) then break end
      g = nxt
    end
  end
  local cell0 = cell
  
  local ok2, body = pcall(tex.getdimen, "g_docxlike_body_size_dim")
  local inc, atbody = 0, true
  if ok2 and body and body > 0 and not nogrid then
    inc = cell - body
    atbody = math.abs(em - body) < 256
    cell = em + inc
  end
  head = legacy_kern(head)
  if M.done_attr then
    for g in node.traverse_id(GLYPH, head) do mark_done(g) end
  end
  local items, indent, strut_h, strut_d = tokenize(head, code_active, nogrid)
  if #items == 0 then
    for rule in traverse_id(RULE, head) do
      if rule.width == 0 then
        local p = node.getproperty(rule) or {}
        p.docxlike_strut_only = true
        node.setproperty(rule, p)
      end
    end
    local previous = previous_body_line()
    local prior = previous and node.getproperty(previous) or {}
    if (M.compat or 15) < 15 and tex.nest.ptr == 0
        and prior.docxlike_keep_released and prior.docxlike_para_keep then
      for rule in traverse_id(RULE, head) do
        if rule.width == 0 then
          local p = node.getproperty(rule) or {}
          p.docxlike_incoming_keep_released = true
          node.setproperty(rule, p)
        end
      end
    end
    return true
  end
  local bp = 65781.76
  
  trace("PARAMS em=%.4f body=%.4f chardim=%.4f cell=%.4f inc=%.4f", em / bp, (body or 0) / bp, (ok and cell0 or 0) / bp, cell / bp, inc / bp)
  
  local pre = "l_docxlike_format_par_"
  local hsnap = getbool(pre .. "snap_horizontal_bool")
  if hsnap == nil then hsnap = true end
  if nogrid then hsnap = false end
  
  local A = latin_adds(inc, hsnap, nogrid)
  local balance, spacing, ari = A.balance, A.spacing, A.ari
  local grid_inc = hsnap and inc or 0
  local sp2 = balance and 2 * spacing or spacing
  cell = em + grid_inc + sp2
  local latin_add = A.latin
  
  local break_compat = M.compat
  local alt_kinsoku = token.get_macro("g_docxlike_alt_kinsoku_tl")
  if break_compat < 15 and (alt_kinsoku == "true" or alt_kinsoku == "false") then
    break_compat = alt_kinsoku == "true" and 11 or (break_compat == 11 and 12 or break_compat)
  end
  local P = { cell = cell, em = em, bp = bp, excess = grid_inc + sp2, grid = hsnap,
              grid_extra = latin_add-spacing, char_grid_extra = grid_inc,
               latin_add = latin_add, spacing = spacing,
              half_space = (em + grid_inc) / 2 + sp2, cell0 = cell0, nogrid = nogrid,
              ari = ari,
              space_add = A.space,
              compat = break_compat, table_cell = M.cell,
               justify = align == "justify" or distributed, distributed=distributed,
               align = align, rtl = tex.pardir == "TRT", autospace = true, compress = true,
               section_end = break_compat < 15 and getbool("l_docxlike_par_section_end_bool") == true,
              no_expand_shift_return = M.no_expand_shift_return,
              cjk_compress = token.get_macro("g_docxlike_character_spacing_control_tl") ~= "do-not-compress",
              cjk_compress_given = getbool("g__docxlike_character_spacing_given_bool") == true,
              balance = balance,
              autospace_de = getbool("l_docxlike_format_autospace_de_bool") ~= false,
              autospace_dn = getbool("l_docxlike_format_autospace_dn_bool") ~= false,
               eps = 0.03 * bp }
  P.toc=toc
  if toc then
    if tex.pardir=='TRT' or wrapping then tex.error('docxlike Word TOC experiment requires an unwrapped LTR paragraph') end
    P.toc_origin=tex.getdimen('l__docxlike_toc_origin_dim')
    local edge=tex.hsize
    if P.ari and not nogrid and M.grid_on and cell0>0 then
      edge=math.floor(edge/cell0+1e-6)*cell0
    end
    edge=edge-tex.getdimen('l_docxlike_format_right_dim')
    
    P.toc_legacy_tail=break_compat~=15 and tex.getdimen('l__docxlike_toc_tab_dim')>=edge-P.eps
    prepare_toc_tails(items,P)
  end
  P.code_overhang = code_active and (align == "justify" or align == "left")
  if wrapping then P.code_overhang = false end
  if P.code_overhang then P.code_right = code_right_limit() end
  trace("STEP cell=%.4f latin_add=%.4f half_space=%.4f", P.cell / bp, P.latin_add / bp, P.half_space / bp)
  trace("STEP snap=%s spacing=%.4f balance=%s", tostring(hsnap), spacing / bp, tostring(balance))
  soft_split(items, P)
  local snapchars = hsnap and getbool("g_docxlike_page_snap_chars_bool") and true or false
  if toc and snapchars then
    tex.error('docxlike Word TOC does not support text-snaps-to-character-grid')
  end
  if snapchars and native_controls() then
    for _,it in ipairs(items) do
      if it.native_disc then
        tex.error("docxlike: native discretionary branches cannot use text-snaps-to-character-grid",
          {"Use no-grid or disable paragraph snap-to-grid-when-document-grid-is-defined. The backend is unchanged."})
        break
      end
    end
  end
  local ctx = M.linectx(strut_h, strut_d)
  local paragraph_leading = ctx and not after_display and previous_body_leading() or 0
  local shape, wrap_next = M.wrap_shape(M.shape(), wrapping, strut_h + strut_d, indent)
  P.wrap_next = wrap_next
  local lines
  if snapchars then lines = snap_decide(items, P, shape, indent)
  else lines = decide(items, P, shape, indent) end
  local pfa = luatexbase.attributes["docxlike@pfill@attr"]
  local pfill = pfa and node.get_attribute(head, pfa)
  local newhead, tail = nil, nil
  local prevdepth = tex.prevdepth
  local previous_leading = 0
  after_display = after_display and prevdepth > -65536000
  local nl = #lines
  local nexthead = nil
  local wrap_rows = {}
  for li, line in ipairs(lines) do
    local box, moved, pre
    local core=items[line.last].core
    line.broken=not not line.hyphen_disc
      or (native_controls() and core and core.id==DISC and line.bp==core.next) or false
    if snapchars then
      box, moved, nexthead, pre = snap_render(items, line, P, strut_h, strut_d, indent, li == 1, ctx)
    else
      box, moved, nexthead, pre = render(items, line, P, strut_h, strut_d, indent, li == 1, ctx, nexthead)
    end
    if line.soft_hyphen then
      local properties = node.getproperty(box) or {}
      properties.docxlike_soft_hyphen_line = true
      node.setproperty(box, properties)
    end
    if pfill then shade_line(box, pfill, wrapping and line.wrap_row == 1 or li == 1, ctx, line.measure, P) end
    if wrapping then
      local ri = line.wrap_row
      local row = wrap_rows[ri]
      if not row then row = {parts = {}, skip = line.wrap_skip}; wrap_rows[ri] = row end
      row.parts[#row.parts + 1] = box
      row.broken=line.broken
      if pre then row.pre = append_list(row.pre, pre) end
      if moved then row.moved = append_list(row.moved, moved) end
    else
    if pre then
      if newhead == nil then newhead = pre else tail.next = pre; pre.prev = tail end
      tail = node.tail(pre)
    end
    if li > 1 then
      
      local g = node.new(GLUE); g.subtype = 0
      if ctx then
        
        g.width = previous_leading
      else
        g.width = tex.baselineskip.width - prevdepth - box.height
        if g.width < tex.lineskiplimit then g.width = tex.lineskip.width end
      end
      tail.next = g; g.prev = tail; tail = g
    end
    if newhead == nil then newhead = box else tail.next = box; box.prev = tail end
    tail = box
    if moved then
      tail.next = moved; moved.prev = tail; tail = node.tail(moved)
    end
    if li < nl then
      local pen = paragraph_penalty(li,nl,is_display,line.broken)
      if pen ~= 0 then
        local pn = node.new(PENALTY, 1); pn.penalty = pen
        tail.next = pn; pn.prev = tail; tail = pn
      end
    end
    prevdepth = box.depth
    previous_leading = (node.getproperty(box) or {}).docxlike_line_leading or 0
    end
  end
  if wrapping then
    local function put(list)
      if not list then return end
      if not newhead then newhead = list else tail.next = list; list.prev = tail end
      tail = node.tail(list)
    end
    for ri, row in ipairs(wrap_rows) do
      local outer = node.new(HLIST)
      outer.width, outer.height, outer.depth = tex.hsize, 0, 0
      local descent_with_leading = 0
      local content, ct, x = nil, nil, 0
      local function insert(n)
        if not content then content = n else ct.next = n; n.prev = ct end
        ct = n
      end
      for _, box in ipairs(row.parts) do
        local kern = node.new(KERN); kern.kern = box.shift - x
        x = box.shift + box.width
        outer.height = math.max(outer.height, box.height)
        outer.depth = math.max(outer.depth, box.depth)
        descent_with_leading = math.max(descent_with_leading, box.depth + ((node.getproperty(box) or {}).docxlike_line_leading or 0))
        if not outer.attr then outer.attr = box.attr end
        box.shift = 0
        insert(kern); insert(box)
      end
      outer.head = content
      local leading = math.max(0, descent_with_leading - outer.depth)
      node.setproperty(outer, {docxlike_line_leading = leading})
      M.wrap_mark_line(outer, wrapping, ri, row.skip)
      put(row.pre)
      if ri > 1 then
        local glue = node.new(GLUE)
        glue.width = ctx and previous_leading or tex.baselineskip.width - prevdepth - outer.height
        if not ctx and glue.width < tex.lineskiplimit then glue.width = tex.lineskip.width end
        put(glue)
      end
      if row.skip > 0 then local kern = node.new(KERN); kern.kern = row.skip; put(kern) end
      put(outer); put(row.moved)
      if ri < #wrap_rows then
        local penalty = paragraph_penalty(ri,#wrap_rows,is_display,row.broken)
        if penalty ~= 0 then local pn = node.new(PENALTY, 1); pn.penalty = penalty; put(pn) end
      end
      prevdepth = outer.depth
      previous_leading = leading
    end
  end
  
  if after_display and newhead then
    local g = node.new(GLUE); g.subtype = 0
    g.width = tex.baselineskip.width - tex.prevdepth - newhead.height
    if g.width < tex.lineskiplimit then g.width = tex.lineskip.width end
    g.next = newhead; newhead.prev = g; newhead = g
  end
  
  
  if is_display then tex.nest.top.prevdepth = prevdepth end
  if wrap_pre then newhead = append_list(wrap_pre, newhead) end
  if ctx then newhead = paragraph_boundary(newhead, paragraph_leading) end
  tag_paragraph(newhead)
  if not wrapping and not is_display then newhead = soft_hyphen_page_fit(newhead, ctx) end
  newhead = coordinate_notes(newhead)
  newhead = M.relax_oversized_keep_lines(newhead, true)
  M.retain_fitting_legacy_keep_next(newhead, true)
  newhead = legacy_relaxed_blank(newhead)
  if wrapping and wrapping.must_break then
    local penalty = node.new(PENALTY); penalty.penalty = -10000
    newhead = node.insert_before(newhead, newhead, penalty)
  end
  return newhead
end




local function fix_skips(head)
  if not (M.ks_attr and M.xks_attr) then return end
  for g in traverse(head) do
    local a, sw = nil, nil
    if g.id == GLUE then
      if is_kanjiskip(g) then a, sw = M.ks_attr, "kanjiskip"
      elseif is_xkanjiskip(g) then a, sw = M.xks_attr, "xkanjiskip" end
    end
    if a then
      local p = g.prev
      while p and p.id ~= GLYPH and p.id ~= HLIST do p = p.prev end
      local ref = p or g.next
      local v = ref and node.get_attribute(ref, a)
      if v and not LTJ.autospacing_off(ref, sw) then g.width = v end
    elseif g.id == KERN and g.subtype == 0 then
      
      local p, q = g.prev, g.next
      if (p and p.id == GLYPH and node.get_attribute(p, M.ks_attr))
        or (q and q.id == GLYPH and node.get_attribute(q, M.ks_attr)) then g.kern = 0 end
    elseif g.id == GLUE and (g.subtype == 0 or g.subtype == 13 or g.subtype == 14)
        and g.next and g.next.id == GLYPH and node.get_attribute(g.next, M.ks_attr) then
      
      local f = font.getfont(g.next.font)
      local kc = f and f.properties and f.properties.kerncharacters
      if kc and kc ~= "max" and f.parameters and f.parameters.quad and g.width > 0 then
        g.width = g.width - kc * f.parameters.quad
      end
    end
  end
end



local function packed_glyph(n)
  if n and n.id == HLIST and is_packed(n) then
    local g = n.head
    while g and g.id ~= GLYPH do g = g.next end
    return g
  end
end
function M.grid_box(n, inc, spacing, balance)
  local b = tex.box[n]
  if not b then return end
  local ec = inc + (balance and 2 or 1) * spacing
  local el = (balance and inc / 2 or inc) + spacing
  local head, added = b.list, 0
  for g in traverse(head) do
    local pg = packed_glyph(g)
    
    if (g.id == GLYPH or pg) and not done(pg or g) then
      local add
      if pg or is_jfont(g.font) then
        
        local nx = g.next
        while nx and (nx.id == PENALTY or (nx.id == RULE and nx.width == 0)) do nx = nx.next end
        if nx and nx.id == GLUE and is_kanjiskip(nx) then add = ec - nx.width else add = ec end
      else
        add = el
      end
      add = add + fake_bold(pg or g)
      if add ~= 0 then
        local k = node.new(KERN); k.kern = add
        head = node.insert_after(head, g, k)
        added = added + add
      end
      mark_done(pg or g)
    end
  end
  b.list = head
  b.width = b.width + added
end




function M.box_punct(n)
  local b = tex.box[n]
  if not b or not b.list then return end
  local head, added = b.list, 0
  local first = head
  while first and (first.id == WHATSIT or first.id == PENALTY
                   or (first.id == RULE and first.width == 0)) do
    first = first.next
  end
  local g = packed_glyph(first)
  if g and openers[g.char] then
    local k = node.new(KERN); k.kern = fsize(g.font) - first.width
    head = node.insert_before(head, first, k)
    added = added + k.kern
  end
  local last = node.tail(head)
  g = packed_glyph(last)
  if g and closers[g.char] then
    local k = node.new(KERN); k.kern = fsize(g.font) - last.width
    head = node.insert_after(head, last, k)
    added = added + k.kern
  end
  b.list = head
  b.width = b.width + added
end

function M.box_has_cjk(n)
  local b = tex.box[n]
  local function walk(list)
    for g in traverse(list) do
      if g.id == GLYPH then
        if is_jfont(g.font) then return true end
      elseif g.id == HLIST or g.id == VLIST then
        if walk(g.list) then return true end
      end
    end
    return false
  end
  return b and walk(b.list) or false
end
function M.box_cjk_flag(n)
  return M.box_has_cjk(n) and 1 or 0
end


local function pin_image(head)
  local sh, sd = 0, 0
  for line in traverse_id(HLIST, head) do
    for r in traverse_id(RULE, line.list) do
      if r.width == 0 and r.subtype == 0 then
        if r.height > sh then sh = r.height end
        if r.depth > sd then sd = r.depth end
      end
    end
  end
  local ctx = M.linectx(sh, sd)
  if not ctx then
    
    local exact = getbool("l_docxlike_format_strut_exact_bool")
    local snap = getbool("l_docxlike_format_line_snap_bool")
    if exact == nil or snap == nil then return true end
    local ok, pitch = pcall(tex.getdimen, "g_docxlike_page_lead_dim")
    if not ok or not pitch then pitch = 0 end
    local f = font.getfont(font.current())
    local size = (f and f.size) or tex.sp("12bp")
    local nat_cjk = getfactor("l__docxlike_format_strut_natural_tl") or 1.296875
    local nat_latin = getfactor("l_docxlike_format_natural_latin_tl") or 1.1499
    local natpara = nat_cjk * size
    local bls = tex.baselineskip.width
    local k = bls / natpara
    if k < 1 then k = 1 end
    ctx = { exact = exact, snap = snap, pitch = pitch, natpara = natpara,
            nat_cjk = nat_cjk, nat_latin = nat_latin, k = k, bls = bls }
  end
  if ctx.exact then return true end
  local changed = {}
  local owned = getbool('l__docxlike_format_owned_par_bool')
  for n in traverse(head) do
    if n.id == HLIST and n.subtype == 1 then
      local ih, id = image_hd(n.list)
      if owned then
        linebox(n, ctx, sh, sd)
        changed[n] = true
      elseif ih > 0 then
        if ctx.snap and ctx.pitch > 0 then
          n.height, n.depth = image_line(ih, id, ctx.pitch)
        else
          n.height, n.depth = image_line_free(ih, id, ctx)
        end
        changed[n] = true
      end
    end
  end
  if next(changed) == nil then return true end
  for n in traverse(head) do
    if n.id == GLUE and (n.subtype == 1 or n.subtype == 2 or (owned and n.subtype == 0))
        and ((n.prev and changed[n.prev]) or (n.next and changed[n.next])) then
      local previous = n.prev
      while previous and previous.id ~= HLIST do previous = previous.prev end
      n.width = previous and ((node.getproperty(previous) or {}).docxlike_line_leading or 0) or 0
      if owned then n.subtype = 0 end
    end
  end
  return true
end



local function pin_exact(head)
  if not getbool("l_docxlike_format_strut_exact_bool") then return pin_image(head) end
  local sh, sd = 0, 0
  for line in traverse_id(HLIST, head) do
    for r in traverse_id(RULE, line.list) do
      if r.width == 0 and r.subtype == 0 then
        if r.height > sh then sh = r.height end
        if r.depth > sd then sd = r.depth end
      end
    end
  end
  if sh == 0 and sd == 0 then return true end
  local bls = tex.baselineskip.width
  local prev = nil
  for n in traverse(head) do
    if n.id == HLIST and n.subtype == 1 then
      local th, td = native_table_hd(n.list)
      n.height, n.depth = math.max(sh, th), math.max(sd, td)
      prev = n
    elseif n.id == GLUE and (n.subtype == 1 or n.subtype == 2) and prev
        and n.next and n.next.id == HLIST then
      local th, td = native_table_hd(n.next.list)
      local next_height = math.max(sh, th)
      local gap = bls - prev.depth - next_height
      local ph, pd = native_table_hd(prev.list)
      n.width = (th > 0 or td > 0 or ph > 0 or pd > 0) and math.max(0, gap) or gap
    end
  end
  return true
end




local AMBIGUOUS = set_of("·–—‘’“”…")
local function scan_script(head)
  local wide, latin = false, false
  for n in traverse(head) do
    if n.id == GLYPH then
      local c = n.char
      if is_wide(c) then return true, latin end
      if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then latin = true end
    elseif (n.id == HLIST or n.id == VLIST) and n.list then
      local w, l = scan_script(n.list)
      if w then return true, latin end
      latin = latin or l
    end
  end
  return wide, latin
end
local function para_latin(head)
  local wide, latin = scan_script(head)
  return latin and not wide
end
local function latin_hint(head)
  local default_latin = para_latin(head)
  local profiles = docxlike.language_profiles or {}
  for n in traverse_id(GLYPH, head) do
    local c = n.char
    local profile = M.language_attr and profiles[node.get_attribute(n,M.language_attr)]
    local latin = profile and (profile.script == "Latn" or profile.script == "Cyrl" or profile.script == "Grek")
      or (not profile and default_latin)
    if latin and AMBIGUOUS[c] and LTJ.unprocessed(n) and LTJ.is_cjk_char(n) then
      LTJ.make_latin(n)
    end
  end
end
M.latin_hint = latin_hint


local UNSET = node.id("unset")
local function mcell_center(head)
  local a = M.mcell_attr
  if not a then return end
  local found = false
  local H, D = 0, 0
  for n in node.traverse_id(UNSET, head) do
    if n.height > H then H = n.height end
    if n.depth > D then D = n.depth end
    for m in node.traverse_id(HLIST, n.head) do
      if node.get_attribute(m, a) == 1 then found = true end
    end
  end
  if not found then return end
  for n in node.traverse_id(UNSET, head) do
    for m in node.traverse_id(HLIST, n.head) do
      if node.get_attribute(m, a) == 1 then
        m.shift = (D - H) / 2 - (m.depth - m.height) / 2
      end
    end
  end
end



local function cell_top(head)
  local a = M.ptop_attr
  if not a then return end
  local cells, H = {}, 0
  for n in node.traverse_id(UNSET, head) do
    local own = 0
    for m in node.traverse(n.head) do
      local first = m.id == VLIST and m.head
      if first and first.id == KERN and node.get_attribute(first, a) == 1 and m.height == 0 then
        local nx = first.next
        while nx and (nx.id == WHATSIT or nx.id == PENALTY) do nx = nx.next end
        local top = nx and (nx.id == HLIST or nx.id == VLIST or nx.id == RULE) and nx.height or 0
        if top > H then H = top end
        cells[#cells + 1] = { n, m }
      elseif m.id == HLIST or m.id == VLIST or m.id == RULE then
        if m.height - (m.shift or 0) > own then own = m.height - (m.shift or 0) end
      end
    end
    if own > H then H = own end
  end
  for _, c in ipairs(cells) do
    local n, m = c[1], c[2]
    m.shift = -H
    if H > n.height then n.height = H end
    local d = 0
    for x in node.traverse(n.head) do
      if x.id == HLIST or x.id == VLIST or x.id == RULE then
        local xd = x.depth + (x.shift or 0)
        if xd > d then d = xd end
      end
    end
    n.depth = d
  end
end


local font_spaces = {}
function M.save_font_space()
  local g = tex.nest.top.tail
  local balanced = g and g.id==GLUE and M.balanced_space_attr
    and node.get_attribute(g,M.balanced_space_attr)==1
  font_spaces[#font_spaces + 1] = g and g.id == GLUE
    and (g.subtype == 13 or g.subtype == 14 or balanced)
    and { subtype = g.subtype, balanced=balanced,
          font = M.spacefont_attr and node.get_attribute(g, M.spacefont_attr) } or false
end
function M.restore_font_space()
  local saved = table.remove(font_spaces)
  local g = tex.nest.top.tail
  if saved and g and g.id == GLUE and g.subtype == 0 then
    g.subtype = saved.subtype
    if saved.balanced then node.set_attribute(g,M.balanced_space_attr,1) end
    if saved.font then node.set_attribute(g, M.spacefont_attr, saved.font) end
  end
end


local cluster_serial = 0
local function explicit_breaks(head)
  local state, id, start, text, has_cf
  local function finish()
    if has_cf and id then cluster_cf_text[id] = text end
  end
  local function reset()
    finish(); state,id,start,text,has_cf=nil,nil,nil,nil,false
  end
  local g = head
  while g do
    local nxt, kind = g.next, g.id
    local c = kind == GLYPH and g.char
    if c == 0x200B and M.attr and (node.get_attribute(g,M.attr) or 0) ~= 0 then
      local p = node.new(PENALTY); p.penalty = 0; p.attr = g.attr
      head = node.insert_before(head,g,p)
      head = node.remove(head,g); node.free(g)
      reset()
    elseif c == 0x00AD and M.attr and (node.get_attribute(g,M.attr) or 0) ~= 0 then
      local hyphen = node.copy(g); hyphen.char = 45
      local disc = node.new(DISC)
      disc.subtype = 0; disc.attr = g.attr; disc.pre = hyphen
      node.setproperty(disc,{docxlike_soft_hyphen=true})
      node.set_attribute(disc,M.soft_hyphen_attr,1)
      node.set_attribute(hyphen,M.soft_hyphen_attr,1)
      disc.penalty = tex.exhyphenpenalty
      head = node.insert_before(head,g,disc)
      head = node.remove(head,g); node.free(g)
      reset()
    else
      if not c then
        local props = node.getproperty(g)
        c = props and props.zwnj and 0x200C
      end
      if node.get_attribute(g,M.cluster_attr) then
        reset()
      elseif c and c >= 0 and c <= 0x10FFFF then
        local fresh
        fresh,state = M.graphemes.read_codepoint(c,state)
        if fresh or not id then
          finish(); cluster_serial=cluster_serial+1; id,start,text,has_cf=cluster_serial,c,"",false
        end
        text = text .. utf8.char(c)
        has_cf = has_cf or c == 0x200C or c == 0x200D
        node.set_attribute(g,M.cluster_attr,id)
        node.set_attribute(g,M.cluster_start_attr,start)
      else
        reset()
      end
    end
    g = nxt
  end
  finish()
  return head
end



function M.relax_oversized_keep_lines(head, word_lines)
  local keep = tex.interlinepenalty
  if keep < 10000 or tex.nest.ptr > 1 then return head end
  local full = tex.getdimen("textheight")
  if not full or full <= 0 then return head end
  local total, count = 0, 0
  for n in traverse(head) do
    if n.id == HLIST or n.id == VLIST or n.id == RULE then
      total = total + n.height + n.depth
      if n.id == HLIST and (word_lines or n.subtype == 1) then count = count + 1 end
    elseif n.id == GLUE then total = total + n.width
    elseif n.id == KERN then total = total + n.kern end
  end
  if count < 2 or total <= full then return head end
  
  local retried = (node.getproperty(head) or {}).docxlike_keep_retry
  if not retried and tex.nest.ptr == 0 and tex.pagetotal > 0
      and getbool("l__docxlike_format_owned_par_bool")
      and not getbool("g__docxlike_cols_open_bool") then
    local penalty = node.new(PENALTY)
    penalty.penalty = -10000
    node.setproperty(penalty, {docxlike_keep_retry = true})
    head = node.insert_before(head, head, penalty)
  end
  for n in traverse_id(PENALTY, head) do
    local properties = node.getproperty(n)
    if n.subtype == 1 and n.penalty >= keep
        and not (properties and properties.docxlike_keep_released) then
      n.penalty = n.penalty - keep
      properties = properties or {}
      properties.docxlike_keep_released = true
      node.setproperty(n, properties)
    end
  end
  for line in traverse_id(HLIST, head) do
    local properties = node.getproperty(line) or {}
    if properties.docxlike_para_last then
      properties.docxlike_keep_released = true
      node.setproperty(line, properties)
    end
  end
  return head
end

function M.retain_fitting_legacy_keep_next(head, word_lines)
  if (M.compat or 15) >= 15 or tex.nest.ptr > 1 or tex.interlinepenalty >= 10000
      or not getbool("l__docxlike_format_owned_par_bool")
      or not getbool("l__docxlike_format_keep_next_bool")
      or getbool("g__docxlike_cols_open_bool") then return true end
  local total, lines = 0, {}
  for n in traverse(head) do
    if n.id == HLIST or n.id == VLIST or n.id == RULE then
      total = total + n.height + n.depth
      if n.id == HLIST and (word_lines or n.subtype == 1) then lines[#lines + 1] = n end
    elseif n.id == GLUE then total = total + n.width
    elseif n.id == KERN then total = total + n.kern end
  end
  if #lines < 2 then return true end
  local full = tex.getdimen("textheight")
  local goal = tex.pagegoal
  if goal > full * 2 then goal = full end
  local room = goal - tex.pagetotal - tex.pagedepth
  if total > room + 1 then return true end
  for i = 1, #lines - 1 do
    local p, found = lines[i].next, nil
    while p and p ~= lines[i + 1] do
      if p.id == PENALTY and p.subtype == 1 then found = p; break end
      p = p.next
    end
    if found then
      if found.penalty >= 0 then found.penalty = math.max(found.penalty, 10000) end
    else
      local penalty = node.new(PENALTY, 1); penalty.penalty = 10000
      head = node.insert_after(head, lines[i], penalty)
    end
  end
  return true
end




local word_hyphenation={entries={},queries={},hits=0,installed=false}
function word_hyphenation.key(tag,mode,word)
  return string.lower(tag)..'/'..mode..'/'..word
end
function word_hyphenation.load()
  local path=tex.jobname..'.docxlike-hyphenation.json'
  local file=io.open(path,'rb')
  if not file then return end
  local raw=file:read('*a');file:close()
  local json=utilities and utilities.json
  assert(json,'docxlike: JSON support unavailable for Word hyphenation data')
  local data=json.tolua(raw)
  assert(type(data)=='table' and data.kind=='docxlike-word-host-hyphenation-v1'
    and type(data.office_version)=='string' and type(data.entries)=='table'
    and type(data.source_manifest_sha256)=='string' and #data.source_manifest_sha256==64
    and type(data.source_export_sha256)=='string' and #data.source_export_sha256==64,
    'docxlike: invalid Word-host hyphenation data')
  for _,entry in ipairs(data.entries) do
    assert(type(entry.tag)=='string' and type(entry.word)=='string' and type(entry.mode)=='number'
      and type(entry.points)=='table','docxlike: invalid Word-host hyphenation entry')
    assert(entry.mode==11 or entry.mode==12 or entry.mode==14 or entry.mode==15,
      'docxlike: invalid Word-host compatibility mode')
    local length=utf8.len(entry.word)
    assert(length and length>=2,'docxlike: invalid Word-host word encoding')
    local last=0
    for _,cut in ipairs(entry.points) do
      assert(type(cut)=='number' and cut%1==0 and cut>last and cut<length,
        'docxlike: invalid Word-host hyphenation point')
      last=cut
    end
    local key=word_hyphenation.key(entry.tag,entry.mode,entry.word)
    assert(not word_hyphenation.entries[key],'docxlike: duplicate Word-host hyphenation entry')
    word_hyphenation.entries[key]=entry
  end
  word_hyphenation.source=data.office_version
end
function word_hyphenation.active()
  return getbool('g_docxlike_word_layout_bool') and getbool('g__docxlike_linebreak_word_bool')
    and getbool('g_docxlike_format_hyphen_bool') and not native_controls()
    and not getbool('l__docxlike_linebreak_native_par_bool')
    and not getbool('l_docxlike_format_in_header_bool') and tex.nest.ptr<=1
end
function word_hyphenation.letter(c)
  return c and ((c>=65 and c<=90) or (c>=97 and c<=122)
    or (c>=0xC0 and c<=0x2AF and c~=0xD7 and c~=0xF7))
end
function word_hyphenation.tag(g)
  if not M.attr or (node.get_attribute(g,M.attr) or 0)==0
      or (M.code_attr and (node.get_attribute(g,M.code_attr) or 0)>0) then return nil end
  local id=M.language_attr and node.get_attribute(g,M.language_attr)
  local profile=id and (docxlike.language_profiles or {})[id]
  return profile and profile.tag
end
function word_hyphenation.collect(head)
  if not word_hyphenation.active() then return end
  local glyphs,text,tag={}, {},nil
  local inside_math=false
  local function finish()
    if #glyphs>=2 then
      local word=table.concat(text)
      local key=word_hyphenation.key(tag,M.compat,word)
      local entry=word_hyphenation.entries[key]
      word_hyphenation.queries[key]={tag=string.lower(tag),mode=M.compat,word=word,available=entry~=nil}
      if entry then
        word_hyphenation.hits=word_hyphenation.hits+1
        for _,g in ipairs(glyphs) do
          local properties=node.getproperty(g) or {}
          properties.docxlike_word_host_entry=entry
          node.setproperty(g,properties)
          g.lang=word_hyphenation.empty_language:id()
        end
      end
    end
    glyphs,text,tag={}, {},nil
  end
  for g in traverse(head) do
    if g.id==MATH then
      finish();inside_math=g.subtype==0
    else
      local language=g.id==GLYPH and not inside_math and word_hyphenation.letter(g.char) and word_hyphenation.tag(g)
      if language then
        if tag and tag~=language then finish() end
        tag=language;glyphs[#glyphs+1]=g;text[#text+1]=utf8.char(g.char)
      elseif g.id~=KERN then finish() end
    end
  end
  finish()
end
function word_hyphenation.insert(head)
  if not word_hyphenation.active() then return head end
  local glyphs,entry={},nil
  local function finish()
    if entry then
      for _,cut in ipairs(entry.points) do
        local g=glyphs[cut]
        if g and glyphs[cut+1] then
          local hyphen=node.new(GLYPH)
          hyphen.font,hyphen.char,hyphen.attr,hyphen.lang=g.font,45,g.attr,g.lang
          local disc=node.new(DISC,2)
          disc.attr,disc.pre,disc.penalty=g.attr,hyphen,tex.hyphenpenalty
          node.setproperty(disc,{docxlike_word_host_auto=true})
          head=node.insert_after(head,g,disc)
        end
      end
      for _,g in ipairs(glyphs) do
        local properties=node.getproperty(g)
        if properties then properties.docxlike_word_host_entry=nil end
      end
    end
    glyphs,entry={},nil
  end
  local g=head
  while g do
    local following=g.next
    local found=g.id==GLYPH and (node.getproperty(g) or {}).docxlike_word_host_entry
    if found then
      if entry and entry~=found then finish() end
      entry=found;glyphs[#glyphs+1]=g
    elseif g.id~=KERN then finish() end
    g=following
  end
  finish()
  return head
end
function word_hyphenation.flush()
  if not next(word_hyphenation.queries) and not word_hyphenation.source then
    local old=io.open(tex.jobname..'.docxlike-hyphenation-requests.json','rb')
    if not old then return end
    old:close()
  end
  local queries,missing={},0
  for _,query in pairs(word_hyphenation.queries) do
    queries[#queries+1]=query
    if not query.available then missing=missing+1 end
  end
  table.sort(queries,function(a,b)return word_hyphenation.key(a.tag,a.mode,a.word)<word_hyphenation.key(b.tag,b.mode,b.word)end)
  local data={kind='docxlike-word-hyphenation-requests-v1',job=tex.jobname,queries=queries,
    office_version=word_hyphenation.source or false,cache_hits=word_hyphenation.hits,missing_queries=missing}
  local file=assert(io.open(tex.jobname..'.docxlike-hyphenation-requests.json','wb'))
  file:write(utilities.json.tostring(data));file:close()
  texio.write_nl('DOCXLIKE-WORD-HYPHENATION queries='..#queries..' missing='..missing..' hits='..word_hyphenation.hits)
end
function word_hyphenation.install()
  if word_hyphenation.installed then return end
  word_hyphenation.installed=true
  word_hyphenation.empty_language=word_hyphenation.empty_language or lang.new()
  if not word_hyphenation.loaded then
    word_hyphenation.load()
    word_hyphenation.loaded=true
  end
  luatexbase.add_to_callback('hyphenate',word_hyphenation.collect,'docxlike.word-hyphenation-language')
  luatexbase.declare_callback_rule('hyphenate','docxlike.word-hyphenation-language','before','ltj.hyphenate')
  luatexbase.add_to_callback('pre_shaping_filter',word_hyphenation.insert,'docxlike.word-hyphenation')
  luatexbase.declare_callback_rule('pre_shaping_filter','docxlike.word-hyphenation','before','docxlike.explicit-breaks')
  luatexbase.add_to_callback('stop_run',word_hyphenation.flush,'docxlike.word-hyphenation-data')
end

function M.install(attr, ks, xks, kern, code)
  M.wrap_init()
  M.attr = attr
  M.graphemes = M.graphemes or require('lua-uni-graphemes')
  M.cluster_attr = M.cluster_attr or luatexbase.new_attribute("docxlike@cluster@attr")
  M.cluster_start_attr = M.cluster_start_attr or luatexbase.new_attribute("docxlike@clusterstart@attr")
  M.soft_hyphen_attr = M.soft_hyphen_attr or luatexbase.new_attribute("docxlike@softhyphen@attr")
  M.kern_attr = kern
  M.ks_attr, M.xks_attr = ks, xks
  M.code_attr = code
  M.spacefont_attr = luatexbase.attributes["docxlike@spacefont@attr"]
  M.balanced_space_attr = luatexbase.attributes["docxlike@balancedspace@attr"]
  M.language_attr = luatexbase.attributes["docxlike@language@attr"]
  M.cell_attr = luatexbase.attributes["docxlike@cell@attr"]
  M.table_attr = luatexbase.attributes["docxlike@table@attr"]
  M.picture_attr = luatexbase.attributes["docxlike@picture@attr"]
  M.done_attr = luatexbase.attributes["docxlike@grid@attr"]
  M.nosnap_attr = luatexbase.attributes["docxlike@nosnap@attr"]
  install_native_boundary()
  local descriptions = luatexbase.callback_descriptions("build_page_insert")
  if #descriptions <= 1 and not M.note_insert_base then
    local description = descriptions[1]
    local base = description and luatexbase.remove_from_callback("build_page_insert", description)
    M.note_insert_base = {base, description}
    luatexbase.add_to_callback("build_page_insert", function(index, ordinal)
      begin_note_story(index)
      return base and base(index, ordinal) or index
    end, "docxlike.note-story")
  end
  luatexbase.add_to_callback("pre_shaping_filter", explicit_breaks, "docxlike.explicit-breaks")
  word_hyphenation.install()
  luatexbase.add_to_callback("linebreak_filter",
    function(h, d) return M.filter(h, d) end, "docxlike.linebreak")
  luatexbase.add_to_callback("post_linebreak_filter",
    function(h)
      pin_exact(h)
      local leading = previous_body_leading()
      for line in traverse_id(HLIST, h) do
        if line.subtype == 1 then
          for n in traverse(line.list) do
            local p = node.getproperty(n)
            if p and p.docxlike_incoming_leading ~= nil then
              leading = p.docxlike_incoming_leading; break
            end
          end
          break
        end
      end
      h = paragraph_boundary(h, leading)
      if getbool('l__docxlike_format_owned_par_bool') then
        tag_paragraph(h)
        if tex.nest.ptr == 0 and not getbool('l__docxlike_format_keep_next_bool') then
          h = flush_held_keep_note(h)
        end
      end
      if tex.nest.ptr == 0 and note_body_context(h) then
        local footnote_class = token.create("footins").mode
        for insertion in traverse_id(INS, h) do
          if insertion.subtype == footnote_class
              and not (node.getproperty(insertion) or {}).docxlike_note_coordinated then
            tag_paragraph(h)
            h = coordinate_notes(h)
            break
          end
        end
      end
      h = M.relax_oversized_keep_lines(h)
      M.retain_fitting_legacy_keep_next(h)
      h = legacy_relaxed_blank(h)
      return h
    end, "docxlike.exact")
  if ks and xks then
    luatexbase.add_to_callback("hpack_filter",
      function(h) fix_skips(h); return true end, "docxlike.skips")
    luatexbase.add_to_callback("pre_linebreak_filter",
      function(h) fix_skips(h); return true end, "docxlike.skips")
  end
  if M.cell_attr then
    luatexbase.add_to_callback("hpack_filter",
      function(h) grid_box(h); return true end, "docxlike.cells")
  end
  M.mcell_attr = luatexbase.attributes["docxlike@mcell@attr"]
  M.ptop_attr = luatexbase.attributes["docxlike@ptop@attr"]
  if M.mcell_attr then
    luatexbase.add_to_callback("hpack_filter",
      function(h, gc) if gc == "fin_row" then cell_top(h); mcell_center(h) end; return true end, "docxlike.mcell")
  end
  luatexbase.add_to_callback("hyphenate", function(h) latin_hint(h) end, "docxlike.hint")
  if luatexbase.declare_callback_rule then
    luatexbase.declare_callback_rule("hyphenate", "docxlike.hint", "before", LTJ.SPLIT_CALLBACK)
  end
end
function M.uninstall()
  if word_hyphenation.installed then word_hyphenation.flush() end
  if M.note_insert_base and luatexbase.in_callback("build_page_insert", "docxlike.note-story") then
    luatexbase.remove_from_callback("build_page_insert", "docxlike.note-story")
    if M.note_insert_base[1] then
      luatexbase.add_to_callback("build_page_insert", M.note_insert_base[1], M.note_insert_base[2])
    end
    M.note_insert_base = nil
  end
  if M.native_append_base and luatexbase.in_callback("append_to_vlist_filter", "docxlike.native-boundary") then
    luatexbase.remove_from_callback("append_to_vlist_filter", "docxlike.native-boundary")
    luatexbase.add_to_callback("append_to_vlist_filter", M.native_append_base[1], M.native_append_base[2])
    M.native_append_base = nil
  end
  if docxlike and docxlike.page then docxlike.page.wrap_native() end
  for _, cb in ipairs({ { "linebreak_filter", "docxlike.linebreak" }, { "hpack_filter", "docxlike.skips" },
                        { "pre_shaping_filter", "docxlike.explicit-breaks" },
                        { "hpack_filter", "docxlike.cells" }, { "hpack_filter", "docxlike.mcell" },
                        { "pre_linebreak_filter", "docxlike.skips" },
                         { "post_linebreak_filter", "docxlike.exact" },
                         { "pre_shaping_filter", "docxlike.word-hyphenation" },
                         { "hyphenate", "docxlike.word-hyphenation-language" },
                         { "stop_run", "docxlike.word-hyphenation-data" },
                         { "hyphenate", "docxlike.hint" } }) do
    if luatexbase.in_callback(cb[1], cb[2]) then luatexbase.remove_from_callback(cb[1], cb[2]) end
  end
  word_hyphenation.installed=false
end

return M
end
factories.ltj = function()

local M = { tested = "20260517.0" }
M.icflag_tested = { PACKED = 2, KINSOKU = 3, FROM_JFM = 4, KANJI_SKIP = 68, KANJI_SKIP_JFM = 69,
  XKANJI_SKIP = 70, XKANJI_SKIP_JFM = 71, PROCESSED_BEGIN_FLAG = 4096 }
M.attributes = { "ltj@icflag", "ltj@curjfnt", "ltj@autospc", "ltj@autoxspc" }
for i = 0, 6 do M.attributes[#M.attributes + 1] = "ltj@kcat" .. i end
M.FONT_SETUP_CALLBACK = "ltj.set_stack_level"
M.SPLIT_CALLBACK = "ltj.hyphenate"
M.callbacks = { { "pre_linebreak_filter", M.FONT_SETUP_CALLBACK },
  { "hpack_filter", M.FONT_SETUP_CALLBACK }, { "hyphenate", M.SPLIT_CALLBACK } }

local get_attr, has_attr, set_attr = node.get_attribute, node.has_attribute, node.set_attribute
local IC, BEGIN, ICF, CUR, AUTOSPC, AUTOXSPC, FMT, CR = {}, 4096
local PACKED, KINSOKU, FROM_JFM, KS, KSJ, XKS, XKSJ = 2, 3, 4, 68, 69, 70, 71

function M.resolve()
  local ja = rawget(_G, "luatexja")
  M.available = type(ja) == "table" and type(ja.icflag_table) == "table"
  if not M.available then return end
  IC = ja.icflag_table
  BEGIN = IC.PROCESSED_BEGIN_FLAG or 4096
  PACKED, KINSOKU, FROM_JFM = IC.PACKED, IC.KINSOKU, IC.FROM_JFM
  KS, KSJ, XKS, XKSJ = IC.KANJI_SKIP, IC.KANJI_SKIP_JFM, IC.XKANJI_SKIP, IC.XKANJI_SKIP_JFM
  local A = luatexbase.attributes
  ICF, CUR, AUTOSPC, AUTOXSPC = A["ltj@icflag"], A["ltj@curjfnt"], A["ltj@autospc"], A["ltj@autoxspc"]
  FMT = ja.jfont and ja.jfont.font_metric_table
  CR = ja.charrange
end
M.resolve()


local function icflag(n) return ICF and (get_attr(n, ICF) or 0) % BEGIN or 0 end
M.icflag = icflag
function M.is_packed(n) return icflag(n) == PACKED end
function M.is_kinsoku(n) return icflag(n) == KINSOKU end
function M.is_jfmglue(n) local ic = icflag(n); return ic >= FROM_JFM and ic < KS end
function M.is_kanjiskip(n) local ic = icflag(n); return ic == KS or ic == KSJ end
function M.is_xkanjiskip(n) local ic = icflag(n); return ic == XKS or ic == XKSJ end
function M.is_inserted_glue(n) return icflag(n) >= FROM_JFM end
function M.unprocessed(n) return ICF ~= nil and has_attr(n, ICF, 0) ~= nil end
function M.is_jfont(f) return FMT ~= nil and FMT[f] ~= nil end
function M.alias_jfont(new, old) if FMT and FMT[old] then FMT[new] = FMT[old] end end
function M.jfont_of(n) return CUR and get_attr(n, CUR) end
function M.set_jfont(n, id) set_attr(n, CUR, id) end
function M.autospacing_off(n, kind)
  local a = kind == "xkanjiskip" and AUTOXSPC or AUTOSPC
  return a ~= nil and get_attr(n, a) == 0
end
function M.is_cjk_char(n) return CR ~= nil and CR.is_ucs_in_japanese_char(n) end

function M.make_latin(n)
  local r = CR.char_to_range(n.char)
  if r and r > 0 and r < 217 then
    local ka = luatexbase.attributes["ltj@kcat" .. math.floor(r / 31)]
    set_attr(n, ka, (has_attr(n, ka) or 0) | (1 << (r % 31)))
  end
end

function M.check()
  M.resolve()
  local bad = {}
  local function miss(s) bad[#bad + 1] = s end
  local ja = rawget(_G, "luatexja")
  if type(ja) ~= "table" then return { "the luatexja Lua table" } end
  local ic = ja.icflag_table
  if type(ic) ~= "table" then miss("luatexja.icflag_table") else
    local keys = {}
    for k in pairs(M.icflag_tested) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      if ic[k] ~= M.icflag_tested[k] then
        miss(string.format("luatexja.icflag_table.%s = %s (tested %d)", k, tostring(ic[k]), M.icflag_tested[k]))
      end
    end
  end
  if not (type(ja.jfont) == "table" and type(ja.jfont.font_metric_table) == "table") then
    miss("luatexja.jfont.font_metric_table")
  end
  local cr = ja.charrange
  if not (type(cr) == "table" and type(cr.char_to_range) == "function"
      and type(cr.is_ucs_in_japanese_char) == "function") then
    miss("luatexja.charrange.char_to_range/is_ucs_in_japanese_char")
  elseif cr.ATTR_RANGE ~= 7 then
    miss("luatexja.charrange.ATTR_RANGE = " .. tostring(cr.ATTR_RANGE) .. " (tested 7)")
  end
  for _, a in ipairs(M.attributes) do
    if not luatexbase.attributes[a] then miss("attribute " .. a) end
  end
  for _, c in ipairs(M.callbacks) do
    local found = false
    for _, d in ipairs(luatexbase.callback_descriptions(c[1])) do
      if d == c[2] then found = true end
    end
    if not found then miss("callback " .. c[2] .. " in " .. c[1]) end
  end
  return bad
end
return M
end
local runtime = { format = 1 }
function runtime.load(name)
  local factory = assert(factories[name], 'Unknown docxlike module: ' .. tostring(name))
  if not loaded[name] then
    local module = factory()
    assert(type(module) == 'table', 'Invalid docxlike module: ' .. name)
    loaded[name] = module
  end
  return loaded[name]
end
return runtime
