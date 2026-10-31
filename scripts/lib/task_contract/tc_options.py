from tc_common import USAGE, JsonMap, fail

VALUE_OPTIONS = {
    "--role": "role",
    "--team": "team",
    "--group": "group",
    "--job": "job",
    "--command": "command",
    "--control-root": "control_root",
    "--runtime-kind": "runtime_kind",
    "--communication-policy": "communication_policy",
    "--requested-backend": "requested_backend",
    "--resolved-backend": "resolved_backend",
    "--assert-snapshot": "assert_snapshot",
}
LIST_KEYS = (
    "write_allowances", "role_write_allowances", "capabilities",
    "role_capabilities", "read_only_roles",
)


def empty_options() -> JsonMap:
    options: JsonMap = {key: "" for key in VALUE_OPTIONS.values()}
    for key in LIST_KEYS:
        options[key] = []
    return options


def add_capability(options: JsonMap, value: str) -> None:
    if ":" not in value:
        fail("invalid write capability")
    kind, path = value.split(":", 1)
    options["capabilities"].append((kind, path))


def add_role_capability(options: JsonMap, value: str) -> None:
    parts = value.split(":", 2)
    if len(parts) != 3:
        fail("invalid role write capability")
    options["role_capabilities"].append(tuple(parts))


def list_handlers() -> JsonMap:
    return {
        "--write-allowance": lambda opts, val: opts["write_allowances"].append(val),
        "--role-write-allowance": lambda opts, val: opts["role_write_allowances"].append(val),
        "--write-capability": add_capability,
        "--capability": add_capability,
        "--role-write-capability": add_role_capability,
        "--read-only-role": lambda opts, val: opts["read_only_roles"].append(val),
    }


def apply_option(options: JsonMap, flag: str, value: str) -> None:
    if flag in VALUE_OPTIONS:
        key = VALUE_OPTIONS[flag]
        if options[key]:
            fail(f"duplicate {flag}")
        options[key] = value
        return
    handler = list_handlers().get(flag)
    if handler is None:
        fail(USAGE)
    handler(options, value)


def parse_options(arguments: list[str], require_command: bool = False) -> JsonMap:
    options = empty_options()
    index = 0
    while index < len(arguments):
        flag = arguments[index]
        index += 1
        if index >= len(arguments):
            fail(USAGE)
        apply_option(options, flag, arguments[index])
        index += 1
    if require_command and not options["command"]:
        fail("--command is required")
    return options
