#!/usr/bin/env bash
# Replace a folder in the repo with a set of screenshots and push it to a branch.
#
# Usage: commit_screenshots.sh <branch> <source_dir> <dest_dir> <commit_message>
#
# Runs in a CI checkout with contents: write. Each attempt fetches the branch, replaces
# <dest_dir> with the contents of <source_dir>, commits only if something changed, rebases
# onto the latest branch and pushes. A rejected push starts the next attempt, up to three.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <branch> <source_dir> <dest_dir> <commit_message>" >&2
    exit 2
fi

BRANCH=$1
SOURCE=$2
DEST=$3
MESSAGE=$4
MAX_ATTEMPTS=3

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    git fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
    git checkout -B "$BRANCH" "origin/$BRANCH"

    rm -rf "$DEST"
    mkdir -p "$(dirname "$DEST")"
    cp -R "$SOURCE" "$DEST"
    git add -A -- "$DEST"

    if git diff --cached --quiet -- "$DEST"; then
        echo "No changes in $DEST, nothing to commit"
        exit 0
    fi

    git commit -m "$MESSAGE"

    if git pull --rebase origin "$BRANCH" && git push origin "HEAD:refs/heads/$BRANCH"; then
        echo "Pushed $DEST to $BRANCH (attempt $attempt)"
        exit 0
    fi

    git rebase --abort 2>/dev/null || true
    echo "Attempt $attempt failed to push to $BRANCH, retrying" >&2
    sleep $((attempt * 2))
done

echo "error: could not push $DEST to $BRANCH after $MAX_ATTEMPTS attempts" >&2
exit 1
