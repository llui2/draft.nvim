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
  -- Mark editable arrows by stroke color, preserving the exact TikZ path.
  -- pdftocairo emits the shaft and arrowhead as separate SVG paths.
  for index, arrow in ipairs(require("draft.sync").editable_arrows(source)) do
    local red, green, blue = marker_color(#labels + index)
    local rgb = string.format("%d,%d,%d", red, green, blue)
    colors[rgb] = arrow
    table.insert(replacements, {
      first = arrow.first, last = arrow.last,
      value = source:sub(arrow.first, arrow.last - 1)
        .. string.format(",draw={rgb,255:red,%d;green,%d;blue,%d}]", red, green, blue),
    })
  end
  table.sort(replacements, function(a, b) return a.first > b.first end)
  for _, replacement in ipairs(replacements) do
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
  svg = svg:gsub('<g fill="rgb%(([^)]*)%)"([^>]*)>', function(rgb, attributes)
    local red, green, blue = rgb:match("([%d%.]+)%%,%s*([%d%.]+)%%,%s*([%d%.]+)%%")
    if not red then return '<g fill="rgb(' .. rgb .. ')"' .. attributes .. '>' end
    local key = string.format("%d,%d,%d",
      math.floor(tonumber(red) * 255 / 100 + 0.5),
      math.floor(tonumber(green) * 255 / 100 + 0.5),
      math.floor(tonumber(blue) * 255 / 100 + 0.5))
    local label = expected[key]
    if not label or label.color then return '<g fill="rgb(' .. rgb .. ')"' .. attributes .. '>' end
    return string.format('<g data-draft-node="%s" data-draft-xshift="%s" data-draft-yshift="%s" fill="rgb(0%%, 0%%, 0%%)"%s>',
      label.name, label.xshift, label.yshift, attributes)
  end)
  return svg:gsub('<path ([^>]-)>', function(attributes)
    local color = attributes:match('stroke="rgb%(([^)]*)%)"')
    if not color then return '<path ' .. attributes .. '>' end
    local red, green, blue = color:match("([%d%.]+)%%,%s*([%d%.]+)%%,%s*([%d%.]+)%%")
    if not red then return '<path ' .. attributes .. '>' end
    local key = string.format("%d,%d,%d",
      math.floor(tonumber(red) * 255 / 100 + 0.5),
      math.floor(tonumber(green) * 255 / 100 + 0.5),
      math.floor(tonumber(blue) * 255 / 100 + 0.5))
    local arrow = expected[key]
    if not arrow or not arrow.color then return '<path ' .. attributes .. '>' end
    local original = arrow.color == "gray" and "rgb(50%, 50%, 50%)" or "rgb(0%, 0%, 0%)"
    attributes = attributes:gsub('stroke="rgb%([^)]*%)"', 'stroke="' .. original .. '"', 1)
    return string.format('<path data-draft-node="%s" data-draft-xshift="%s" data-draft-yshift="%s" %s>',
      arrow.name, arrow.xshift, arrow.yshift, attributes)
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
  local line, message, context = output:match(":(%d+): ([^\n]+)\n(l%.%d+[^\n]+)")
  if message then return "Line " .. line .. ": " .. message .. "\n" .. context end
  local detail = output:match("! [^\n]+") or output:match("LaTeX Error:[^\n]+") or output:match("Latexmk: All targets[^\n]+")
  return detail or output:sub(-1800):gsub("^%s+", "")
end

local directory
local running, pending, cached
local revision = 0
local start_next

local function dependencies()
  local files = {}
  local recorder = directory and vim.fs.joinpath(directory, "out", "figure.fls")
  if not recorder or vim.fn.filereadable(recorder) ~= 1 then return files end
  for _, line in ipairs(vim.fn.readfile(recorder)) do
    local path = line:match("^INPUT (.+)")
    if path then
      path = vim.fs.normalize(path)
      if path:sub(1, #directory) ~= directory then
        local stat = vim.uv.fs_stat(path)
        if stat then files[path] = { size = stat.size, sec = stat.mtime.sec, nsec = stat.mtime.nsec } end
      end
    end
  end
  return files
end

local function cache_valid()
  for path, prior in pairs(cached.files) do
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.size ~= prior.size or stat.mtime.sec ~= prior.sec or stat.mtime.nsec ~= prior.nsec then return false end
  end
  return true
end

-- Invalidate immediately on an edit, including before the next source publication.
function M.invalidate()
  revision = revision + 1
  pending = nil
end

local function compile(request)
  local source, callback = request.source, request.callback
  local instrumented, marker_colors = M.instrument(source)
  local document = M.document(instrumented)
  if not document then callback(nil, "No standalone TikZ figure"); return end
  if vim.fn.executable("latexmk") ~= 1 then callback(nil, "latexmk is not installed"); return end
  if vim.fn.executable("pdftocairo") ~= 1 then callback(nil, "pdftocairo is not installed (needed to convert the PDF to SVG)"); return end

  directory = directory or vim.fn.tempname() -- Neovim owns and removes this session directory.
  local output = vim.fs.joinpath(directory, "out")
  vim.fn.mkdir(output, "p")
  local input = vim.fs.joinpath(directory, "figure.tex")
  local written = vim.fn.writefile(vim.split(document, "\n", { plain = true }), input)
  if written ~= 0 then callback(nil, "could not write temporary TikZ source"); return end

  local function finish(svg, err)
    vim.schedule(function()
      callback(svg, err)
    end)
  end
  local command = {
    "latexmk", "-pdf", "-halt-on-error", "-interaction=nonstopmode", "-file-line-error",
    "-outdir=" .. output, "-auxdir=" .. output, input,
  }
  local ok, err = pcall(vim.system, command, { text = true }, function(result)
    vim.schedule(function()
      if request.revision ~= revision then finish(nil); return end
      if result.code ~= 0 then finish(nil, failure(result)); return end
      local pdf = vim.fs.joinpath(output, "figure.pdf")
      local svg = vim.fs.joinpath(directory, "figure.svg")
      local converted, convert_err = pcall(vim.system, { "pdftocairo", "-r", "300", "-svg", "-f", "1", "-l", "1", pdf, svg }, { text = true }, function(conversion)
        vim.schedule(function()
          if request.revision ~= revision then finish(nil); return end
          if conversion.code ~= 0 then finish(nil, failure(conversion)); return end
          local contents = vim.fn.readfile(svg)
          if #contents == 0 then finish(nil, "PDF to SVG conversion produced no output"); return end
          local vector = table.concat(contents, "\n")
          -- feImage fits referenced groups to their bounding boxes in WebKit.
          -- Cairo expects every input to cover the filter's full viewport,
          -- including empty destinations and partially painted shading groups.
          local bounds = {}
          for attributes in vector:gmatch("<feImage ([^>]+)>") do
            local id = attributes:match('href="#([^"]+)"')
            local width, height = attributes:match('width="([%d.]+)" height="([%d.]+)"')
            if id and width then bounds[id] = { width, height } end
          end
          vector = vector:gsub('(<g id="(compositing%-group%-%d+)"[^>]*>)', function(open, id)
            local size = bounds[id]
            if not size then return open end
            return open .. string.format('<rect width="%s" height="%s" fill-opacity="0"/>', size[1], size[2])
          end)
          local _, composites = vector:gsub("<feComposite", "")
          if composites <= 1 then finish(annotate_svg(vector, marker_colors), nil); return end
          -- Separate Cairo shading tiles acquire seams in WebKit. Render the
          -- authoritative PDF only for this case, retaining its page bounds.
          local function rasterize()
            local png = vim.fs.joinpath(directory, "figure")
            local raster_ok, raster_err = pcall(vim.system,
              { "pdftocairo", "-png", "-singlefile", "-r", "300", "-f", "1", "-l", "1", pdf, png },
              { text = true }, function(raster)
                vim.schedule(function()
                  if request.revision ~= revision then finish(nil); return end
                  if raster.code ~= 0 then finish(nil, failure(raster)); return end
                  local file = io.open(png .. ".png", "rb")
                  if not file then finish(nil, "PDF raster conversion produced no output"); return end
                  local data = file:read("*a"); file:close()
                  local width, height = vector:match('viewBox="0 0 ([%d.]+) ([%d.]+)"')
                  if not width then finish(nil, "PDF conversion has no page bounds"); return end
                  finish(string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%spt" height="%spt" viewBox="0 0 %s %s" data-draft-raster="true"><image width="%s" height="%s" href="data:image/png;base64,%s"/></svg>',
                    width, height, width, height, width, height, vim.base64.encode(data)))
                end)
              end)
            if not raster_ok then finish(nil, tostring(raster_err)) end
          end
          -- Marker colors are for vector editing; the raster must use the
          -- original text colors. Raster figures have no draggable SVG nodes.
          if next(marker_colors) then
            vim.fn.writefile(vim.split(M.document(source), "\n", { plain = true }), input)
            local original_ok, original_err = pcall(vim.system, command, { text = true }, function(original)
              vim.schedule(function()
                if request.revision ~= revision then finish(nil); return end
                if original.code ~= 0 then finish(nil, failure(original)); return end
                rasterize()
              end)
            end)
            if not original_ok then finish(nil, tostring(original_err)) end
          else rasterize() end
        end)
      end)
      if not converted then finish(nil, tostring(convert_err)) end
    end)
  end)
  if not ok then callback(nil, tostring(err)) end
end

start_next = function()
  if running or not pending then return end
  local request = pending
  pending, running = nil, true
  compile({ source = request.source, revision = request.revision, callback = function(svg, err)
    running = false
    if request.revision == revision then
      if svg then cached = { source = request.source, svg = svg, files = dependencies() } end
      request.callback(svg, err)
    end
    start_next()
  end })
end

function M.compile(source, callback)
  M.invalidate()
  local current = revision
  if cached and cached.source == source and cache_valid() then
    vim.schedule(function() if current == revision then callback(cached.svg) end end)
    return
  end
  pending = { source = source, callback = callback, revision = current }
  start_next()
end

return M
