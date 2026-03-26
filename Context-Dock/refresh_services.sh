#!/bin/bash

# Script to refresh macOS Services menu
# Run this after making changes to NSServices in Info.plist

echo "🔄 Refreshing macOS Services cache..."

# Kill and restart the pasteboard server
/System/Library/CoreServices/pbs -flush
/System/Library/CoreServices/pbs -flush_pboard

echo "✅ Services cache flushed!"
echo ""
echo "📝 Next steps:"
echo "   1. Restart ILauncher"
echo "   2. Test in Finder: select files → right-click → Services"
echo "   3. You should see 'ILauncher' services in the menu"
echo ""
echo "💡 If services don't appear, you may need to log out and back in"
