# CECP Panel — {{DOMAIN}} (HTTP). Managed file: `cecp-panel site rebuild-vhost {{DOMAIN}}` rewrites it.
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};
    set $cecp_hsts "";

{{SITE_BODY}}
}
