def effort: type == "string" and IN("thorough", "balanced", "fast", "turbo");
def autonomy: type == "string" and IN("cautious", "standard", "confident", "pure-vibe");
def verification_tier: type == "string" and IN("quick", "standard", "deep");
def positive_integer: type == "number" and . > 0 and . == floor;
def role_name:
  . as $name | type == "string" and ($roles | index($name) != null);
def turn_limit:
  . == false or (type == "number" and . >= 0 and . == floor);
def turn_setting:
  turn_limit
  or (
    type == "object"
    and all(to_entries[]; (.key | IN("thorough", "balanced", "fast", "turbo")) and (.value | turn_limit))
  );
def custom_profile_name:
  . as $name
  | type == "string"
  and ($name | test("^[a-z0-9]+(-[a-z0-9]+)*$") and length <= 30)
  and (["default", "prototype", "production", "yolo", "custom"] | index($name) == null);
def custom_profile:
  type == "object"
  and (keys | sort == ["autonomy", "effort", "verification_tier"])
  and (.effort | effort)
  and (.autonomy | autonomy)
  and (.verification_tier | verification_tier);
def exact_keys($allowed):
  (keys - $allowed | length) == 0;
def tmux_restrictions:
  type == "object"
  and exact_keys([
    "allow_nested_spawn", "allow_agent_git", "allow_agent_ask_user", "require_orchestrator_attach"
  ])
  and (.allow_nested_spawn | type == "boolean")
  and (.allow_agent_git | type == "boolean")
  and (.allow_agent_ask_user | type == "boolean")
  and (.require_orchestrator_attach | type == "boolean");
def tmux_execution:
  type == "object"
  and exact_keys([
    "enabled", "session_name_prefix", "max_agents",
    "attach_policy", "heartbeat_interval_seconds",
    "heartbeat_stale_seconds", "comms_latency_tolerance_ms", "comms_fallback",
    "cleanup_policy", "layout", "restrictions"
  ])
  and (.enabled | type == "boolean")
  and (.session_name_prefix | type == "string" and test("^[A-Za-z][A-Za-z0-9_-]{0,31}$"))
  and (.max_agents | type == "number" and . >= 1 and . <= 4 and . == floor)
  and (.attach_policy | type == "string" and IN("orchestrator_only", "visible_grid"))
  and (.heartbeat_interval_seconds | positive_integer)
  and (.heartbeat_stale_seconds | positive_integer)
  and (.comms_latency_tolerance_ms | positive_integer)
  and (.comms_fallback | type == "string" and IN("bus_only", "fall_back_to_in_process"))
  and (.cleanup_policy | type == "string" and IN("kill_on_complete", "keep_panes"))
  and (.layout | type == "string" and IN("main-vertical", "main-horizontal", "tiled", "even-horizontal", "even-vertical"))
  and (.restrictions | tmux_restrictions);
def workflow_execution:
  type == "object"
  and exact_keys(["enabled"])
  and (.enabled | type == "boolean");
type == "object"
and exact_keys([
  "schema_version", "effort", "autonomy", "auto_commit", "planning_tracking", "auto_push",
  "verification_tier", "skill_suggestions", "auto_install_skills", "discovery_questions",
  "discussion_mode", "context_compiler", "visual_format", "max_tasks_per_plan", "prefer_teams",
  "agent_execution_mode", "tmux_execution", "workflow_execution",
  "pipeline_research", "branch_per_milestone", "plain_summary", "active_profile", "custom_profiles",
  "agent_max_turns", "qa_skip_agents", "auto_uat", "require_phase_discussion", "rolling_summary",
  "metrics", "token_budgets", "two_phase_completion", "smart_routing", "validation_gates",
  "snapshot_resume", "lease_locks", "event_recovery", "worktree_isolation", "monorepo_routing",
  "debug_logging", "statusline_hide_limits", "statusline_hide_limits_for_api_key",
  "statusline_hide_agent_in_tmux", "statusline_collapse_agent_in_tmux", "caveman_style",
  "caveman_commit", "caveman_review", "max_uat_remediation_rounds", "routing", "model_profile", "roles"
])
and .schema_version == 1
and (.effort | effort)
and (.autonomy | autonomy)
and (.auto_commit | type == "boolean")
and (.planning_tracking | type == "string" and IN("manual", "ignore", "commit"))
and (.auto_push | type == "string" and IN("never", "after_phase", "always"))
and (.verification_tier | verification_tier)
and (.skill_suggestions | type == "boolean")
and (.auto_install_skills | type == "boolean")
and (.discovery_questions | type == "boolean")
and (.discussion_mode | type == "string" and IN("questions", "assumptions", "auto"))
and (.context_compiler | type == "boolean")
and (.visual_format | type == "string" and IN("unicode", "ascii"))
and (.max_tasks_per_plan | type == "number" and . > 0 and . == floor)
and (.prefer_teams | type == "string" and IN("always", "auto", "never"))
and (.agent_execution_mode | type == "string" and IN("in_process", "tmux", "workflow", "ask"))
and (.tmux_execution | tmux_execution)
and (.workflow_execution | workflow_execution)
and (.pipeline_research | type == "boolean")
and (.branch_per_milestone | type == "boolean")
and (.plain_summary | type == "boolean")
and (.active_profile | type == "string")
and (.custom_profiles | type == "object" and all(to_entries[]; (.key | custom_profile_name) and (.value | custom_profile)))
and (
  . as $config
  | .active_profile as $active
  | $active == "custom"
    or $active == "default"
    or $active == "prototype"
    or $active == "production"
    or $active == "yolo"
    or ($config.custom_profiles | has($active))
)
and (.agent_max_turns | type == "object" and all(to_entries[]; (.key | (role_name or . == "dev")) and (.value | turn_setting)))
and (.qa_skip_agents | type == "array" and length == ([.[]] | unique | length) and all(.[]; role_name))
and (.auto_uat | type == "boolean")
and (.require_phase_discussion | type == "boolean")
and (.rolling_summary | type == "boolean")
and (.metrics | type == "boolean")
and (.token_budgets | type == "boolean")
and (.two_phase_completion | type == "boolean")
and (.smart_routing | type == "boolean")
and (.validation_gates | type == "boolean")
and (.snapshot_resume | type == "boolean")
and (.lease_locks | type == "boolean")
and (.event_recovery | type == "boolean")
and (.worktree_isolation | type == "string" and IN("off", "on"))
and (.monorepo_routing | type == "boolean")
and (.debug_logging | type == "boolean")
and (.statusline_hide_limits | type == "boolean")
and (.statusline_hide_limits_for_api_key | type == "boolean")
and (.statusline_hide_agent_in_tmux | type == "boolean")
and (.statusline_collapse_agent_in_tmux | type == "boolean")
and (.caveman_style | type == "string" and IN("none", "lite", "full", "ultra", "auto"))
and (.caveman_commit | type == "boolean")
and (.caveman_review | type == "boolean")
and (.max_uat_remediation_rounds | . == false or (type == "number" and . > 0 and . == floor))
and (.routing | type == "object" and exact_keys(["active_profile", "profiles"]))
and (.routing.active_profile | type == "string" and IN("quality", "balanced", "turbo"))
and (.routing.profiles | type == "object" and (keys | sort == ["balanced", "quality", "turbo"]))
and (.routing.profiles.quality | type == "object" and (keys | sort == ["roles"]) and (.roles | type == "object"))
and (.routing.profiles.balanced | type == "object" and (keys | sort == ["roles"]) and (.roles | type == "object"))
and (.routing.profiles.turbo | type == "object" and (keys | sort == ["roles"]) and (.roles | type == "object"))
and (if has("model_profile") then .model_profile | IN("quality", "balanced", "budget", "turbo") else true end)
and (if has("roles") then .roles | type == "object" else true end)
