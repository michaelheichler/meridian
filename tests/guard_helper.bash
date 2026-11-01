fail_case() {
  echo "case=$1 $2" >&2
  echo "output=$output" >&2
  return 1
}

expect_status() {
  [ "$status" -eq "$2" ] || fail_case "$1" "expected exit status $2 got $status"
}

expect_output_has() {
  [[ "$output" == *"$2"* ]] || fail_case "$1" "expected output to contain '$2'"
}

expect_output_lacks() {
  [[ "$output" != *"$2"* ]] || fail_case "$1" "expected output to omit '$2'"
}

expect_output_empty() {
  [ -z "$output" ] || fail_case "$1" "expected no output"
}

expect_exists() {
  [ -e "$2" ] || fail_case "$1" "expected $2 to exist"
}

expect_missing() {
  [ ! -e "$2" ] || fail_case "$1" "expected $2 to be absent"
}

tree_digest() {
  (
    cd "$1" || exit 1
    find . -type f -print0 | sort -z | xargs -0 cksum
    find . -type l -print0 | sort -z | xargs -0 -n1 readlink
  ) | cksum
}

expect_same_digest() {
  [ "$2" = "$3" ] || fail_case "$1" "tree changed, before=$2 after=$3"
}
