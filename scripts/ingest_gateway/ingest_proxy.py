#!/usr/bin/env python3
"""TCP passthrough 9200 -> a live data node. TLS stays on Elasticsearch."""
import json
import os
import signal
import subprocess
import sys
import time

CLUSTER = os.environ["CLUSTER_NAME"]
REGION = os.environ["AWS_REGION"]
PREFERRED_AZ = os.environ["PREFERRED_AZ"]
LISTEN_PORT = "9200"
ES_PORT = "9200"

socat = None


def discover():
    raw = subprocess.check_output(
        [
            "aws",
            "ec2",
            "describe-instances",
            "--region",
            REGION,
            "--filters",
            f"Name=tag:Cluster,Values={CLUSTER}",
            "Name=instance-state-name,Values=running",
            "--output",
            "json",
        ],
        text=True,
    )
    preferred, other = [], []
    for reservation in json.loads(raw)["Reservations"]:
        for instance in reservation["Instances"]:
            tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
            role = tags.get("ElasticsearchRole", "")
            if role in ("", "master"):
                continue
            ip = instance.get("PrivateIpAddress")
            if not ip:
                continue
            az = instance["Placement"]["AvailabilityZone"]
            (preferred if az == PREFERRED_AZ else other).append(ip)
    if preferred:
        return preferred[0]
    if other:
        return other[0]
    return None


def stop():
    global socat
    if socat is not None and socat.poll() is None:
        socat.terminate()
        try:
            socat.wait(timeout=5)
        except subprocess.TimeoutExpired:
            socat.kill()
    socat = None


def start(ip):
    global socat
    socat = subprocess.Popen(
        [
            "socat",
            f"TCP-LISTEN:{LISTEN_PORT},fork,reuseaddr,bind=0.0.0.0",
            f"TCP:{ip}:{ES_PORT}",
        ]
    )


def main():
    current = None
    while True:
        try:
            ip = discover()
        except Exception as exc:
            print(f"ingest_proxy: discover failed: {exc}", flush=True)
            ip = current
        if ip and ip != current:
            print(f"ingest_proxy: target {current} -> {ip}", flush=True)
            stop()
            start(ip)
            current = ip
        elif socat is not None and socat.poll() is not None:
            print(f"ingest_proxy: socat exited {socat.returncode}; restarting", flush=True)
            if current:
                start(current)
        time.sleep(15)


def shutdown(_signum, _frame):
    stop()
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    main()
