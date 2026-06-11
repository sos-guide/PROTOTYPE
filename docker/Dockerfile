FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    php8.4-fpm \
    supervisor \
    sudo \
    openssl \
    apache2-utils \
    && rm -rf /var/lib/apt/lists/*

COPY nginx-dev.conf /etc/nginx/sites-available/sos-guide
RUN ln -sf /etc/nginx/sites-available/sos-guide /etc/nginx/sites-enabled/ \
    && rm -f /etc/nginx/sites-enabled/default

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY dev-init.sh /usr/local/bin/dev-init.sh
RUN chmod +x /usr/local/bin/dev-init.sh

EXPOSE 80
CMD ["/usr/local/bin/dev-init.sh"]
