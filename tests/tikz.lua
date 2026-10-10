-- Standalone TikZ detection, asynchronous LaTeX compilation and 2D SVG / 3D PNG.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local tikz = require("draft.tikz")

local diagram = [[
\documentclass[tikz,border=2pt]{standalone}
\begin{document}
\begin{tikzpicture}
  \draw (0,0) -- (1,1) node[right] {diagram};
\end{tikzpicture}
\end{document}
]]
local plot2d = [[
\documentclass[tikz,border=2pt]{standalone}
\usepackage{pgfplots}
\begin{document}
\begin{tikzpicture}
  \begin{axis}\addplot {x^2};\end{axis}
\end{tikzpicture}
\end{document}
]]
local surface3d = [[
\documentclass[tikz,border=2pt]{standalone}
\usepackage{pgfplots}
\pgfplotsset{compat=1.18}
\begin{document}
\begin{tikzpicture}
  \begin{axis}[view={35}{25}]\addplot3[surf,domain=-2:2] {sin(deg(x*y))};\end{axis}
\end{tikzpicture}
\end{document}
]]
local arrowSource = table.concat(vim.fn.readfile("templates/annotated-curves.tex"), "\n")
local arrows = require("draft.sync").editable_arrows(arrowSource)
assert(#arrows == 1 and arrows[1].name == "draft-path-1", "annotated arrow was not recognized")
local markedArrow = tikz.instrument(arrowSource)
assert(markedArrow:find("draw={rgb,255:red,", 1, true), "arrow was not marked in TeX")
local pgfplotsLabel = table.concat(vim.fn.readfile("tests/fixtures/pgfplots-label.tex"), "\n")
local tikzLabels = table.concat(vim.fn.readfile("tests/fixtures/tikz-labels.tex"), "\n")

assert(tikz.is_standalone(diagram))
assert(tikz.is_standalone(plot2d))
assert(tikz.is_standalone(surface3d))
assert(tikz.is_standalone(pgfplotsLabel))
assert(tikz.is_standalone(tikzLabels))
assert(tikz.is_3d(surface3d) and not tikz.is_3d(plot2d))
assert(tikz.is_3d("\\begin{axis}[shader=faceted interp] \\end{axis}"))
assert(not tikz.is_3d("% \\addplot3[surf] commented out\n" .. plot2d))
assert(not tikz.is_standalone("\\begin{document}\\begin{tikzpicture}x\\end{tikzpicture}\\end{document}"))
local _, commentedMarkers = tikz.instrument([[% \node[name=ignored,xshift=0pt,yshift=0pt] {same text};
\node[name=kept,xshift=0pt,yshift=0pt] {same text};]])
assert(commentedMarkers["17,29,41"] and commentedMarkers["17,29,41"].name == "kept")
local _, duplicateMarkers = tikz.instrument([[\node[name=same,xshift=0pt,yshift=0pt] {A};
\node[name=same,xshift=0pt,yshift=0pt,color=red] {A};]])
assert(next(duplicateMarkers) == nil, "duplicate identifiers must not become editable SVG targets")
local fragment = "\\usetikzlibrary{arrows.meta}\n\\begin{tikzpicture}\\draw (0,0)--(1,1);\\end{tikzpicture}"
assert(tikz.document(fragment):match("\\documentclass%[tikz,border=2pt%]"))
assert(tikz.document(fragment):match("\\usetikzlibrary"))

if vim.fn.executable("latexmk") ~= 1 or vim.fn.executable("pdftocairo") ~= 1 then
  print("Draft: TikZ detection passed; LaTeX/PDF-to-SVG integration skipped (latexmk or pdftocairo missing)")
  return
end

local responsive = false
local result, failure
local figures = { diagram, plot2d, surface3d }
for index, source in ipairs(figures) do
  responsive = false
  result, failure = nil, nil
  tikz.compile(source, function(svg, err) result, failure = svg, err end)
  vim.schedule(function() responsive = true end)
  assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end), "TikZ compile timed out")
  assert(responsive, "TikZ compilation blocked Neovim's event loop")
  if index == 3 then
    assert(result and result:find("data:image/png;base64,", 1, true) == 1, failure or "3D figure did not use PDF raster")
  else
    assert(result and result:match("<svg") and result:match("<path"), failure or ("2D figure " .. index .. " lost SVG"))
  end
end

-- Check the actual 3D examples; isolated compilation alone does not prove
-- macOS WebKit fidelity, but catches regressions in their LaTeX sources.
for _, name in ipairs({
  "three-dimensional-surface", "vector-field-3d", "mobius-strip",
  "radial-surface", "singular-surface",
}) do
  result, failure = nil, nil
  local source = table.concat(vim.fn.readfile("templates/" .. name .. ".tex"), "\n")
  tikz.compile(source, function(svg, err) result, failure = svg, err end)
  assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end),
    "3D template compilation timed out: " .. name)
  assert(result and result:find("data:image/png;base64,", 1, true) == 1,
    failure or ("3D template did not use the compiled PDF: " .. name))
end

for _, case in ipairs({
  { source = pgfplotsLabel, names = { "critical" } },
  { source = tikzLabels, names = { "left", "right" } },
}) do
  result, failure = nil, nil
  tikz.compile(case.source, function(svg, err) result, failure = svg, err end)
  assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end), "editable TikZ compile timed out")
  assert(result, failure or "editable label figure did not compile")
  for _, name in ipairs(case.names) do
    assert(result:match('data%-draft%-node="' .. name .. '"'), "SVG lost source node identity " .. name)
  end
  if case.source == pgfplotsLabel then
    assert(result:match('data%-draft%-xshift="1%.25"'))
    assert(result:match('data%-draft%-yshift="%-0%.5"'))
  end
end

result, failure = nil, nil
tikz.compile(arrowSource, function(svg, err) result, failure = svg, err end)
assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end), "editable arrow compiled too slowly")
assert(result and result:match('data%-draft%-node="draft%-path%-1"'),
  failure or "SVG did not identify the arrow shaft and head")
local arrowBuffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(arrowBuffer, 0, -1, false, vim.split(arrowSource, "\n", { plain = true }))
require("draft.sync").set_buffer(arrowBuffer)
local arrowTick = require("draft.sync").node_edit_state().changedtick
local moved = require("draft.sync").update_node_shift("draft-path-1", 4, -2, arrowTick)
assert(moved.ok, moved.error)
local movedArrow = table.concat(vim.api.nvim_buf_get_lines(arrowBuffer, 0, -1, false), "\n")
assert(movedArrow:find("xshift=4pt,yshift=-2pt", 1, true), "arrow movement did not update the source")
assert(movedArrow:find("(axis cs:0.55,0.79) -- (axis cs:0.20,1.10)", 1, true),
  "arrow movement changed its endpoints")
result, failure = nil, nil
tikz.compile(movedArrow, function(svg, err) result, failure = svg, err end)
assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end))
assert(result and result:match('data%-draft%-xshift="4"'), failure or "moved arrow failed to render")

local buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(pgfplotsLabel, "\n", { plain = true }))
require("draft.sync").set_buffer(buffer)
local editState = require("draft.sync").node_edit_state()
local edit = require("draft.sync").update_node_shift("critical", 4.25, 1.75, editState.changedtick)
assert(edit.ok, edit.error)
local updatedSource = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
assert(updatedSource:match("axis cs:0,0"), "label edit changed plot coordinates")
assert(updatedSource:match("xshift=4%.25pt,yshift=1%.75pt"), "label shifts were not written to source")
result, failure = nil, nil
tikz.compile(updatedSource, function(svg, err) result, failure = svg, err end)
assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end), "recompiled edited PGFPlots figure timed out")
assert(result and result:match('data%-draft%-xshift="4%.25"') and result:match('data%-draft%-yshift="1%.75"'),
  failure or "edited label offset did not reach the authoritative SVG")

result, failure = nil, nil
tikz.compile(surface3d:gsub("sin%(deg%(x%*y%)%)", "\\undefinedDraftTikzCommand"), function(svg, err) result, failure = svg, err end)
assert(vim.wait(60000, function() return failure ~= nil end), "invalid TikZ compile timed out")
assert(not result and failure, "invalid TikZ unexpectedly compiled")
assert(failure:find("Undefined control sequence", 1, true), "actual TeX error was hidden")
-- All 3D figures bypass Cairo SVG, while 2D diagrams remain vector.
for _, path in ipairs(vim.fn.glob("templates/*.tex", false, true)) do
  local source = table.concat(vim.fn.readfile(path), "\n")
  result, failure = nil, nil
  tikz.compile(source, function(figure, err) result, failure = figure, err end)
  assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end), path .. " timed out")
  assert(result, failure)
  if tikz.is_3d(source) then
    assert(result:find("data:image/png;base64,", 1, true) == 1, path .. " lost its PDF image path")
  else
    assert(result:find("<svg", 1, true), path .. " lost its editable SVG path")
  end
end

-- Exercise the real queue under rapid editing: no overlapping latexmk,
-- no intermediate output, one latest pending build and a reusable directory.
local system = vim.system
local active, maximum, builds, directory = 0, 0, 0, nil
vim.system = function(command, options, callback)
  if command[1] ~= "latexmk" then return system(command, options, callback) end
  active, builds = active + 1, builds + 1
  maximum = math.max(maximum, active)
  for _, arg in ipairs(command) do
    if arg:match("^%-outdir=") then
      if directory then assert(directory == arg, "compile artifacts were not reused") else directory = arg end
    end
  end
  return system(command, options, function(output) active = active - 1; callback(output) end)
end
local complex = table.concat(vim.fn.readfile("templates/three-dimensional-surface.tex"), "\n")
local stale = 0
local start = vim.uv.hrtime()
tikz.compile(complex .. "\n% first", function() stale = stale + 1 end)
for index = 1, 40 do
  tikz.compile(complex .. "\n% edit " .. index, function() stale = stale + 1 end)
end
local latest = complex .. "\n% latest"
result, failure = nil, nil
tikz.compile(latest, function(svg, err) result, failure = svg, err end)
assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end), "rapid edits timed out")
assert(result, failure)
assert(stale == 0 and maximum == 1 and builds == 2, "queue compiled or displayed superseded edits")
print(string.format("Draft: 42 rapid edits -> %d serial builds, %.1f ms to latest", builds, (vim.uv.hrtime() - start) / 1e6))
local previous = result
start = vim.uv.hrtime()
result = nil
tikz.compile(latest, function(svg) result = svg end)
assert(vim.wait(1000, function() return result ~= nil end))
assert(result == previous and builds == 2, "identical source was recompiled")
print(string.format("Draft: cached complex figure %.2f ms", (vim.uv.hrtime() - start) / 1e6))
-- Cache validity includes LaTeX inputs, not just the editor's source text.
local dependency = vim.fn.tempname() .. ".tex"
vim.fn.writefile({ "First" }, dependency)
local external = diagram:gsub("{diagram}", "{\\input{" .. dependency .. "}}")
result, failure = nil, nil
tikz.compile(external, function(svg, err) result, failure = svg, err end)
assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end))
assert(result, failure)
previous = result
local before = builds
vim.fn.writefile({ "Changed label" }, dependency)
result, failure = nil, nil
tikz.compile(external, function(svg, err) result, failure = svg, err end)
assert(vim.wait(60000, function() return result ~= nil or failure ~= nil end))
assert(result and result ~= previous and builds == before + 1, failure or "changed input returned stale cache")
vim.fn.delete(dependency)
vim.system = system
print("Draft: all templates, latest-only queue, cached artifacts and editable vector labels passed")
