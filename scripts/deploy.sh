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
compiler_version="$(odin version)"
[[ "${compiler_version##* version }" == "$(cat .odinversion)" ]] || { echo "Odin $(cat .odinversion) is required." >&2; exit 1; }
mkdir -p "$release_root/releases"
exec 9>"$release_root/.deploy.lock"
flock 9
rm -rf build # every release is built from source, never from earlier build output
OPT=speed TARGET=x86-64-v3 ./build.sh server
release_dir="$release_root/releases/$revision"
# A rolled-back revision may be retried using its immutable build.
stage_dir="$(mktemp -d "$release_root/.stage.XXXXXX")"
trap 'chmod -R u+w -- "$stage_dir"; rm -rf -- "$stage_dir"' EXIT
mkdir -p "$stage_dir/release/bin"
cp build/typer "$stage_dir/release/bin/"
cp -a build/packs "$stage_dir/release/packs"
printf '%s\n' "$revision" > "$stage_dir/release/REVISION"
find "$stage_dir/release" -type d -exec chmod 0755 {} +
find "$stage_dir/release" -type f -exec chmod 0444 {} +
chmod 0555 "$stage_dir/release/bin/typer"
if [[ ! -e "$release_dir" ]]; then
  mv "$stage_dir/release" "$release_dir"
  find "$release_dir" -type d -exec chmod 0555 {} +
elif [[ "$(cat "$release_dir/REVISION")" != "$revision" ]]; then
  echo "Release directory does not match $revision" >&2
  exit 1
fi
for link in current previous; do
  [[ ! -e "$release_root/$link" || -L "$release_root/$link" ]] || { echo "Refusing non-symlink $link" >&2; exit 1; }
done
prior="$(readlink "$release_root/current" || true)"
if [[ "$prior" == "releases/$revision" ]] && systemctl --user is-active --quiet typer.service && curl --fail --silent --max-time 2 "http://127.0.0.1:$port/healthz" | grep -qx ok; then
  echo "Release $revision is already healthy."
  exit 0
fi
data_dir="$HOME/.local/share/typer"
db="$data_dir/typer.sqlite"
backup=
mkdir -p "$data_dir"
if [[ -n "$prior" ]]; then ln -s "$prior" "$stage_dir/restore"; fi
ln -s "releases/$revision" "$stage_dir/current"
rollback() {
  [[ -n "$prior" ]] || return 0
  systemctl --user stop typer.service
  if [[ -n "$backup" ]]; then
    # Migrations can change derived scores. A user write after cutover must
    # never be discarded. Hold the SQLite lock through comparison and restore.
    if ! ( cd "$backup" && sqlite3 -bail "$db" <<'SQL'
PRAGMA busy_timeout=5000;
PRAGMA locking_mode=EXCLUSIVE;
BEGIN EXCLUSIVE;
COMMIT;
ATTACH 'before.sqlite' AS prior;
CREATE TEMP TABLE unchanged (ok INTEGER CHECK(ok=1));
INSERT INTO unchanged SELECT
  (SELECT count(*) FROM main.results) = (SELECT count(*) FROM prior.results)
  AND NOT EXISTS (
    SELECT id, user_id, record_sha, created_at FROM main.results EXCEPT
    SELECT id, user_id, record_sha, created_at FROM prior.results)
  AND (SELECT count(*) FROM main.users) = (SELECT count(*) FROM prior.users)
  AND NOT EXISTS (
    SELECT id, token_sha, name, created_at FROM main.users EXCEPT
    SELECT id, token_sha, name, created_at FROM prior.users);
DETACH prior;
.restore before.sqlite
SQL
    ); then
      echo "Could not safely restore the database. Current data and $backup/before.sqlite are preserved." >&2
      return 1
    fi
  fi
  mv -Tf "$stage_dir/restore" "$release_root/current"
  systemctl --user restart typer.service
}
if [[ -n "$prior" && -f "$db" ]]; then
  installed_schema=$(sqlite3 -readonly "$db" 'PRAGMA user_version;')
  new_schema=$("$release_dir/bin/typer" schema-version)
  if (( installed_schema > new_schema )); then
    echo "Database schema $installed_schema is newer than release schema $new_schema." >&2
    exit 1
  elif (( installed_schema < new_schema )); then
    backup=$(mktemp -d "$data_dir/pre-upgrade.XXXXXXXX")
    systemctl --user stop typer.service
    if ! ( cd "$backup" && sqlite3 -bail -readonly "$db" '.backup before.sqlite' &&
           [[ "$(sqlite3 -readonly before.sqlite 'PRAGMA quick_check;')" == ok ]] ); then
      systemctl --user start typer.service
      echo "Could not back up the database to $backup." >&2
      exit 1
    fi
  fi
fi
if ! mv -Tf "$stage_dir/current" "$release_root/current"; then
  if [[ -n "$backup" ]]; then systemctl --user start typer.service; fi
  exit 1
fi
if ! systemctl --user restart typer.service; then
  rollback
  exit 1
fi
healthy=false
for ((attempt=0; attempt<600; attempt++)); do
  systemctl --user is-active --quiet typer.service || break
  if curl --fail --silent --max-time 1 "http://127.0.0.1:$port/healthz" | grep -qx ok; then healthy=true; break; fi
  sleep 1
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
# Each release carries its own packs (~120 MB): keep the ten newest, and
# never the ones current or previous point at.
keep="$(readlink "$release_root/current") $(readlink "$release_root/previous" || true)"
for old in $(ls -1t "$release_root/releases" | tail -n +11); do
  [[ " $keep " == *" releases/$old "* ]] && continue
  chmod -R u+w -- "$release_root/releases/$old"
  rm -rf -- "$release_root/releases/$old"
done
printf 'Published release %s\n' "$revision"
