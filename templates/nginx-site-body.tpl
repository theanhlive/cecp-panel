    root {{DOCROOT}};
    index index.php index.html;

    access_log /var/log/nginx/{{DOMAIN}}-access.log cecp;
    error_log  /var/log/nginx/{{DOMAIN}}-error.log;

    include /etc/nginx/snippets/cecp-headers.conf;

    # Deny rules come first: nginx uses the FIRST matching regex location, so anything after
    # "location ~ \.php$" would never apply (uploaded .php files would execute).
    location ~* /(?:uploads|files)/.*\.(?:php[0-9]?|phtml|phar)$ { deny all; }
    location ~* ^/wp-includes/[^/]+\.php$ { deny all; }
    location ~* ^/wp-admin/includes/ { deny all; }
    location = /wp-config.php { deny all; }
    location = /xmlrpc.php { deny all; }
    location ~ /\.(?!well-known) { deny all; }
    location ~* \.(?:env|git|svn|htaccess|htpasswd|sql|bak|log|ini|sh|swp)$ { deny all; }

    location / {
        # Dynamic HTML only — never rate-limit static assets (browsers load 50+ in parallel).
        limit_req zone=cecp_general burst=50 nodelay;
        limit_conn cecp_conn 80;
        try_files $uri $uri/ /index.php?$args;
    }

    location ~* \.(?:jpg|jpeg|png|gif|ico|css|js|mjs|woff2?|ttf|otf|eot|svg|webp|avif|mp4|webm|pdf)$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, max-age=2592000";
        include /etc/nginx/snippets/cecp-headers.conf;
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

        # Micro-cache anonymous pages; bypass logged-in users, carts, previews, search, admin.
        set $cecp_skip_cache 0;
        if ($http_cookie ~* "wordpress_logged_in|wp-postpass|woocommerce_items_in_cart|woocommerce_cart_hash|comment_author") {
            set $cecp_skip_cache 1;
        }
        if ($request_method !~ ^(GET|HEAD)$) { set $cecp_skip_cache 1; }
        if ($args ~* "(^|&)(preview[a-z_]*|customize_changeset[a-z_]*|add-to-cart|wc-ajax|s)=") {
            set $cecp_skip_cache 1;
        }
        if ($request_uri ~* "^/(wp-admin|wp-login\.php|cart|checkout|my-account|wc-api)") {
            set $cecp_skip_cache 1;
        }
        fastcgi_cache_bypass $cecp_skip_cache;
        fastcgi_no_cache $cecp_skip_cache;
        fastcgi_cache CECP_WP;
        # open_file_cache would keep serving a purged (deleted) cache file from its cached fd.
        open_file_cache off;
        fastcgi_cache_valid 200 301 302 5m;
        fastcgi_cache_valid 404 1m;
        add_header X-CECP-Cache $upstream_cache_status;
        include /etc/nginx/snippets/cecp-headers.conf;
    }
