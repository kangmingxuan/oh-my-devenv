# Demo environment for docs/assets/demo.gif. record.sh builds it from a copy of
# the tracked source and applies the non-desktop baseline as a new user would.
FROM ghcr.io/charmbracelet/vhs:v0.12.1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git sudo unzip zsh \
 && rm -rf /var/lib/apt/lists/*

# Render the recording in the project font, pinned by the desktop font manifest.
COPY src/bootstrap/manifests/desktop/maple-mono-nf-cn.env /tmp/maple.env
RUN . /tmp/maple.env \
 && curl -fsSL -o /tmp/maple.zip "$MAPLE_MONO_URL" \
 && echo "$MAPLE_MONO_SHA256  /tmp/maple.zip" | sha256sum -c - \
 && mkdir -p /usr/share/fonts/truetype/maple \
 && unzip -q -j /tmp/maple.zip '*.ttf' -d /usr/share/fonts/truetype/maple \
 && rm /tmp/maple.zip && fc-cache -f

RUN mkdir -p /root/.local/bin && sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /root/.local/bin
ENV PATH=/root/.local/bin:$PATH

COPY src/ /root/.local/share/chezmoi/
RUN git -C /root/.local/share/chezmoi init -q -b main \
 && git -C /root/.local/share/chezmoi add -A \
 && git -C /root/.local/share/chezmoi -c user.name=Demo -c user.email=demo@example.com \
      commit -qm "Demo snapshot"
RUN mkdir -p /root/.config/chezmoi \
 && printf 'name = "Demo User"\nemail = "demo@example.com"\ndesktopBaseline = false\n' >/tmp/data.toml \
 && chezmoi execute-template --init --override-data-file /tmp/data.toml \
      --file /root/.local/share/chezmoi/.chezmoi.toml.tmpl >/root/.config/chezmoi/chezmoi.toml \
 && CI=true chezmoi apply
WORKDIR /root
