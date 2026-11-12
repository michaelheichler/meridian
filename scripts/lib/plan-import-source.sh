# Plain assignments, because bash 3.2 has no declare -g.
SOURCE_DIGEST="" SOURCE_FILE_COUNT=0 SOURCE_TOTAL_BYTES=0

valid_import_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

canonical_directory() {
  local path="$1"
  [ -d "$path" ] || die "directory does not exist: $path"
  [ ! -L "$path" ] || die "directory must not be a symbolic link: $path"
  (CDPATH='' cd -P -- "$path" && pwd -P)
}

canonical_file() {
  local path="$1"
  [ -f "$path" ] || die "file does not exist: $path"
  [ ! -L "$path" ] || die "file must not be a symbolic link: $path"
  (CDPATH='' cd -P -- "$(dirname "$path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
}

import_file_size() {
  local path="$1" size
  size=$(stat -f '%z' "$path" 2>/dev/null || true)
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    size=$(stat -c '%s' "$path" 2>/dev/null || true)
  fi
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

import_sha256() {
  local path="$1" digest
  if [ "$path" = - ]; then
    if command -v shasum >/dev/null 2>&1; then
      digest=$(shasum -a 256 | awk '{print $1}')
    else
      digest=$(sha256sum | awk '{print $1}')
    fi
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$path" | awk '{print $1}')
  else
    digest=$(sha256sum "$path" | awk '{print $1}')
  fi
  [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

import_sorted_files() {
  local source="$1"
  if [ -d "$source" ]; then
    find "$source" -type f -print0 2>/dev/null
  else
    printf '%s\0' "$source"
  fi | LC_ALL=C sort -z
}

import_digest_files() {
  local source="$1" digest_input="$2" path relative file_digest
  while IFS= read -r -d '' path; do
    [ ! -L "$path" ] || { rm -f "$digest_input"; import_fail "source contains a symbolic link: $path"; }
    relative=${path#"$source"/}
    file_digest=$(import_sha256 "$path") || { rm -f "$digest_input"; import_fail "could not digest source file: $path"; }
    printf '%s\t%s\n' "$relative" "$file_digest" >> "$digest_input"
    SOURCE_FILE_COUNT=$((SOURCE_FILE_COUNT + 1))
    SOURCE_TOTAL_BYTES=$((SOURCE_TOTAL_BYTES + $(import_file_size "$path")))
  done < <(import_sorted_files "$source")
}

import_source_metadata() {
  local source="$1" digest_input
  SOURCE="$source"
  SOURCE_FILE_COUNT=0
  SOURCE_TOTAL_BYTES=0
  digest_input=$(mktemp "${TMPDIR:-/tmp}/meridian-import-digest.XXXXXX") || import_fail 'could not create source digest workspace'
  if find "$source" -type l -print -quit 2>/dev/null | grep -q .; then
    rm -f "$digest_input"
    import_fail "source contains a symbolic link"
  fi
  import_digest_files "$source" "$digest_input"
  SOURCE_DIGEST="sha256:$(import_sha256 "$digest_input")"
  rm -f "$digest_input"
  export SOURCE SOURCE_DIGEST SOURCE_FILE_COUNT SOURCE_TOTAL_BYTES
}

validate_ir() {
  local path="$1"
  jq -e -f "$SCRIPT_DIR/../config/import-ir-validator.jq" "$path" >/dev/null \
    || import_fail "normalized import IR is invalid: $path"
}

canonical_source() {
  local source="$1"
  [ ! -L "$source" ] || die "source must not be a symbolic link: $source"
  if [ -d "$source" ]; then
    canonical_directory "$source"
  elif [ -f "$source" ]; then
    canonical_file "$source"
  else
    die "source does not exist: $source"
  fi
}

source_adapter() {
  case "$1" in
    gsd)
      . "$SCRIPT_DIR/import-adapters/lib.sh"
      . "$SCRIPT_DIR/import-adapters/gsd.sh"
      ;;
    markdown)
      . "$SCRIPT_DIR/import-adapters/lib.sh"
      . "$SCRIPT_DIR/import-adapters/markdown.sh"
      ;;
    *)
      import_fail "unsupported import adapter: $1"
      ;;
  esac
}

normalize_source() {
  local adapter="$1" source="$2" output="$3"
  source=$(canonical_source "$source")
  mkdir -p "$(dirname "$output")"
  output="$(CDPATH='' cd -P -- "$(dirname "$output")" && pwd -P)/$(basename "$output")"
  source_adapter "$adapter"
  import_source_metadata "$source"
  case "$adapter" in
    gsd) import_adapter_gsd_normalize "$source" "$output" ;;
    markdown) import_adapter_markdown_normalize "$source" "$output" ;;
  esac
  validate_ir "$output"
}
