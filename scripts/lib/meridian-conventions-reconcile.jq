def norm: ascii_downcase | gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "");
def rank: if . == "high" then 0 elif . == "medium" then 1 else 2 end;
($current.conventions | map(select(.source == "user-defined"))) as $users
| ($current.conventions | map(select(.source == "auto-detected"))) as $old_auto
| ([ $current.conventions[].id | capture("^CONV-(?<n>[0-9]+)$").n | tonumber ] | max // 0) as $max_id
| ($candidates.conventions
    | map(. as $candidate | select(
        ($candidate.conflicts_with // []) as $conflicts
        | all($users[];
            . as $user
            | (($conflicts | index($user.id)) == null)
              and (($user.rule | norm) != ($candidate.rule | norm))
          )
      ))) as $conflict_filtered
| ($conflict_filtered
    | map(. as $candidate | select(all($users[]; (.rule | norm) != ($candidate.rule | norm))))
    | map(. as $candidate | select(
        $candidate.confidence != "low"
        or ([$conflict_filtered[] | select(.category == $candidate.category and .confidence != "low")] | length == 0)
      ))
    | sort_by((.confidence | rank), .category, (.rule | norm))
    | unique_by(.rule | norm)
  ) as $accepted
| reduce $accepted[] as $candidate (
    {next: $max_id, conventions: $users};
    ($old_auto | map(select((.rule | norm) == ($candidate.rule | norm)))[0]) as $old
    | if $old then
        .conventions += [$old + $candidate + {
          tag: ($candidate.category | ascii_upcase), source: "auto-detected",
          conflicts_with: ($candidate.conflicts_with // [])
        }]
      else
        .next += 1
        | .conventions += [$candidate + {
          id: ("CONV-" + ((.next | tostring | ("000" + .)[-3:]))),
          tag: ($candidate.category | ascii_upcase), source: "auto-detected",
          added: $today, conflicts_with: ($candidate.conflicts_with // [])
        }]
      end
  )
| {schema_version: 1, conventions: (.conventions | sort_by(.id))}
