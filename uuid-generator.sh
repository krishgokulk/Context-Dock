#!/bin/bash
# Name: UUID Generator
# Description: Generate a random UUID/GUID
# Icon: key.fill
# Keywords: uuid, guid, identifier, random
# Pattern: ^uuid$
# Pattern: ^guid$
# Pattern: ^generate uuid$

# Generate lowercase UUID
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')

echo "🔑 UUID Generated"
echo ""
echo "$UUID"
echo ""
echo "✅ Copied to clipboard!"

# Copy to clipboard
echo "$UUID" | pbcopy

exit 0
