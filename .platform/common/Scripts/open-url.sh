#!/bin/bash
url=$(grep '^URL=' "$1" | cut -d= -f2-)
exec omarchy-launch-webapp $url
