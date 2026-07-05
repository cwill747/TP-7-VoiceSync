#!/bin/bash
# Run once on your Mac. Sets this folder up as a FORK of armynante/TP-7-VoiceSync:
# full upstream history, with the Parakeet + Notion changes as one commit on top.
set -e
cd "$(dirname "$0")"
UPSTREAM="https://github.com/armynante/TP-7-VoiceSync.git"

rm -rf .git
git init -q
git remote add upstream "$UPSTREAM"
git fetch upstream

# Base the branch on upstream's history, keep this working tree, commit the diff on top.
git reset -q upstream/main
git add -A
git commit -q -m "Parakeet (FluidAudio) transcription + Notion output"

echo "Set up as a fork of armynante/TP-7-VoiceSync."
echo "Upstream history is preserved; your changes are one commit on top of upstream/main."
echo
echo "History:"
git log --oneline -5
echo
echo "To push to your own fork, create an empty repo on GitHub, then:"
echo "  git remote add origin git@github.com:<you>/<your-fork>.git"
echo "  git branch -M main && git push -u origin main"
echo
echo "To pull future upstream updates later:"
echo "  git fetch upstream && git merge upstream/main"
