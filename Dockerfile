FROM node:20-alpine
RUN apk add --no-cache bash python3
WORKDIR /app
CMD ["node", "server.js"]
