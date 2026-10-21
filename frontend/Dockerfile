FROM docker.io/library/nginx:1.27-alpine
ARG APP_VERSION=v1
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html app.js style.css /usr/share/nginx/html/ui/
# Write the build version into the page footer
RUN sed -i "s/__APP_VERSION__/${APP_VERSION}/g" /usr/share/nginx/html/ui/index.html
