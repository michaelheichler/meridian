def normalized_profile($value):
  if $value == "budget" then "turbo" else $value end;
($defaults * $existing)
| .schema_version = 1
| .routing = (.routing // {})
| .routing.profiles = (.routing.profiles // {})
| .routing.profiles.quality = (.routing.profiles.quality // {})
| .routing.profiles.balanced = (.routing.profiles.balanced // {})
| .routing.profiles.turbo = (.routing.profiles.turbo // {})
| .routing.profiles.quality.roles = (.routing.profiles.quality.roles // {})
| .routing.profiles.balanced.roles = (.routing.profiles.balanced.roles // {})
| .routing.profiles.turbo.roles = (.routing.profiles.turbo.roles // {})
| .tmux_execution = (($defaults.tmux_execution // {}) * (.tmux_execution // {}))
| .tmux_execution |= del(.session_timeout_seconds, .pane_base_index)
| .tmux_execution.restrictions = (($defaults.tmux_execution.restrictions // {}) * (.tmux_execution.restrictions // {}))
| .workflow_execution = (($defaults.workflow_execution // {}) * (.workflow_execution // {}))
| .routing.active_profile = (
    if $existing.routing.active_profile? != null
    then normalized_profile($existing.routing.active_profile)
    elif $existing.model_profile? != null
    then normalized_profile($existing.model_profile)
    else "balanced"
    end
  )
