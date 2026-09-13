#!/usr/bin/env bash
# SPIKE-I leg 3 — stand the mirror up on the Pi so the clip can be measured
# where addendum 2c says it has to be measured.
#
#   ./deploy_mirror.sh argon-robot [pinned-date]
#
# This is deliberately NOT a new deployment path. It runs `deploy/mirror`'s own
# artifacts — `build_tree.sh`, `geofabrik_pull.py`, `docker-compose.yml`,
# `service/Dockerfile.mirror-clip` — in the order `deploy/mirror/README.md`
# documents, because the whole point of measuring on the Pi is to measure the
# thing that will actually run. A bespoke spike deployment would produce numbers
# for a configuration nobody ships.
#
# Three details that bit on the first attempt and are not stylistic:
#
#  - **Caddy's site block is a named vhost** (`http://tiles.plotlines.app`) with
#    no fallback, so a request to `http://<pi>/clip` does not match it. Every
#    request must carry `Host: tiles.plotlines.app`. That is §6.5's "exercise
#    the real code path" working as intended, not an obstacle to route around —
#    `mirror_bench.py --host-header` exists for exactly this.
#  - **Caddy publishes :80**; the clip container publishes nothing at all and is
#    reachable only through Caddy's `reverse_proxy`. There is no :8080.
#  - **The image builds from the repo root**, needing both `core/` and
#    `service/` in one context, and it is built *on the Pi* — cross-building an
#    aarch64 image from x86 would need buildx/qemu and would stop being the
#    image the Pi actually runs.
set -euo pipefail

HOST="${1:?usage: deploy_mirror.sh <ssh-host> [pinned-date]}"
PINNED_DATE="${2:-2026-09-13}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOTE=/opt/plotlines-mirror

REGIONS=(
	north-america/us/colorado
	north-america/us/california
	north-america/us/wisconsin
	north-america/us/wyoming
)

echo "==> preparing $REMOTE on $HOST"
# The mkdir/chown-first and the trailing /. are both load-bearing; see
# deploy/mirror/README.md — modern SFTP-based scp does not create the
# destination, and /opt is root-owned.
ssh "$HOST" "sudo mkdir -p $REMOTE && sudo chown \"\$(id -un)\":\"\$(id -gn)\" $REMOTE"
scp -q -r "$REPO/deploy/mirror/." "$HOST:$REMOTE/"

echo "==> copying the build context (core/ + service/) for the clip image"
# rsync with excludes rather than `scp -r`: `core/` carries a 400 MB local
# `.venv` that has x86 wheels in it, and shipping those to an aarch64 box would
# be slow, useless, and — if the Dockerfile's `uv sync` ever saw them — actively
# wrong. The image resolves its own dependencies from pyproject.toml.
ssh "$HOST" "mkdir -p $REMOTE/src"
rsync -a --delete \
	--exclude '.venv/' --exclude '__pycache__/' --exclude '.pytest_cache/' \
	--exclude '*.pyc' --exclude '.mypy_cache/' \
	"$REPO/core" "$REPO/service" "$HOST:$REMOTE/src/"

echo "==> scaffolding the §6.3 tree"
ssh "$HOST" "cd $REMOTE && sudo ./build_tree.sh /srv/plotlines-mirror \
	&& sudo chown -R \"\$(id -un)\":\"\$(id -gn)\" /srv/plotlines-mirror"

echo "==> pulling ${#REGIONS[@]} region extracts on the Pi"
# Pulled ON the Pi, not copied from here. Two reasons, and the second matters
# more: the pull client is the shipped one (#258) and exercising it is part of
# what this leg rehearses; and pushing 2.1 GB over the LAN would land the
# extracts with provenance and MIRROR_STATE.json entries no real mirror has.
REGION_ARGS=""
for r in "${REGIONS[@]}"; do REGION_ARGS="$REGION_ARGS --region $r"; done
# shellcheck disable=SC2029
ssh "$HOST" "cd $REMOTE && python3 geofabrik_pull.py --root /srv/plotlines-mirror \
	--pinned-date $PINNED_DATE -v$REGION_ARGS"

echo "==> building the clip image on the Pi (aarch64, native)"
# shellcheck disable=SC2029
ssh "$HOST" "cd $REMOTE/src && docker build -q -f service/Dockerfile.mirror-clip \
	-t plotlines-mirror-clip:latest ."

echo "==> bringing up Caddy + the clip container"
ssh "$HOST" "cd $REMOTE && docker compose up -d"

echo "==> waiting for /health through Caddy (named vhost, so Host header)"
# shellcheck disable=SC2029
ssh "$HOST" 'for i in $(seq 1 60); do
	curl -fsS -H "Host: tiles.plotlines.app" http://localhost/health >/dev/null 2>&1 \
		&& { echo "  up"; exit 0; }
	sleep 2
done
echo "  clip service did not answer /health in 120s"; docker compose -f /opt/plotlines-mirror/docker-compose.yml logs --tail 40 mirror-clip; exit 1'

CID_CMD="docker compose -f $REMOTE/docker-compose.yml ps -q mirror-clip"
cat <<EOF

Mirror is up on $HOST. Take the leg-3 measurement with:

  .venv/bin/python mirror_bench.py \\
      --base-url http://$HOST \\
      --host-header tiles.plotlines.app \\
      --restart-cmd "ssh $HOST 'docker restart \$($CID_CMD)'"

--restart-cmd is not optional if you want more than one honest RSS sample:
X-Plotlines-Clip-Peak-Rss-Kb is a process high-water mark (issue #374), so only
the first clip after a process start measures that clip. Without it,
mirror_bench records one valid RSS reading per cell and labels the rest.
EOF
