<?php
/**
 * Plugin Name: CECP Media Optimize
 * Description: On-upload image resize/compress for CECP Panel (per-site opt-in).
 * Version: 1.0.0
 * Author: CECP
 *
 * Managed by: cecp-panel media enable|disable
 * Config file: wp-content/mu-plugins/cecp-media-optimize.json
 */

if (!defined('ABSPATH')) {
    exit;
}

final class Cecp_Media_Optimize {
    private static $cfg = null;

    public static function boot() {
        $cfg = self::config();
        if (empty($cfg['enabled']) || empty($cfg['on_upload'])) {
            return;
        }
        add_filter('wp_handle_upload', [__CLASS__, 'on_upload'], 20);
        add_filter('wp_generate_attachment_metadata', [__CLASS__, 'on_metadata'], 20, 2);
        add_filter('jpeg_quality', [__CLASS__, 'jpeg_quality'], 20);
        add_filter('wp_editor_set_quality', [__CLASS__, 'jpeg_quality'], 20);
        if (!empty($cfg['max_width'])) {
            add_filter('big_image_size_threshold', [__CLASS__, 'big_image_threshold'], 20);
        }
    }

    private static function config() {
        if (self::$cfg !== null) {
            return self::$cfg;
        }
        $path = WPMU_PLUGIN_DIR . '/cecp-media-optimize.json';
        $defaults = [
            'enabled' => false,
            'on_upload' => true,
            'max_width' => 1920,
            'max_height' => 1920,
            'quality' => 80,
            'webp' => true,
            'skip_under_kb' => 200,
        ];
        if (!is_readable($path)) {
            self::$cfg = $defaults;
            return self::$cfg;
        }
        $raw = json_decode((string) file_get_contents($path), true);
        if (!is_array($raw)) {
            self::$cfg = $defaults;
            return self::$cfg;
        }
        self::$cfg = array_merge($defaults, $raw);
        return self::$cfg;
    }

    public static function jpeg_quality($q) {
        $cfg = self::config();
        $quality = isset($cfg['quality']) ? (int) $cfg['quality'] : 80;
        if ($quality < 40 || $quality > 95) {
            $quality = 80;
        }
        return $quality;
    }

    public static function big_image_threshold($threshold) {
        $cfg = self::config();
        $w = (int) ($cfg['max_width'] ?? 1920);
        return max(1, $w);
    }

    public static function on_upload($upload) {
        if (!empty($upload['error']) || empty($upload['file']) || empty($upload['type'])) {
            return $upload;
        }
        if (strpos($upload['type'], 'image/') !== 0) {
            return $upload;
        }
        if (in_array($upload['type'], ['image/svg+xml', 'image/gif'], true)) {
            return $upload;
        }
        self::optimize_file($upload['file']);
        return $upload;
    }

    public static function on_metadata($metadata, $attachment_id) {
        if (empty($metadata['file'])) {
            return $metadata;
        }
        $upload_dir = wp_get_upload_dir();
        $base = trailingslashit($upload_dir['basedir']);
        $full = $base . $metadata['file'];
        if (is_file($full)) {
            self::optimize_file($full);
        }
        if (!empty($metadata['sizes']) && is_array($metadata['sizes'])) {
            $dir = trailingslashit(dirname($full));
            foreach ($metadata['sizes'] as $size) {
                if (empty($size['file'])) {
                    continue;
                }
                $path = $dir . $size['file'];
                if (is_file($path)) {
                    self::optimize_file($path, true);
                }
            }
        }
        return $metadata;
    }

    private static function optimize_file($path, $is_size = false) {
        if (!is_file($path) || !is_readable($path)) {
            return;
        }
        $cfg = self::config();
        $skip_kb = (int) ($cfg['skip_under_kb'] ?? 200);
        $size = filesize($path);
        if ($size !== false && $size < ($skip_kb * 1024) && $is_size) {
            return;
        }

        $editor = wp_get_image_editor($path);
        if (is_wp_error($editor)) {
            return;
        }

        $max_w = (int) ($cfg['max_width'] ?? 1920);
        $max_h = (int) ($cfg['max_height'] ?? 1920);
        $quality = (int) ($cfg['quality'] ?? 80);
        if ($quality < 40 || $quality > 95) {
            $quality = 80;
        }

        $dims = $editor->get_size();
        if (is_array($dims) && !empty($dims['width']) && !empty($dims['height'])) {
            if ($dims['width'] > $max_w || $dims['height'] > $max_h) {
                $editor->resize($max_w, $max_h, false);
            }
        }
        $editor->set_quality($quality);
        $saved = $editor->save($path);
        if (is_wp_error($saved)) {
            return;
        }

        if (!empty($cfg['webp']) && function_exists('imagewebp')) {
            self::maybe_write_sidecar($path, $quality, 'webp');
        }
        // imageavif: PHP >= 8.1 with a GD built against libavif.
        if (!empty($cfg['avif']) && function_exists('imageavif')) {
            self::maybe_write_sidecar($path, max(30, $quality - 20), 'avif');
        }

        $marker = $path . '.cecp-opt';
        @file_put_contents($marker, gmdate('c') . " optimized\n");
    }

    /** photo.jpg -> photo.webp / photo.avif: the names nginx negotiates on the Accept header. */
    private static function maybe_write_sidecar($path, $quality, $format) {
        $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
        if (!in_array($ext, ['jpg', 'jpeg', 'png'], true)) {
            return;
        }
        $out = preg_replace('/\.(jpe?g|png)$/i', '.' . $format, $path);
        if (!$out || $out === $path) {
            return;
        }
        if (is_file($out) && filemtime($out) >= filemtime($path)) {
            return;
        }

        $data = @file_get_contents($path);
        if ($data === false) {
            return;
        }
        $img = @imagecreatefromstring($data);
        if (!$img) {
            return;
        }
        if (function_exists('imagepalettetotruecolor')) {
            @imagepalettetotruecolor($img);
        }
        @imagealphablending($img, true);
        @imagesavealpha($img, true);
        if ($format === 'avif') {
            @imageavif($img, $out, $quality);
        } else {
            @imagewebp($img, $out, $quality);
        }
        imagedestroy($img);
    }
}

Cecp_Media_Optimize::boot();
