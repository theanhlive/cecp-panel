# CECP Panel — {{DOMAIN}}
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};
    root {{DOCROOT}};
    index index.php index.html;

    access_log /var/log/nginx/{{DOMAIN}}-access.log;
    error_log  /var/log/nginx/{{DOMAIN}}-error.log;

    # Security headers (HTTPS block added by certbot / ssl snippet)
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # NOTE: Do NOT put limit_req/limit_conn at server level — that also throttles
    # static images/CSS/JS and causes intermittent 503 / broken images on WP pages.

    location / {
        # Dynamic HTML only
        limit_req zone=cecp_general burst=50 nodelay;
        limit_conn cecp_conn 80;
        try_files $uri $uri/ /index.php?$args;
    }

    # Static assets — cache, no rate limit (browser parallel loads 50+ assets)
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?|ttf|svg|webp|avif)$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, immutable";
    }

    location ~ \.php$ {
        limit_req zone=cecp_general burst=50 nodelay;
        limit_conn cecp_conn 80;
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:{{PHP_SOCK}};
        fastcgi_read_timeout 120s;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;

        # Micro-cache anonymous WP pages (skip logged-in / cart / preview)
        set $cecp_skip_cache 0;
        if ($http_cookie ~* "wordpress_logged_in|wp-postpass|woocommerce_items_in_cart|woocommerce_cart_hash|comment_author") {
            set $cecp_skip_cache 1;
        }
        if ($request_method != GET) { set $cecp_skip_cache 1; }
        if ($query_string ~* "(preview|customize_changeset|add-to-cart|wc-ajax|s=)") {
            set $cecp_skip_cache 1;
        }
        if ($request_uri ~* "^/(wp-admin|wp-login\.php|cart|checkout|my-account|wc-api)") {
            set $cecp_skip_cache 1;
        }
        fastcgi_cache_bypass $cecp_skip_cache;
        fastcgi_no_cache $cecp_skip_cache;
        fastcgi_cache CECP_WP;
        fastcgi_cache_valid 200 301 302 5m;
        fastcgi_cache_valid 404 1m;
        add_header X-CECP-Cache $upstream_cache_status;
    }

    location ~ /\.(?!well-known).* { deny all; }
    location ~* \.(env|git|svn|htaccess|sql|bak)$ { deny all; }
    location = /xmlrpc.php { deny all; }
    location ~* /(?:uploads|files)/.*\.php$ { deny all; }
}
