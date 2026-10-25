# Frontend image: static UI served by nginx.
# Author: Nihal Singh Atwal (student ID 49299175, nihalsingh.atwal@student.uq.edu.au)
# AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
FROM docker.io/library/nginx:1.27-alpine
ARG APP_VERSION=v1
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html app.js style.css /usr/share/nginx/html/ui/
# Write the build version into the page footer
RUN sed -i "s/__APP_VERSION__/${APP_VERSION}/g" /usr/share/nginx/html/ui/index.html
