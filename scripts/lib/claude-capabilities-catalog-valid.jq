. as $catalog
| type == "object"
and .schema_version == 1
and (.source | type == "object")
and (.source.binary_path | type == "string" and startswith("/"))
and (.source.version | type == "string" and length > 0)
and (.source.sha256 | type == "string" and test("^[[:xdigit:]]{64}$"))
and (.source.detected_at | type == "string" and length > 0)
and (.models | type == "array" and length > 0)
and (all(.models[];
  type == "object"
  and (keys | sort) == ["description", "label", "selector"]
  and (.selector | type == "string" and length > 0)
  and (
    ((.label | type == "string" and length > 0) and (.description | type == "string" and length > 0))
    or (.label == null and .description == null)
  )
))
and ([.models[].selector] | length == (unique | length))
and (.reasoning | type == "object")
and (.reasoning.scope | IN("global", "model_associated"))
and (.reasoning.accepted_values | type == "array" and length > 0)
and (all(.reasoning.accepted_values[]; type == "string" and length > 0))
and (.reasoning.accepted_values | length == (unique | length))
and (.reasoning.model_associations | type == "object")
and (all(.reasoning.model_associations | to_entries[];
  (.key as $selector | [$catalog.models[].selector] | index($selector) != null)
  and (.value | type == "array" and length > 0)
  and (all(.value[]; type == "string" and length > 0))
  and (.value | length == (unique | length))
  and (all(.value[]; . as $effort | $catalog.reasoning.accepted_values | index($effort) != null))
))
and (
  (has("host_agent_enum") | not)
  or (
    (.host_agent_enum | type == "array")
    and (all(.host_agent_enum[]; type == "string" and length > 0))
    and (.host_agent_enum | length == (unique | length))
  )
)
and (
  (has("agent_model_ids") | not)
  or (
    has("host_agent_enum")
    and (.agent_model_ids | type == "object")
    and (all(.agent_model_ids | to_entries[];
      (.value | type == "string" and length > 0)
      and (.value as $host_id | $catalog.host_agent_enum | index($host_id) != null)
    ))
  )
)
