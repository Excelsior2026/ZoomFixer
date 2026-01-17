FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    USER=zoomuser \
    HOME=/home/zoomuser \
    DISPLAY=:0

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates wget gnupg2 \
    libxcb-xtest0 libxcb-shape0 libegl1 libglu1-mesa libsm6 libxv1 libxrender1 libxi6 libxrandr2 libxcursor1 libxss1 libasound2 libpulse0 libnss3 libxcomposite1 xdg-utils dbus-x11 xauth \
    xvfb fluxbox x11vnc novnc websockify pulseaudio \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://zoom.us/client/latest/zoom_amd64.deb -o /tmp/zoom.deb && \
    apt-get update && apt-get install -y /tmp/zoom.deb || (apt-get install -f -y && apt-get install -y /tmp/zoom.deb)

RUN useradd -ms /bin/bash $USER
USER root
WORKDIR $HOME

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5901 6080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
