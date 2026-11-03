def field: (if . == null or . == false then "" else tostring end | gsub("\u0000"; "")), "\u0000";
def capabilities_valid:
  .capabilities | type == "array" and length > 0 and all(.[]; type == "object");
def allowances_valid:
  .write_allowances | type == "array" and length > 0 and all(.[]; type == "string");
def contract_matches:
  . as $contract |
  ($entry.role // "") as $role |
  ($entry.contract_id // "") as $identity |
  ($identity != "" and
   ($contract.contract_digest // "") == ($entry.contract_digest // "") and
   ($contract.contract_id // "") == $identity and
   ($contract.project_root // "") == $expected_root and
   $role != "" and
   ($contract.task_identity // "") == ($entry.task_identity // "") and
   ($contract.state == "dispatched" or $contract.state == "running") and
   $contract.allowances_by_role[$role] == $entry.write_allowances and
   (if (($contract.schema_version // 2) | tostring) == "3" then
      $contract.capabilities_by_role[$role] == ($entry.capabilities // [])
    else true end));
if $source == "hook" then
  (.tool_name // "" | field),
  (.tool_input.file_path // .tool_input.notebook_path // "" |
   if type == "string" then . else "invalid\nfile path" end | field),
  (.cwd // "" | field),
  (.agent_id // .agentId // .agent_type // .agentType // .subagent_type // .subagentType // .name // "" | field)
elif $source == "manifest" then
  (if $identifier == "" then null else (.agents[$identifier] // null) end) as $agent |
  (if $agent == null then "" else ($agent | tojson) end | field),
  ($agent.role // "" | field),
  (try ([.agents[] | select(.state == "registered" or .state == "running")] | length) catch 0 | field),
  (if $agent.schema_version != null then $agent.schema_version elif $agent.capabilities != null then 3 else 2 end | field),
  ($agent.project_root // "" | field),
  ($agent.contract_path // "" | field),
  ($agent | capabilities_valid | tostring | field),
  ($agent | allowances_valid | tostring | field),
  (if ($agent | capabilities_valid) then ($agent.capabilities | length) else 0 end | field),
  (if ($agent | capabilities_valid) then $agent.capabilities[] | (.kind // "" | field), (.path // "" | field) else empty end),
  (if ($agent | allowances_valid) then $agent.write_allowances[] | split("\n")[] | field else empty end)
elif $source == "contract" then
  (try contract_matches catch false | tostring | field),
  (.schema_version // 2 | field)
else empty end
