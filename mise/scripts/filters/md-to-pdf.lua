-- Rewrites relative .md links to .pdf for portable document bundles
function Link(el)
  local target = el.target

  -- Skip web links, mailto, and internal page anchors
  if target:match("^%a+://") or target:match("^mailto:") or target:match("^#") then
    return el
  end

  -- If a root document (e.g. README.md) links into docs/ (e.g. docs/arch.md),
  -- strip the leading docs/ prefix because both land as siblings in dist/docs/
  local input_file = PANDOC_STATE.input_files[1] or ""
  if not input_file:match("^docs/") then
    target = target:gsub("^docs/", "")
    target = target:gsub("^%./docs/", "./")
  end

  -- Convert .md (and .md#section) to .pdf (and .pdf#section)
  target = target:gsub("%.md(#.*)$", ".pdf%1")
  target = target:gsub("%.md$", ".pdf")

  el.target = target
  return el
end
