#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
notes_dir="${1:-"$repo_root/notes"}"
out_dir="${2:-"$notes_dir/html"}"

if ! command -v pandoc >/dev/null 2>&1; then
  echo "error: pandoc is required to render notes HTML" >&2
  exit 1
fi

mkdir -p "$out_dir"

link_filter="$(mktemp)"
nav_html="$(mktemp)"
theme_html="$(mktemp)"
trap 'rm -f "$link_filter" "$nav_html" "$theme_html"' EXIT

cat >"$link_filter" <<'LUA'
local function is_external(target)
  return target:match("^[%a][%w+.-]*:") ~= nil
      or target:match("^#") ~= nil
      or target:match("^/") ~= nil
end

local function split_fragment(target)
  local path, fragment = target:match("^([^#]*)(#.*)$")
  if path then
    return path, fragment
  end
  return target, ""
end

local function rebase(target)
  if target == "" or is_external(target) then
    return target
  end

  local path, fragment = split_fragment(target)
  if path == "" then
    return target
  end

  if path:match("%.md$") and not path:match("/") then
    return path:gsub("%.md$", ".html") .. fragment
  end

  if path:match("^%./[^/]+%.md$") then
    return path:gsub("^%./", ""):gsub("%.md$", ".html") .. fragment
  end

  return "../" .. path .. fragment
end

function Link(el)
  el.target = rebase(el.target)
  return el
end

function Image(el)
  el.src = rebase(el.src)
  return el
end
LUA

cat >"$nav_html" <<'HTML'
<nav class="notes-nav">
<a href="index.html">Notes index</a>
</nav>
HTML

cat >"$theme_html" <<'HTML'
<style>
:root {
  color-scheme: dark;
}

html {
  background: #101418;
  color: #d7dde6;
}

body {
  background: #101418;
  color: #d7dde6;
  max-width: 48em;
}

a,
a:visited {
  color: #8ab4f8;
}

a:hover,
a:focus {
  color: #c6ddff;
}

h1,
h2,
h3,
h4,
h5,
h6 {
  color: #f2f5f8;
}

code {
  background: #1a2028;
  color: #f4c27a;
  border-radius: 4px;
  padding: 0.1em 0.25em;
}

pre {
  background: #151b22;
  border: 1px solid #2c3642;
  border-radius: 6px;
  padding: 1em;
}

pre code {
  background: transparent;
  color: #d7dde6;
  padding: 0;
}

blockquote {
  color: #b8c2cf;
  border-left-color: #3a4654;
}

hr {
  border-color: #2c3642;
}

table {
  border-color: #384453;
}

th,
td {
  border-color: #384453;
}

thead,
tr:nth-child(even) {
  background: #151b22;
}

.notes-nav {
  margin-bottom: 2rem;
  padding-bottom: 0.75rem;
  border-bottom: 1px solid #2c3642;
}
</style>
HTML

mapfile -d '' notes < <(
  find "$notes_dir" -maxdepth 1 -type f -name '*.md' -print0 | LC_ALL=C sort -z
)

html_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g'
}

file_uri() {
  local path
  path="$(realpath "$1")"
  printf 'file://%s\n' "$path" | sed -e 's/ /%20/g'
}

{
  cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>MetaSonic Notes</title>
HTML
  cat "$theme_html"
  cat <<'HTML'
</head>
<body>
<h1>MetaSonic Notes</h1>
<p>Generated from Markdown notes in chronological filename order.</p>
<ul>
HTML
} >"$out_dir/index.html"

for note in "${notes[@]}"; do
  base="$(basename "$note")"
  stem="${base%.md}"
  out_file="$out_dir/$stem.html"
  title="$(
    awk '
      /^# / {
        sub(/^# +/, "")
        print
        exit
      }
    ' "$note"
  )"
  if [[ -z "$title" ]]; then
    title="$stem"
  fi

  pandoc \
    --standalone \
    --from=markdown \
    --to=html5 \
    --toc \
    --metadata "title=$title" \
    --include-in-header "$theme_html" \
    --include-before-body "$nav_html" \
    --lua-filter "$link_filter" \
    "$note" \
    -o "$out_file"

  escaped_title="$(printf '%s' "$title" | html_escape)"
  escaped_href="$(file_uri "$out_file" | html_escape)"
  escaped_base="$(printf '%s' "$base" | html_escape)"
  printf '<li><a href="%s">%s</a> - <code>%s</code></li>\n' \
    "$escaped_href" "$escaped_title" "$escaped_base" >>"$out_dir/index.html"
done

{
  cat <<'HTML'
</ul>
</body>
</html>
HTML
} >>"$out_dir/index.html"

echo "Rendered ${#notes[@]} notes to $out_dir"
