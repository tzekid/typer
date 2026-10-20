#!/usr/bin/env bash
# Build and publish the committed revision as an immutable release, then
# restart the user service and roll back unless the new binary is healthy.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_root="$HOME/.local/opt/typer"
port=9334
cd "$project_dir"
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit the complete change before deploying.' >&2; exit 1; }
revision="$(git rev-parse --verify HEAD^{commit})"
[[ "$(odin version)" == "odin version $(cat .odinversion)" ]] || { echo "Odin $(cat .odinversion) is required." >&2; exit 1; }
rm -rf build # every release is built from source, never from earlier build output
OPT=speed TARGET=x86-64-v3 ./build.sh server
mkdir -p "$release_root/releases"
exec 9>"$release_root/.deploy.lock"
flock 9
release_dir="$release_root/releases/$revision"
[[ ! -e "$release_dir" ]] || { echo 'This revision already has a release.' >&2; exit 1; }
stage_dir="$(mktemp -d "$release_root/.stage.XXXXXX")"
trap 'chmod -R u+w -- "$stage_dir"; rm -rf -- "$stage_dir"' EXIT
mkdir -p "$stage_dir/release/bin"
cp build/typer "$stage_dir/release/bin/"
cp -a build/packs "$stage_dir/release/packs"
printf '%s\n' "$revision" > "$stage_dir/release/REVISION"
find "$stage_dir/release" -type d -exec chmod 0755 {} +
find "$stage_dir/release" -type f -exec chmod 0444 {} +
chmod 0555 "$stage_dir/release/bin/typer"
mv "$stage_dir/release" "$release_dir"
find "$release_dir" -type d -exec chmod 0555 {} +
for link in current previous; do
  [[ ! -e "$release_root/$link" || -L "$release_root/$link" ]] || { echo "Refusing non-symlink $link" >&2; exit 1; }
done
prior="$(readlink "$release_root/current" || true)"
rollback() {
  if [[ -n "$prior" ]]; then
    ln -s "$prior" "$stage_dir/restore"
    mv -Tf "$stage_dir/restore" "$release_root/current"
    systemctl --user restart typer.service
  fi
}
mkdir -p "$HOME/.local/share/typer"
ln -s "releases/$revision" "$stage_dir/current"
mv -Tf "$stage_dir/current" "$release_root/current"
if ! systemctl --user restart typer.service; then
  rollback
  exit 1
fi
healthy=false
for attempt in {1..30}; do
  if curl --fail --silent --max-time 1 "http://127.0.0.1:$port/healthz" | grep -qx ok; then healthy=true; break; fi
  sleep 0.2
done
service_pid="$(systemctl --user show typer.service --property MainPID --value)"
if ! $healthy || [[ "$(readlink -f "/proc/$service_pid/exe")" != "$release_dir/bin/typer" ]]; then
  rollback
  echo 'The new service failed its release check.' >&2
  exit 1
fi
if [[ -n "$prior" ]]; then
  ln -s "$prior" "$stage_dir/previous"
  mv -Tf "$stage_dir/previous" "$release_root/previous"
fi
printf 'Published release %s\n' "$revision"
