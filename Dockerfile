FROM node:20-alpine

# Rozdzielamy instalację, aby dokładnie widzieć w logach, co się dzieje
RUN apk update && \
    apk add --no-cache bash && \
    apk add --no-cache python3 && \
    apk add --no-cache ffmpeg && \
    apk add --no-cache sox

WORKDIR /app
# Skrypt scan.sh wymaga basha, upewnijmy się, że ma prawa do wykonywania
COPY . .
RUN chmod +x /app/scan.sh

CMD ["node", "server.js"]