#!/bin/sh

export TERM="xterm-256color"
OFF='\033[0m'
RED='\033[0;31m'
BRED='\033[1;31m'
GREEN='\033[0;32m'

clear
echo "This machine's clock is currently set to: $(date) "$GREEN"($(TZ=America/Los_Angeles date))"$OFF"\n\nIf this is not correct and you plan on performing any PGP operations (key creation, signing, encryption) then you should correct the system time to the current time in order to avoid time drift issues.\n\nTo change the system time (along with system hardware clock):\n"

echo "1) First set the timezone with the command "$RED"sudo timedatectl set-timezone "$BRED"America/Los_Angeles"$OFF"  (For a list of timezones use "$RED"timedatectl list-timezones"$OFF")\n"

echo "2) Set time with the command "$RED"sudo timedatectl set-time \""$BRED"YYYY-MM-DD HH:MM:SS"$OFF$RED"\""$OFF" (default is in UTC if timezone from step #1 isn't set)\n\n"

echo "Run the command "$RED"help"$OFF" to repeat this message.\n"