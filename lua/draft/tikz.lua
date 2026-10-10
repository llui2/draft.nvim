local M = {}

local function skip_space(source, cursor)
  while cursor <= #source do
    local char = source:sub(cursor, cursor)
    if char:match("%s") then
      cursor = cursor + 1
    elseif char == "%" then
      local newline = source:find("\n", cursor, true)
      if not newline then return #source + 1 end
      cursor = newline + 1
    else
      break
    end
  end
  return cursor
end

local function balanced_end(source, first, open, close)
  if source:sub(first, first) ~= open then return nil end
  local depth, cursor = 1, first + 1
  while cursor <= #source do
    local char = source:sub(cursor, cursor)
    if char == "\\" then
      cursor = cursor + 2
    elseif char == "%" then
      local newline = source:find("\n", cursor, true)
      if not newline then return nil end
      cursor = newline + 1
    else
      if char == open then depth = depth + 1 end
      if char == close then
        depth = depth - 1
        if depth == 0 then return cursor end
      end
      cursor = cursor + 1
    end
  end
end

local function split_options(source, first, last)
  local parts, start, braces, escaped = {}, first, 0, false
  for cursor = first, last do
    local char = source:sub(cursor, cursor)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "{" then
      braces = braces + 1
    elseif char == "}" and braces > 0 then
      braces = braces - 1
    elseif char == "," and braces == 0 then
      table.insert(parts, source:sub(start, cursor - 1))
      start = cursor + 1
    end
  end
  table.insert(parts, source:sub(start, last))
  return parts
end

local function named_labels(source)
  local candidates, counts, cursor = {}, {}, 1
  while cursor <= #source do
    local first = source:find("\\node", cursor, true)
    local comment = source:find("%", cursor, true)
    if comment and (not first or comment < first) then
      local newline = source:find("\n", comment, true)
      cursor = newline and newline + 1 or #source + 1
      goto continue
    end
    if not first then break end
    cursor = first + 5
    if source:sub(cursor, cursor):match("[%a@]") then goto continue end
    local option_first = skip_space(source, cursor)
    local option_last = balanced_end(source, option_first, "[", "]")
    if not option_last then goto continue end

    local fields, keys = {}, {}
    for _, item in ipairs(split_options(source, option_first + 1, option_last - 1)) do
      local key, value = item:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key then
        keys[key] = (keys[key] or 0) + 1
        fields[key] = value
      else
        keys[(item:match("^%s*([%w_]+)") or "")] = (keys[(item:match("^%s*([%w_]+)") or "")] or 0) + 1
      end
    end
    local name = fields.name
    if name and name:match("^[%a_][%w_%-]*$") then counts[name] = (counts[name] or 0) + 1 end
    local supported = name and name:match("^[%a_][%w_%-]*$")
      and keys.name == 1 and keys.xshift == 1 and keys.yshift == 1
      and not keys.color and not keys.text
      and fields.xshift and fields.xshift:match("^[+-]?%d+%.?%d*pt$")
      and fields.yshift and fields.yshift:match("^[+-]?%d+%.?%d*pt$")

    local label_first, label_last = nil, nil
    local scan = option_last + 1
    while scan <= #source do
      scan = skip_space(source, scan)
      local char = source:sub(scan, scan)
      if char == ";" or char == "" then break end
      if char == "(" then
        local finish = balanced_end(source, scan, "(", ")")
        if not finish then break end
        scan = finish + 1
      elseif char == "[" then
        local finish = balanced_end(source, scan, "[", "]")
        if not finish then break end
        scan = finish + 1
      elseif char == "{" then
        local finish = balanced_end(source, scan, "{", "}")
        if not finish then break end
        label_first, label_last = scan, finish
        break
      else
        scan = scan + 1
      end
    end
    if supported and label_first then
        table.insert(candidates, { name = name, xshift = tonumber((fields.xshift:gsub("pt$", ""))),
          yshift = tonumber((fields.yshift:gsub("pt$", ""))), first = label_first, last = label_last })
    end
    cursor = (label_last or option_last) + 1
    ::continue::
  end

  local labels = {}
  for _, candidate in ipairs(candidates) do
    if counts[candidate.name] == 1 then table.insert(labels, candidate) end
  end
  return labels
end

local function marker_color(index)
  local n = index - 1
  local red = 17 + (n % 220)
  local green = 29 + (math.floor(n / 220) % 220)
  local blue = 41 + (math.floor(n / (220 * 220)) % 210)
  return red, green, blue
end

function M.instrument(source)
  local labels = named_labels(source)
  local replacements, colors = {}, {}
  for index, label in ipairs(labels) do
    local red, green, blue = marker_color(index)
    local color = string.format("%d,%d,%d", red, green, blue)
    colors[color] = label
    table.insert(replacements, {
      first = label.first,
      last = label.last,
      value = string.format("{\\begingroup\\color[RGB]{%s}%s\\endgroup}", color, source:sub(label.first + 1, label.last - 1)),
    })
  end
  for index = #replacements, 1, -1 do
    local replacement = replacements[index]
    source = source:sub(1, replacement.first - 1) .. replacement.value .. source:sub(replacement.last + 1)
  end
  return source, colors
end

local function annotate_svg(svg, colors)
  local expected = {}
  for rgb, label in pairs(colors) do
    local red, green, blue = rgb:match("^(%d+),(%d+),(%d+)$")
    expected[string.format("%d,%d,%d", tonumber(red), tonumber(green), tonumber(blue))] = label
  end
  return svg:gsub('<g fill="rgb%(([^)]*)%)"([^>]*)>', function(rgb, attributes)
    local red, green, blue = rgb:match("([%d%.]+)%%,%s*([%d%.]+)%%,%s*([%d%.]+)%%")
    if not red then return '<g fill="rgb(' .. rgb .. ')"' .. attributes .. '>' end
    local key = string.format("%d,%d,%d",
      math.floor(tonumber(red) * 255 / 100 + 0.5),
      math.floor(tonumber(green) * 255 / 100 + 0.5),
      math.floor(tonumber(blue) * 255 / 100 + 0.5))
    local label = expected[key]
    if not label then return '<g fill="rgb(' .. rgb .. ')"' .. attributes .. '>' end
    return string.format('<g data-draft-node="%s" data-draft-xshift="%s" data-draft-yshift="%s" fill="rgb(0%%, 0%%, 0%%)"%s>',
      label.name, label.xshift, label.yshift, attributes)
  end)
end

local function figure_start(source)
  local first, last = source:find("\\begin%s*{tikzpicture%*?}")
  return first, last
end

function M.is_standalone(source)
  if not figure_start(source) then return false end
  return source:match("\\documentclass%s*%b[]%s*{standalone}") ~= nil
    or source:match("\\documentclass%s*{standalone}") ~= nil
    or not source:match("\\begin%s*{document}")
end

function M.document(source)
  if not M.is_standalone(source) then return nil end
  if source:match("\\documentclass") then
    if source:match("\\begin%s*{document}") then return source end
    local first = figure_start(source)
    if not first then return source end
    return source:sub(1, first - 1) .. "\\begin{document}\n" .. source:sub(first) .. "\n\\end{document}\n"
  end

  local preamble = "\\documentclass[tikz,border=2pt]{standalone}\n\\usepackage{tikz}\n\\usepackage{pgfplots}\n\\pgfplotsset{compat=1.18}\n"
  if source:match("\\begin%s*{document}") then return preamble .. source end
  local first = figure_start(source)
  if not first then return nil end
  return preamble .. source:sub(1, first - 1) .. "\\begin{document}\n" .. source:sub(first) .. "\n\\end{document}\n"
end

local function failure(result)
  local output = ((result and result.stdout) or "") .. "\n" .. ((result and result.stderr) or "")
  local detail = output:match("! [^\n]+") or output:match("LaTeX Error:[^\n]+") or output:match("Latexmk: All targets[^\n]+")
  return detail or output:sub(-1800):gsub("^%s+", "")
end

function M.compile(source, callback)
  local instrumented, marker_colors = M.instrument(source)
  local document = M.document(instrumented)
  if not document then callback(nil, "No standalone TikZ figure"); return end
  if vim.fn.executable("latexmk") ~= 1 then callback(nil, "latexmk is not installed"); return end
  if vim.fn.executable("pdftocairo") ~= 1 then callback(nil, "pdftocairo is not installed (needed to convert the PDF to SVG)"); return end

  local directory = vim.fn.tempname()
  local output = vim.fs.joinpath(directory, "out")
  vim.fn.mkdir(output, "p")
  local input = vim.fs.joinpath(directory, "figure.tex")
  local written = vim.fn.writefile(vim.split(document, "\n", { plain = true }), input)
  if written ~= 0 then vim.fn.delete(directory, "rf"); callback(nil, "could not write temporary TikZ source"); return end

  local function finish(svg, err)
    vim.schedule(function()
      vim.fn.delete(directory, "rf")
      callback(svg, err)
    end)
  end
  local command = {
    "latexmk", "-pdf", "-halt-on-error", "-interaction=nonstopmode", "-file-line-error",
    "-outdir=" .. output, "-auxdir=" .. output, input,
  }
  local ok, err = pcall(vim.system, command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then finish(nil, failure(result)); return end
      local pdf = vim.fs.joinpath(output, "figure.pdf")
      local svg = vim.fs.joinpath(directory, "figure.svg")
      local converted, convert_err = pcall(vim.system, { "pdftocairo", "-svg", "-f", "1", "-l", "1", pdf, svg }, { text = true }, function(conversion)
        vim.schedule(function()
          if conversion.code ~= 0 then finish(nil, failure(conversion)); return end
          local contents = vim.fn.readfile(svg)
          if #contents == 0 then finish(nil, "PDF to SVG conversion produced no output"); return end
          finish(annotate_svg(table.concat(contents, "\n"), marker_colors), nil)
        end)
      end)
      if not converted then finish(nil, tostring(convert_err)) end
    end)
  end)
  if not ok then vim.fn.delete(directory, "rf"); callback(nil, tostring(err)) end
end

return M
