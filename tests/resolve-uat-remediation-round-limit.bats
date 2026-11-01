#!/usr/bin/env bats

load script_contract_helper

cap_input_rows() {
  local label mode input expected_status expected
  while IFS='|' read -r label mode input expected_status expected; do
    run bash "$SCRIPTS_DIR/resolve-uat-remediation-round-limit.sh" "$mode" "$input"
    expect_case "$label" "$expected_status"
    [ "$output" = "$expected" ] || record_case_failure "$label" "got=$output want=$expected"
  done
  assert_no_case_failures
}

@test "round caps distinguish strict user input from permissive legacy JSON normalization" {
  cap_input_rows <<'CASES'
zero|--validate-input|0|0|false
padded-zero|--validate-input|0000|0|false
case-insensitive-disable|--validate-input|FaLsE|0|false
padded-limit|--validate-input|0008|0|8
large-limit|--validate-input|999999999999999999999999|0|999999999999999999999999
negative|--validate-input|-2|1|
fraction|--validate-input|1.5|1|
boolean-enable|--validate-input|true|1|
empty|--validate-input||1|
null-json|--normalize-json|null|0|false
true-json|--normalize-json|true|0|false
string-json|--normalize-json|"8"|0|false
object-json|--normalize-json|{}|0|false
number-json|--normalize-json|0008|0|8
CASES
}

cap_decision_rows() {
  local label config current cap reached unlimited
  while IFS='|' read -r label config current cap reached unlimited; do
    printf '%s\n' "$config" > config.json
    run bash "$SCRIPTS_DIR/resolve-uat-remediation-round-limit.sh" --next-round-decision config.json "$current"
    expect_case "$label" 0 "max_rounds=$cap"
    expect_output_has "$label" "cap_reached=$reached"
    expect_output_has "$label" "unlimited=$unlimited"
  done
  assert_no_case_failures
}

@test "next round decisions honor canonical precedence and compare caps without integer overflow" {
  cap_decision_rows <<'CASES'
at-boundary|{"max_uat_remediation_rounds":3}|02|3|false|false
past-boundary|{"max_uat_remediation_rounds":3}|03|3|true|false
legacy-cap|{"max_remediation_rounds":2}|02|2|true|false
canonical-disable|{"max_uat_remediation_rounds":false,"max_remediation_rounds":1}|09||false|true
nested-is-not-top-level|{"nested":{"max_uat_remediation_rounds":1},"max_remediation_rounds":12}|02|12|false|false
huge-cap|{"max_uat_remediation_rounds":999999999999999999999999}|99|999999999999999999999999|false|false
malformed-config|not-json|01||false|true
empty-config|{}|01||false|true
CASES
}
