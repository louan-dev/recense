#!/bin/zsh
# Installs the Finder Quick Action "Move to Gallery Main" (SPEC 43). Run it yourself:
#   zsh chau/install-move-to-gallery-main.sh
# Needs chau/setup.sh to have run once (Keychain token, rclone remote gallery-main).
# Puts move-to-gallery-main.sh in ~/Library/Application Support/Gallery and writes
# ~/Library/Services/Move to Gallery Main.workflow, which calls it with the selected items.
# Remove: delete that .workflow.
set -e
here="${0:A:h}"
support="$HOME/Library/Application Support/Gallery"
wf="$HOME/Library/Services/Move to Gallery Main.workflow"
[[ -f "$here/move-to-gallery-main.sh" ]] || { print "move-to-gallery-main.sh must sit next to this script." >&2; exit 1; }

mkdir -p "$support" "$wf/Contents"
cp "$here/move-to-gallery-main.sh" "$support/move-to-gallery-main.sh"
chmod 755 "$support/move-to-gallery-main.sh"

cat > "$wf/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>NSServices</key><array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Move to Gallery Main</string></dict>
    <key>NSMessage</key><string>runWorkflowAsService</string>
    <key>NSRequiredContext</key><dict><key>NSApplicationIdentifier</key><string>com.apple.finder</string></dict>
    <key>NSSendFileTypes</key><array><string>public.item</string></array>
  </dict></array>
</dict></plist>
PL

cat > "$wf/Contents/document.wflow" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AMApplicationBuild</key><string>523</string>
  <key>AMApplicationVersion</key><string>2.10</string>
  <key>AMDocumentVersion</key><string>2</string>
  <key>actions</key><array><dict>
    <key>action</key><dict>
      <key>AMAccepts</key><dict><key>Container</key><string>List</string><key>Optional</key><true/>
        <key>Types</key><array><string>com.apple.cocoa.string</string></array></dict>
      <key>AMActionVersion</key><string>2.0.3</string>
      <key>AMApplication</key><array><string>Automator</string></array>
      <key>AMParameterProperties</key><dict>
        <key>COMMAND_STRING</key><dict/><key>CheckedForUserDefaultShell</key><dict/>
        <key>inputMethod</key><dict/><key>shell</key><dict/><key>source</key><dict/>
      </dict>
      <key>AMProvides</key><dict><key>Container</key><string>List</string>
        <key>Types</key><array><string>com.apple.cocoa.string</string></array></dict>
      <key>ActionBundlePath</key><string>/System/Library/Automator/Run Shell Script.action</string>
      <key>ActionName</key><string>Run Shell Script</string>
      <key>ActionParameters</key><dict>
        <key>COMMAND_STRING</key><string>exec /bin/bash "$HOME/Library/Application Support/Gallery/move-to-gallery-main.sh" "$@"</string>
        <key>CheckedForUserDefaultShell</key><true/>
        <key>inputMethod</key><integer>1</integer>
        <key>shell</key><string>/bin/bash</string>
        <key>source</key><string></string>
      </dict>
      <key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
      <key>CFBundleVersion</key><string>2.0.3</string>
      <key>CanShowSelectedItemsWhenRun</key><false/>
      <key>CanShowWhenRun</key><true/>
      <key>Category</key><array><string>AMCategoryUtilities</string></array>
      <key>Class Name</key><string>RunShellScriptAction</string>
      <key>InputUUID</key><string>6F1C0A52-2C1B-4B57-9D43-43A1A0C0F001</string>
      <key>Keywords</key><array><string>Shell</string><string>Script</string></array>
      <key>OutputUUID</key><string>6F1C0A52-2C1B-4B57-9D43-43A1A0C0F002</string>
      <key>UUID</key><string>6F1C0A52-2C1B-4B57-9D43-43A1A0C0F003</string>
      <key>UnlocalizedApplications</key><array><string>Automator</string></array>
      <key>arguments</key><dict/>
      <key>isViewVisible</key><integer>1</integer>
      <key>location</key><string>309.0:253.0</string>
    </dict>
    <key>isViewVisible</key><integer>1</integer>
  </dict></array>
  <key>connectors</key><dict/>
  <key>workflowMetaData</key><dict>
    <key>applicationBundleIDsByPath</key><dict/>
    <key>applicationPaths</key><array/>
    <key>inputTypeIdentifier</key><string>com.apple.Automator.fileSystemObject</string>
    <key>outputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
    <key>presentationMode</key><integer>15</integer>
    <key>processesInput</key><false/>
    <key>serviceApplicationBundleID</key><string>com.apple.finder</string>
    <key>serviceApplicationPath</key><string>/System/Library/CoreServices/Finder.app</string>
    <key>serviceInputTypeIdentifier</key><string>com.apple.Automator.fileSystemObject</string>
    <key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
    <key>serviceProcessesInput</key><false/>
    <key>systemImageName</key><string>NSActionTemplate</string>
    <key>useAutomaticInputType</key><false/>
    <key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
  </dict>
</dict></plist>
PL

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
print "Installed. In Finder: right click > Quick Actions > Move to Gallery Main."
print "If it is missing, turn it on in System Settings > Keyboard > Keyboard Shortcuts > Services > Files and Folders."
