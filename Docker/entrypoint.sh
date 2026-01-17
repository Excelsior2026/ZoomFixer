#!/usr/bin/env bash
set -e
export DISPLAY=:0

pulseaudio -D --exit-idle-time=-1 --log-target=syslog || true
Xvfb :0 -screen 0 1280x800x24 &
sleep 2
fluxbox &
x11vnc -display :0 -forever -shared -rfbport 5901 -nopw &
/usr/share/novnc/utils/launch.sh --vnc localhost:5901 --listen 6080 --forever &

su - zoomuser -c "/usr/bin/zoom" &
wait -n
