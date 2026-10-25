#!/bin/sh
# Xcode Cloud: writes the Hammerhead client secret from the secret environment variable HAMMERHEAD_CLIENT_SECRET
# into the ignored Config/Secrets.xcconfig. Without the variable the build continues and Hammerhead stays hidden.
set -eu
if [ -n "${HAMMERHEAD_CLIENT_SECRET:-}" ]; then
    umask 077
    printf 'HAMMERHEAD_CLIENT_SECRET = %s\n' "$HAMMERHEAD_CLIENT_SECRET" > "$CI_PRIMARY_REPOSITORY_PATH/Config/Secrets.xcconfig"
fi
