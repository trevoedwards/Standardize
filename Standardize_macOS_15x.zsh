#!/bin/zsh
#
#  ____  _                  _               _ _         
# / ___|| |_ __ _ _ __   __| | __ _ _ __ __| (_)_______ 
# \___ \| __/ _` | '_ \ / _` |/ _` | '__/ _` | |_  / _ \
#  ___) | || (_| | | | | (_| | (_| | | | (_| | |/ /  __/
# |____/ \__\__,_|_| |_|\__,_|\__,_|_|  \__,_|_/___\___| 
#
# -----------------------------------------------------------------------------
# Script: Standardize_macOS_15x.sh
# Purpose: Standardize user-specific macOS preferences for things like Finder and the Dock
# Author: Trevor Edwards
#
# Change Log:
# -----------------------------------------------------------------------------
# 2023-11-13 - Initial version created
# 2025-05-05 - Updated for macOS Sequoia (15.4):
#   • Replaced hardcoded paths with robust user context detection
#   • Replaced deprecated `authorizationdb write` with configuration profile guidance
#   • Added support for Installomator-based dockutil installation
#   • Improved dockutil handling and added full fallback logic
#   • Enhanced output logging and script safety (set -e, check commands)
#   • Cleaned Dock setup logic with Jamf user-context compatibility
# -----------------------------------------------------------------------------

#############################
####      PRE WORK      #####
#############################

scriptVersion="1.2.0"
logTag="Standardize-macOS"
logFile="/var/log/standardize.log"
startTime=$(date +%s)

log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$logTag] $msg" | tee -a "$logFile"
}

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

# Exit on any error
set -e

# Check for DEP/ADE enrollment
# This does not stop the script, just logs the result

depStatus=$(profiles status -type enrollment | awk -F": " '/Enrolled via DEP/{print $2}')

if [[ "$depStatus" != "Yes" ]]; then
    log "⚠️ Device is NOT enrolled via DEP. Proceeding with caution."
else
    log "✅ Device is DEP-enrolled."
fi

#############################
### GATHER USER CONTEXT #####
#############################

log "Running Standardize script version $scriptVersion..."

currentUser=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')
uid=$(id -u "$currentUser" 2>/dev/null || echo "")
userHome=$(dscl . -read /Users/"$currentUser" NFSHomeDirectory | awk '{ print $2 }')
plist="${userHome}/Library/Preferences/com.apple.dock.plist"

if [[ -z "$currentUser" || "$currentUser" == "loginwindow" ]]; then
    log "❌ No user logged in. Exiting..."
    exit 1
fi

log "👤 Logged-in user: $currentUser"

runAsUser() {
    launchctl asuser "$uid" sudo -u "$currentUser" "$@"
}

###########################################
#  OPTIONAL: Install dockutil if missing  #
###########################################

if [[ ! -x "/usr/local/bin/dockutil" ]]; then
    log "📦 dockutil not found, attempting to install via Installomator..."
    if [[ -f "/Library/Management/AppAutoPatch/Installomator/Installomator.sh" ]]; then
    # Default location: /usr/local/Installomator/Installomator.sh
    # Installomator may be installed in a different location if you're already using something like AppAutoPatch in your env
        /Library/Management/AppAutoPatch/Installomator/Installomator.sh dockutil NOTIFY=silent
    else
        log "⚠️ Installomator not found. Cannot install dockutil. Exiting."
        exit 1
    fi
fi

dockutil="/usr/local/bin/dockutil"
[[ ! -x "$dockutil" ]] && { log "❌ dockutil still not found after install. Exiting."; exit 1; }

log "✅ dockutil found at: $dockutil"

####################################
### SET FINDER & SYSTEM DEFAULTS ###
####################################

log "⚙️ Applying Finder and System preferences..."

# Use list view in all Finder windows by default. Other view modes: 'icnv', 'clmv', 'Flwv'.
defaults write com.apple.finder FXPreferredViewStyle -string 'Nlsv'

# Keep folders at the top of the list when sorting by name
defaults write com.apple.finder _FXSortFoldersFirst -bool true

# Save dialogs default to local instead of iCloud
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false

# Prevent .DS_Store creation on network & USB volumes
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# Save screen captures in `Pictures/Screenshots` instead of `Desktop` & save as PNG format (other options: BMP, GIF, JPG, PDF, TIFF)
mkdir -p "$userHome/Pictures/Screenshots"
defaults write com.apple.screencapture location -string "$userHome/Pictures/Screenshots"
defaults write com.apple.screencapture type -string "PNG"

# Restart SystemUIServer, so changes to screen capture settings will take effect
killall SystemUIServer &>/dev/null || true

# Disable resume system-wide
defaults write com.apple.systempreferences NSQuitAlwaysKeepsWindows -bool false

# Enable Gatekeeper (App Store + Identified Developers)
spctl --master-enable

###################################
### CONFIGURE THE USER'S DOCK #####
###################################

log "🧼 Cleaning and configuring Dock..."

until pgrep -x Dock &>/dev/null; do sleep 1; done

# Disable app launch animations on Dock
defaults write com.apple.dock launchanim -bool false

# Hide recently used apps section
runAsUser defaults write com.apple.dock show-recents -bool false

# Remove all existing Dock items
runAsUser "$dockutil" --remove all --no-restart "$plist"

# Define apps to be added to the Dock
apps=(
    "/Applications/Self Service.app"
    "/System/Applications/Launchpad.app"
    "/Applications/Google Chrome.app"
    "/Applications/Safari.app"
    "/Applications/Microsoft Outlook.app"
    "/Applications/OneDrive.app"
    "/System/Applications/System Settings.app"
)

for app in "${apps[@]}"; do
    if [[ -e "$app" ]]; then
        runAsUser "$dockutil" --add "$app" --no-restart "$plist"
        log "➕ Added to Dock: $app"
    else
        log "⚠️ App not found, skipping: $app"
    fi
done

# Restart the Dock to apply changes
killall Dock
log "✅ Dock configuration complete."

log "✅ Standardization complete for $currentUser"

endTime=$(date +%s)
elapsed=$((endTime - startTime))
log "🕒 Script completed in ${elapsed} seconds."

exit 0
