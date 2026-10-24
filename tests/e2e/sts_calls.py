# Prints the STS calls moto recorded, one per line: "<Action> <RoleArn> <tag>=<value>,...".
# Runs inside the moto container for tests/e2e.sh (MOTO_ENABLE_RECORDING=True).
import base64
import json
import urllib.parse
import urllib.request

raw = urllib.request.urlopen("http://localhost:5000/moto-api/recorder/download-recording").read().decode()
for line in raw.splitlines():
    if not line.strip():
        continue
    req = json.loads(line)
    body = req.get("body") or ""
    if req.get("body_encoded") and isinstance(body, str):
        body = base64.b64decode(body).decode(errors="replace")
    if isinstance(body, dict):
        params = {k: [v] for k, v in body.items()}
    else:
        params = urllib.parse.parse_qs(body)
    action = params.get("Action", [""])[0]
    if not action.startswith("AssumeRole"):
        continue
    tags = {}
    i = 1
    while f"Tags.member.{i}.Key" in params:
        tags[params[f"Tags.member.{i}.Key"][0]] = params.get(f"Tags.member.{i}.Value", [""])[0]
        i += 1
    print(action, params.get("RoleArn", [""])[0], ",".join(f"{k}={v}" for k, v in sorted(tags.items())))
