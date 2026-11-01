# Bash 3.2 has no associative arrays, so entries live in PREFIX_KEY globals.

keyed_ref() {
  local LC_ALL=C key="$2" encoded="" character code hex index
  for ((index = 0; index < ${#key}; index++)); do
    character="${key:index:1}"
    case "$character" in
      [A-Za-z0-9]) encoded="$encoded$character" ;;
      *)
        printf -v code '%d' "'$character"
        printf -v hex '%02x' $((code & 255))
        encoded="${encoded}_$hex"
        ;;
    esac
  done
  printf -v "$3" '%s' "${1}_${encoded}"
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
  local variable_name
  keyed_ref "$2" "$3" variable_name
  printf -v "$1" '%s' "${!variable_name-}"
}

keyed_unset() {
  local variable_name
  keyed_ref "$1" "$2" variable_name
  unset "$variable_name"
}
