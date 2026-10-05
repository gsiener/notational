#!/bin/sh
# Archive Notational to build/Notational.xcarchive. CI, the release workflow and install.sh all
# build through here.
set -eu

cd "$(dirname "$0")/.."
xcodebuild -project Notation.xcodeproj -scheme 'Notation Release' -configuration ForBuilding \
	-derivedDataPath build/DerivedData -archivePath build/Notational.xcarchive archive "$@"
