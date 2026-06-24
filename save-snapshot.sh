#!/bin/bash
# save-snapshot.sh
# Saves a dated copy of Context-Dock to iCloud Projects.
# Keeps only the 5 most recent snapshots — older ones are deleted automatically.
#
# Usage:
#   ./save-snapshot.sh              — saves snapshot with today's date
#   ./save-snapshot.sh "prefect"    — saves with a label e.g. "Context-Dock-prefect-18-06-26"

REPO="$HOME/Desktop/Context-Dock"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Projects"
DATE=$(date '+%d-%m-%y')
LABEL="${1:-}"

if [ -n "$LABEL" ]; then
    SNAPSHOT_NAME="Context-Dock-${LABEL}-${DATE}"
else
    SNAPSHOT_NAME="Context-Dock-${DATE}"
fi

DEST="$ICLOUD/$SNAPSHOT_NAME"

# If same-name snapshot already exists today, add time to avoid overwrite
if [ -d "$DEST" ]; then
    TIME=$(date '+%H%M')
    SNAPSHOT_NAME="${SNAPSHOT_NAME}-${TIME}"
    DEST="$ICLOUD/$SNAPSHOT_NAME"
fi

echo "Saving snapshot: $SNAPSHOT_NAME ..."

rsync -a \
    --exclude='.git/' \
    --exclude='DerivedData/' \
    --exclude='*.xcworkspace/xcuserdata/' \
    --exclude='*.xcworkspace/xcshareddata/swiftpm/' \
    --exclude='.build/' \
    --exclude='*.o' \
    --exclude='*.d' \
    "$REPO/" "$DEST/"

SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)
echo "Saved: $DEST ($SIZE)"

# ── Keep only the 5 most recent Context-Dock-* snapshots ──────────────────────
echo ""
echo "Rotating snapshots (keeping 5 most recent)..."

mapfile -t ALL_SNAPS < <(ls -dt "$ICLOUD/Context-Dock-"* 2>/dev/null)
KEEP=5
TOTAL=${#ALL_SNAPS[@]}

if [ "$TOTAL" -gt "$KEEP" ]; then
    for (( i=KEEP; i<TOTAL; i++ )); do
        echo "  Removing: $(basename "${ALL_SNAPS[$i]}")"
        rm -rf "${ALL_SNAPS[$i]}"
    done
fi

echo ""
echo "Current snapshots in iCloud:"
ls -dt "$ICLOUD/Context-Dock-"* 2>/dev/null | head -5 | while read snap; do
    echo "  $(basename "$snap")"
done
