import os


def migrate_environment(environment=None) -> None:
    environment = os.environ if environment is None else environment
    for name, value in tuple(environment.items()):
        if name.startswith("LBWC_"):
            environment.setdefault("MERIDIAN_" + name[5:], value)
