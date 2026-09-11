# Packaging environment for build-zim.sh, pinned so a ZIM built today is reproducible.
# System deps are zimscraperlib's declared list (its README) minus the ones only its
# download/video/GIF helpers need: libmagic1 for type detection, libcairo2 because
# cairosvg is imported eagerly for SVG-to-PNG.
FROM python:3.14-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends libmagic1 libcairo2 \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY package.py /opt/zim/package.py
WORKDIR /work
ENTRYPOINT ["python", "/opt/zim/package.py"]
