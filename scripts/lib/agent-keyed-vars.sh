# Bash 3.2 has no associative arrays, so entries live in PREFIX_KEY globals.

keyed_ref() {
  local LC_ALL=C _kr_key="$2" _kr_encoded="" _kr_character _kr_code _kr_hex _kr_index _kr_out="$3"
  for ((_kr_index = 0; _kr_index < ${#_kr_key}; _kr_index++)); do
    _kr_character="${_kr_key:_kr_index:1}"
    case "$_kr_character" in
      [A-Za-z0-9]) _kr_encoded="$_kr_encoded$_kr_character" ;;
      *)
        printf -v _kr_code '%d' "'$_kr_character"
        printf -v _kr_hex '%02x' $((_kr_code & 255))
        _kr_encoded="${_kr_encoded}_$_kr_hex"
        ;;
    esac
  done
  printf -v "$_kr_out" '%s' "${1}_${_kr_encoded}"
}

keyed_set() {
  local variable_name
  keyed_ref "$1" "$2" variable_name
  printf -v "$variable_name" '%s' "$3"
}

keyed_has() {
  local variable_name
  keyed_ref "$1" "$2" variable_name
  [ "${!variable_name+set}" = set ]
}

keyed_get_into() {
  local _kgi_out="$1" _kgi_variable
  keyed_ref "$2" "$3" _kgi_variable
  printf -v "$_kgi_out" '%s' "${!_kgi_variable-}"
}

keyed_unset() {
  local variable_name
  keyed_ref "$1" "$2" variable_name
  unset "$variable_name"
}
