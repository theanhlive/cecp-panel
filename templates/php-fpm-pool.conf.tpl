; CECP Panel pool — {{DOMAIN}}
[{{POOL_NAME}}]
user = {{SITE_USER}}
group = {{SITE_USER}}
listen = {{PHP_SOCK}}
listen.owner = nginx
listen.group = nginx
listen.mode = 0660
pm = ondemand
pm.max_children = 8
pm.process_idle_timeout = 10s
pm.max_requests = 400
php_admin_value[open_basedir] = {{DOCROOT}}:/tmp
php_admin_value[upload_tmp_dir] = /tmp
php_admin_value[session.save_path] = /tmp
php_admin_value[memory_limit] = 256M
php_admin_value[post_max_size] = 64M
php_admin_value[upload_max_filesize] = 64M
php_admin_value[max_execution_time] = 120
php_admin_flag[log_errors] = on
php_admin_flag[expose_php] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,parse_ini_file,show_source,pcntl_exec,pcntl_fork
php_value[opcache.enable] = 1
php_value[opcache.memory_consumption] = 128
php_value[opcache.max_accelerated_files] = 10000
php_value[opcache.revalidate_freq] = 60
; JIT when PHP 8+ (ignored silently on older)
php_value[opcache.jit] = 1255
php_value[opcache.jit_buffer_size] = 64M
