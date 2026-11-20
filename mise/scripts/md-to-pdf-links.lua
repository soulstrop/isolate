-- Normalizes markdown links to relative PDF targets for self-contained bundles
function Link(el)
  local target = el.target

  -- Preserve external protocols, mailto, and in-page anchor links
  if target:match("^%a+://") or target:match("^mailto:") or target:match("^#") then
    return el
  end

  -- If root doc (e.g. README.md) links to docs/arch.md, strip 'docs/'
  -- because both files land as sibling outputs in dist/docs/
  local input_file = PANDOC_STATE.input_files[1] or ""
  if not input_file:match("^docs/") then
    target = target:gsub("^docs/", "")
    target = target:gsub("^%./docs/", "")
  end

  -- Convert .md (and .md#section) to .pdf (and .pdf#section)
  target = target:gsub("%.md(#.*)$", ".pdf%1")
  target = target:gsub("%.md$", ".pdf")

  el.target = target
  return el
end
