; CECP Panel pool — {{DOMAIN}} (PHP {{PHP_VERSION}}). Managed file: `cecp-panel site rebuild-vhost` rewrites it.
[{{POOL_NAME}}]
user = {{SITE_USER}}
group = {{SITE_USER}}
listen = {{PHP_SOCK}}
listen.owner = nginx
listen.group = nginx
listen.mode = 0660
pm = ondemand
; Sized from RAM and site count at render time (cecp-panel site rebuild-vhost --all re-sizes).
pm.max_children = {{PM_MAX_CHILDREN}}
; 60s: with 10s, quiet sites respawned a worker on almost every request (slower TTFB).
pm.process_idle_timeout = 60s
pm.max_requests = 500
; Per-site temp/session dir: a shared /tmp let one site read another site's sessions and uploads.
php_admin_value[open_basedir] = {{DOCROOT}}:{{SITE_HOME}}/tmp
php_admin_value[upload_tmp_dir] = {{SITE_HOME}}/tmp
php_admin_value[session.save_path] = {{SITE_HOME}}/tmp
php_admin_value[sys_temp_dir] = {{SITE_HOME}}/tmp
php_admin_value[memory_limit] = 256M
php_admin_value[post_max_size] = 64M
php_admin_value[upload_max_filesize] = 64M
php_admin_value[max_execution_time] = 120
php_admin_flag[log_errors] = on
php_admin_flag[expose_php] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,parse_ini_file,show_source,pcntl_exec,pcntl_fork
; OPcache/JIT sizes are server-wide (shared memory allocated when the FPM master starts);
; per-pool values had no effect. Tune with: cecp-panel optimize opcache
