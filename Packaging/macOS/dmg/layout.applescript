-- Lays out the Alloy disk image window: app on the left, Applications link on the right.
-- Usage: osascript layout.applescript <volume name>
on run argv
    set volName to item 1 of argv
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 800, 520}
            set opts to the icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 112
            set background picture of opts to file ".background:background.tiff"
            set position of item "Alloy.app" of container window to {150, 200}
            set position of item "Applications" of container window to {450, 200}
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
