"""Merge the chart's settings into sabnzbd.ini before SABnzbd starts.

Runs in the init container, with the SABnzbd image's own Python and configobj.
Order: the saved ini, then the `config` value (config.json), then the Secret's
ini fragment when mounted. A listed key wins, an unlisted key keeps its saved
value, nothing is deleted. SABnzbd accepts a partial ini: a missing key keeps
its default (sabnzbd/config.py, _read_config).
"""

import json
import os
import sys
import tempfile

import configobj

INI = "/config/sabnzbd.ini"
CONFIG = "/etc/sabnzbd-chart/config.json"
SECRET = "/etc/sabnzbd-secret/sabnzbd.ini"


def load(path):
    return configobj.ConfigObj(path, encoding="utf-8", default_encoding="utf-8", file_error=True)


def saved():
    """The saved ini, else its backup (as SABnzbd does), else nothing on a first start."""
    paths = [path for path in (INI, INI + ".bak") if os.path.exists(path)]
    for path in paths:
        try:
            return load(path)
        except configobj.ConfigObjError as error:
            print(f"{path}: {error}", file=sys.stderr)
    if paths:
        sys.exit("no readable sabnzbd.ini: repair or delete it, then restart the pod")
    return configobj.ConfigObj(encoding="utf-8", default_encoding="utf-8")


def ini_value(value, path):
    """configobj stores strings: SABnzbd reads booleans as 1/0, lists as comma-separated."""
    if isinstance(value, dict):
        return {key: ini_value(item, f"{path}.{key}") for key, item in value.items()}
    if isinstance(value, list):
        return [ini_value(item, path) for item in value]
    if isinstance(value, bool):
        return "1" if value else "0"
    if value is None:
        sys.exit(f"{path} is null: give a value or remove the key")
    return str(value)


def main():
    ini = saved()
    with open(CONFIG, encoding="utf-8") as f:
        ini.merge(ini_value(json.load(f), "config"))
    if os.path.exists(SECRET):
        ini.merge(load(SECRET))
    ini.filename = None
    # Mode 0600, as SABnzbd creates it; os.replace keeps a crash from truncating it.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(INI), prefix=".sabnzbd.ini.")
    try:
        with os.fdopen(fd, "wb") as f:
            ini.write(f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, INI)
    except BaseException:
        os.unlink(tmp)
        raise


main()
