# Seeds the mock AWS for tests/e2e.sh. Runs inside the moto container (boto3 is installed there).
# Idempotent: re-running resets every value, so the e2e test can run again on the same cluster.
import json
import boto3

kw = dict(endpoint_url="http://localhost:5000", region_name="us-east-1",
          aws_access_key_id="test", aws_secret_access_key="test")
ssm = boto3.client("ssm", **kw)
for name, value, kind in [
    ("/my-app/log-level", "debug", "String"),
    ("/my-app/api-url", "https://api.example.com", "String"),
    ("/my-app/flags/FEATURE_A", "on", "String"),
    ("/my-app/flags/nested/FEATURE_B", "off", "String"),
    ("/my-app/db/host", "db.internal", "String"),
    ("/my-app/db/password", "s3cret", "SecureString"),
    ("/other-app/not-mine", "x", "String"),
]:
    ssm.put_parameter(Name=name, Value=value, Type=kind, Overwrite=True)

sm = boto3.client("secretsmanager", **kw)
for name, value in [
    ("my-app/env", json.dumps({"ENV_A": "1", "ENV_B": "2"})),
    ("my-app/db", json.dumps({"username": "app", "password": "pw"})),
    ("my-app/api-token", "tok-123"),
    ("my-app/registry-auth", json.dumps({"auths": {"registry.example.com": {"auth": "dXNlcjpwYXNz"}}})),
]:
    try:
        sm.create_secret(Name=name, SecretString=value)
    except sm.exceptions.ResourceExistsException:
        sm.put_secret_value(SecretId=name, SecretString=value)
print("seeded")
