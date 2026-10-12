# Cloudflare Access JWT verifier (Traefik forwardAuth target).
# No dependencies: the image is the official Node runtime plus one file.

FROM node:22-alpine

WORKDIR /app
COPY server.js ./

USER node
EXPOSE 4180
CMD ["node", "server.js"]
