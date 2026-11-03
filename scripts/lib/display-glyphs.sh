lbwc_glyphs_load() {
  local _glyphs_planning="${1:-${LBWC_PLANNING_DIR:-}}" _glyphs_config _glyphs_format
  local _glyphs_scripts
  _glyphs_scripts="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -z "$_glyphs_planning" ]; then
    . "$_glyphs_scripts/lib/lbwc-config-root.sh"
    find_lbwc_root "${2:-$PWD}"
    _glyphs_planning="$LBWC_PLANNING_DIR"
  fi
  . "$_glyphs_scripts/lib/lbwc-settings.sh"
  _glyphs_config=$(lbwc_merged_config "$_glyphs_planning/config.json")
  _glyphs_format=$(jq -r '.visual_format // "unicode"' <<< "$_glyphs_config" 2>/dev/null) || _glyphs_format=unicode
  printf -v LBWC_GLYPH_FORMAT '%s' "$_glyphs_format"
}

lbwc_glyph() {
  local _glyph_target="$1" _glyph_name="$2" _glyph_format="${3:-${LBWC_GLYPH_FORMAT:-unicode}}" _glyph_index=0
  local _glyph_names=(brand dirty done check running needs_you failed cross pending separator filled empty next next_up warning top_left top_right bottom_left bottom_right horizontal vertical rule)
  local _glyph_unicode=('✦' '●' '✔' '✓' '◐' '?' '✖' '✗' '○' ' · ' '▮' '▯' '→' '➜' '⚠' '╔' '╗' '╚' '╝' '═' '║' '─')
  local _glyph_ascii=('*' '~' '[ok]' '[ok]' '[..]' '[?]' '[x]' '[x]' '-' ' | ' '#' '-' '->' '->' '[!]' '+' '+' '+' '+' '-' '|' '-')
  while [ "$_glyph_index" -lt "${#_glyph_names[@]}" ]; do
    if [ "${_glyph_names[$_glyph_index]}" = "$_glyph_name" ]; then
      if [ "$_glyph_format" = ascii ]; then
        printf -v "$_glyph_target" '%s' "${_glyph_ascii[$_glyph_index]}"
      else
        printf -v "$_glyph_target" '%s' "${_glyph_unicode[$_glyph_index]}"
      fi
      return 0
    fi
    _glyph_index=$((_glyph_index + 1))
  done
  return 1
}

lbwc_glyph_text() {
  local _glyph_text_target="$1" _glyph_text_value="$2" _glyph_text_name
  local _glyph_text_original _glyph_text_replacement
  if [ "${LBWC_GLYPH_FORMAT:-unicode}" = ascii ]; then
    for _glyph_text_name in brand dirty done check running failed cross pending separator filled empty next next_up warning top_left top_right bottom_left bottom_right horizontal vertical rule; do
      lbwc_glyph _glyph_text_original "$_glyph_text_name" unicode
      lbwc_glyph _glyph_text_replacement "$_glyph_text_name" ascii
      _glyph_text_value="${_glyph_text_value//$_glyph_text_original/$_glyph_text_replacement}"
    done
  fi
  printf -v "$_glyph_text_target" '%s' "$_glyph_text_value"
}

lbwc_glyph_file() {
  local _glyph_file_path="$1" _glyph_file_line=''
  if [ "${LBWC_GLYPH_FORMAT:-unicode}" != ascii ]; then
    cat "$_glyph_file_path"
    return
  fi
  while IFS= read -r _glyph_file_line; do
    lbwc_glyph_text _glyph_file_line "$_glyph_file_line"
    printf '%s\n' "$_glyph_file_line"
  done < "$_glyph_file_path"
  if [ -n "$_glyph_file_line" ]; then
    lbwc_glyph_text _glyph_file_line "$_glyph_file_line"
    printf '%s' "$_glyph_file_line"
  fi
}

lbwc_glyph_repeat() {
  local _glyph_repeat_target="$1" _glyph_repeat_name="$2" _glyph_repeat_count="$3"
  local _glyph_repeat_char _glyph_repeat_value=''
  lbwc_glyph _glyph_repeat_char "$_glyph_repeat_name"
  while [ "$_glyph_repeat_count" -gt 0 ]; do
    _glyph_repeat_value="$_glyph_repeat_value$_glyph_repeat_char"
    _glyph_repeat_count=$((_glyph_repeat_count - 1))
  done
  printf -v "$_glyph_repeat_target" '%s' "$_glyph_repeat_value"
}
