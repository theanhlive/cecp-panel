# CECP Panel — {{DOMAIN}} (HTTPS). Managed file: `cecp-panel site rebuild-vhost {{DOMAIN}}` rewrites it.
{{ADMIN_GUARD_HTTP}}
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    location ^~ /.well-known/acme-challenge/ {
        root {{DOCROOT}};
        default_type "text/plain";
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
{{LISTEN_SSL}}
    server_name {{DOMAIN}};

    ssl_certificate     /etc/letsencrypt/live/{{DOMAIN}}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{DOMAIN}}/privkey.pem;
    include /etc/nginx/snippets/cecp-ssl-params.conf;
    set $cecp_hsts "{{HSTS}}";

{{SITE_BODY}}
}
