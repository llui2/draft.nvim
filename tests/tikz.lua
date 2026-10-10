-- Standalone TikZ detection, asynchronous LaTeX compilation and PDF-to-SVG.
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
local pgfplotsLabel = table.concat(vim.fn.readfile("tests/fixtures/pgfplots-label.tex"), "\n")
local tikzLabels = table.concat(vim.fn.readfile("tests/fixtures/tikz-labels.tex"), "\n")

assert(tikz.is_standalone(diagram))
assert(tikz.is_standalone(plot2d))
assert(tikz.is_standalone(surface3d))
assert(tikz.is_standalone(pgfplotsLabel))
assert(tikz.is_standalone(tikzLabels))
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
  assert(result and result:match("<svg") and result:match("<path"), failure or ("figure " .. index .. " did not produce vector SVG"))
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
print("Draft: TikZ diagram, 2D/3D PGFPlots and source-identified editable labels passed")
