#!/bin/bash

DMG_PATH=""
MOUNT_PATH="/tmp/AIUsageMonitor"
APP_PATH="/Applications"
APP_NAME="AI Usage Monitor"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--dmg) DMG_PATH="$2"; shift;;
        -a|--app) APP_PATH="$2"; shift;;
        -m|--mount) MOUNT_PATH="$2"; shift;;
        *) echo "Unknown parameter: $1"; exit 1;;
    esac
    shift
done

sleep 1

rm -rf "$APP_PATH/$APP_NAME.app"

cp -rf "$MOUNT_PATH/$APP_NAME.app" "$APP_PATH/$APP_NAME.app"

/usr/bin/hdiutil detach "$MOUNT_PATH" 2>/dev/null
rm -rf "$MOUNT_PATH"
rm -f "$DMG_PATH"

open "$APP_PATH/$APP_NAME.app"

rm -f /tmp/updater.sh

exit 0
