<?php
/**
 * Plugin Name: CECP Cache Purge
 * Description: Queues page-cache purges when content changes; CECP Panel purges nginx (and the Cloudflare edge) as root.
 * Version: 1.0.0
 * Author: CECP
 *
 * Managed by: cecp-panel cache auto-purge DOMAIN on|off
 * Config file: wp-content/mu-plugins/cecp-cache-purge.json
 */

if (!defined('ABSPATH')) {
    exit;
}

final class Cecp_Cache_Purge {
    /** @var array<string,bool> */
    private static $urls = [];
    private static $all = false;
    private static $queue = '';

    public static function boot() {
        $cfg = @json_decode((string) @file_get_contents(WPMU_PLUGIN_DIR . '/cecp-cache-purge.json'), true);
        if (!is_array($cfg) || empty($cfg['queue'])) {
            return;
        }
        self::$queue = (string) $cfg['queue'];

        add_action('transition_post_status', [__CLASS__, 'on_post_status'], 10, 3);
        add_action('deleted_post', [__CLASS__, 'on_post_id']);
        add_action('comment_post', [__CLASS__, 'on_comment_id']);
        add_action('edit_comment', [__CLASS__, 'on_comment_id']);
        add_action('transition_comment_status', [__CLASS__, 'on_comment_status'], 10, 3);
        add_action('woocommerce_product_set_stock', [__CLASS__, 'on_product']);
        add_action('woocommerce_variation_set_stock', [__CLASS__, 'on_product']);

        foreach (['switch_theme', 'customize_save_after', 'wp_update_nav_menu', 'activated_plugin',
                  'deactivated_plugin', 'upgrader_process_complete'] as $hook) {
            add_action($hook, [__CLASS__, 'purge_all']);
        }
        add_action('updated_option', [__CLASS__, 'on_option']);
        add_action('shutdown', [__CLASS__, 'flush']);
    }

    public static function on_post_status($new, $old, $post) {
        // Updates to published posts fire publish→publish; unpublishing fires publish→draft/trash.
        if ($new === 'publish' || $old === 'publish') {
            self::add_post($post->ID);
        }
    }

    public static function on_post_id($post_id) {
        self::add_post((int) $post_id);
    }

    public static function on_comment_id($comment_id) {
        $c = get_comment($comment_id);
        if ($c) {
            self::add_post((int) $c->comment_post_ID);
        }
    }

    public static function on_comment_status($new, $old, $comment) {
        self::add_post((int) $comment->comment_post_ID);
    }

    public static function on_product($product) {
        if (!is_object($product) || !method_exists($product, 'get_id')) {
            return;
        }
        $id = method_exists($product, 'get_parent_id') && $product->get_parent_id() ? $product->get_parent_id() : $product->get_id();
        self::add_post((int) $id);
        if (function_exists('wc_get_page_permalink')) {
            self::add(wc_get_page_permalink('shop'));
        }
    }

    public static function on_option($option) {
        $global = ['blogname', 'blogdescription', 'permalink_structure', 'sidebars_widgets', 'page_on_front',
                   'page_for_posts', 'show_on_front', 'posts_per_page', 'template', 'stylesheet'];
        if (in_array($option, $global, true) || strpos((string) $option, 'widget_') === 0 || strpos((string) $option, 'theme_mods_') === 0) {
            self::purge_all();
        }
    }

    public static function purge_all() {
        self::$all = true;
    }

    private static function add($url) {
        if (is_string($url) && $url !== '') {
            self::$urls[$url] = true;
        }
    }

    private static function add_post($post_id) {
        $type = get_post_type($post_id);
        if (!$type || wp_is_post_revision($post_id) || !is_post_type_viewable($type)) {
            return;
        }
        self::add(get_permalink($post_id));
        self::add(home_url('/'));
        self::add(get_feed_link());
        $archive = get_post_type_archive_link($type);
        if ($archive) {
            self::add($archive);
        }
        $author = (int) get_post_field('post_author', $post_id);
        if ($author) {
            self::add(get_author_posts_url($author));
        }
        foreach (get_object_taxonomies($type) as $tax) {
            $terms = get_the_terms($post_id, $tax);
            if (is_array($terms)) {
                foreach ($terms as $term) {
                    $link = get_term_link($term);
                    if (!is_wp_error($link)) {
                        self::add($link);
                    }
                }
            }
        }
    }

    public static function flush() {
        if (!self::$all && !self::$urls) {
            return;
        }
        $lines = self::$all || count(self::$urls) > 200 ? ['*'] : array_keys(self::$urls);
        @file_put_contents(self::$queue, implode("\n", $lines) . "\n", FILE_APPEND | LOCK_EX);
        self::$urls = [];
        self::$all = false;
    }
}

Cecp_Cache_Purge::boot();
