(.agent_max_turns | if type == "object" then . else {} end) as $map
| (if ($map | has($role)) then [$role, $map[$role]]
   elif $family and ($map | has("dev")) then ["dev", $map.dev]
   else null end) as $hit
| if $hit == null then empty
  else
    $hit[0] as $key
    | (if ($hit[1] | type) == "object" then $hit[1][$effort] else $hit[1] end) as $picked
    | if $picked == null then empty else [$key, ($picked | tostring)] | @tsv end
  end
