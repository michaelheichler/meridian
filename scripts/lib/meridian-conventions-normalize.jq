def category: IN("file-structure", "naming", "testing", "style", "tooling", "patterns", "other");
def valid_text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
def legacy_artifact:
  (has("schema_version") | not)
  and ((keys_unsorted | sort) == ["conventions"])
  and all(.conventions[];
    type == "object" and ((keys_unsorted | sort) == ["rule", "tag"])
  );
if type == "object"
  and (.conventions | type == "array")
  and ((has("schema_version") and .schema_version == 1) or legacy_artifact)
  and all(.conventions[]; (.rule | valid_text) and (.tag | valid_text))
then . else error("invalid conventions artifact") end
|
.conventions as $entries
| reduce range(0; $entries | length) as $index (
    {schema_version: 1, conventions: []};
    $entries[$index] as $entry
    | ($entry.category // ($entry.tag | ascii_downcase)) as $raw_category
    | (if ($raw_category | category) then $raw_category else "other" end) as $category
    | ($entry.source // "user-defined") as $source
    | .conventions += [
        $entry + {
          id: ($entry.id // ("CONV-" + (($index + 1) | tostring | ("000" + .)[-3:]))),
          tag: $entry.tag,
          rule: $entry.rule,
          source: (if $source == "auto-detected" then $source else "user-defined" end),
          category: $category,
          confidence: (if $source == "auto-detected" then ($entry.confidence // "medium") else null end),
          detected_from: (if $source == "auto-detected" then ($entry.detected_from // "legacy") else null end),
          added: ($entry.added // $today)
        }
      ]
  )
| if ([.conventions[].id] | length) != ([.conventions[].id] | unique | length)
  then error("duplicate convention id") else . end
| if all(.conventions[];
    (.id | type == "string" and test("^CONV-[0-9]{3,}$"))
    and (.category | category)
    and (.source | IN("user-defined", "auto-detected"))
    and (.added | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (if .source == "auto-detected"
      then (.confidence | IN("high", "medium", "low")) and (.detected_from | type == "string" and length > 0)
      else .confidence == null and .detected_from == null end)
  ) then . else error("invalid convention entry") end
| .conventions |= sort_by(.id)
