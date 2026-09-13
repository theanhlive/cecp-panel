<?php
/**
 * Plugin Name: CECP Staging Guard
 * Description: This is a staging copy — outgoing e-mail and background jobs are blocked, search engines are asked not to index.
 * Version: 1.0.0
 * Author: CECP
 *
 * Managed by: cecp-panel site staging. Removed automatically when staging is pushed to live.
 */

if (!defined('ABSPATH')) {
    exit;
}

// Customers must not get order / password / newsletter mails from a copy of the shop.
add_filter('pre_wp_mail', '__return_false', PHP_INT_MAX);

// No background jobs (WooCommerce Action Scheduler: renewals, webhooks, syncs).
add_filter('action_scheduler_allow_async_request_runner', '__return_false', PHP_INT_MAX);
add_filter('action_scheduler_queue_runner_concurrent_batches', '__return_zero', PHP_INT_MAX);

add_filter('pre_option_blog_public', function () {
    return '0';
});

add_action('admin_bar_menu', function ($bar) {
    $bar->add_node([
        'id'    => 'cecp-staging',
        'title' => 'STAGING',
        'meta'  => ['title' => 'Staging copy — e-mail and background jobs are disabled'],
    ]);
}, 1);

add_action('admin_head', 'cecp_staging_bar_style');
add_action('wp_head', 'cecp_staging_bar_style');
function cecp_staging_bar_style() {
    if (is_admin_bar_showing()) {
        echo '<style>#wpadminbar{background:#b32d2e!important}#wp-admin-bar-cecp-staging>.ab-item{font-weight:700}</style>';
    }
}
