#!/usr/bin/env bash

cd /opt/jumpwire
if [[ `whoami` != $USER ]]; then
    exec sudo -u $USER -E ./bin/jumpwire start
fi
exec ./bin/jumpwire start
