.conventions |= map(select(.id != $replace))
| .conventions += [{
    id: $id, tag: $tag, rule: $rule, source: "user-defined", category: $category,
    confidence: null, detected_from: null, added: $today
  }]
| .conventions |= sort_by(.id)
