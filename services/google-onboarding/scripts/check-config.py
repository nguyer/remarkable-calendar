"""Check deployment prerequisites without displaying client IDs or secret values."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tomllib
from urllib.parse import urlsplit

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--remote", action="store_true", help="Also check deployed secret names (requires Wrangler login)")
args = parser.parse_args()
config = tomllib.loads((root / "wrangler.toml").read_text())
values = config.get("vars", {})
problems = []
client = values.get("GOOGLE_CLIENT_ID", "")
if not client or not client.endswith(".apps.googleusercontent.com") or client.strip() != client:
    problems.append("Set GOOGLE_CLIENT_ID to the Google Web application client ID in wrangler.toml.")
origin = values.get("PUBLIC_ORIGIN", "")
url = urlsplit(origin)
if url.scheme != "https" or not url.hostname or url.path or url.query or url.fragment or url.username or url.password:
    problems.append("Set PUBLIC_ORIGIN to the public HTTPS origin, with no path or trailing slash.")
databases = config.get("d1_databases", [])
if not any(d.get("binding") == "DB" and d.get("database_id") and d["database_id"] != "00000000-0000-0000-0000-000000000000" for d in databases):
    problems.append("Set the DB D1 binding to the created database ID.")
limits = {item.get("name") for item in config.get("ratelimits", [])}
for name in ("PAIRING_LIMIT", "TOKEN_LIMIT"):
    if name not in limits:
        problems.append("Add the " + name + " rate-limit binding.")
if args.remote:
    result = subprocess.run(["node", str(root / "node_modules/wrangler/bin/wrangler.js"), "secret", "list"], cwd=root, capture_output=True, text=True)
    try:
        names = {item["name"] for item in json.loads(result.stdout)} if result.returncode == 0 else None
    except (ValueError, KeyError, TypeError):
        names = None
    if names is None:
        problems.append("Could not check deployed secret names. Run wrangler login and try again.")
    else:
        for name in ("GOOGLE_CLIENT_SECRET", "TOKEN_ENCRYPTION_KEY"):
            if name not in names:
                problems.append("Add the deployed " + name + " secret with wrangler secret put.")
if problems:
    for message in problems:
        print("CHECK: " + message)
    sys.exit(1)
print("Deployment configuration checks passed" + ("; required deployed secret names exist." if args.remote else "."))
print("Secret values are not read or validated by this check.")
