<?php
/**
 * Plugin Name: CECP Media Optimize
 * Description: On-upload image optimisation for CECP Panel (per-site opt-in): any image format in,
 *              one right-sized WebP/AVIF out, the original is not kept.
 * Version: 2.0.0
 * Author: CECP
 *
 * Managed by: cecp-panel media enable|disable
 * Config file: wp-content/mu-plugins/cecp-media-optimize.json
 *
 * format = "webp" | "avif": every upload (JPEG, PNG, WebP, BMP, TIFF, HEIC/HEIF when the image
 *   editor can read it) is auto-rotated, shrunk to max_width x max_height (never enlarged) and
 *   stored as ONE file in that format; the upload itself is deleted. WordPress then has no
 *   oversized original to keep (no "-scaled"/"-rotated" + original pair) and its sub-sizes are
 *   generated in the same format. GIF (animation) and SVG are left alone.
 * format = "original": previous behaviour — same format, recompressed, WebP/AVIF sidecars that
 *   nginx serves by Accept header.
 */

if (!defined('ABSPATH')) {
    exit;
}

final class Cecp_Media_Optimize {
    private static $cfg = null;

    /** Formats browsers cannot show (or WordPress cannot resize): always converted. */
    const FOREIGN = ['image/heic', 'image/heif', 'image/tiff', 'image/bmp', 'image/x-ms-bmp'];

    public static function boot() {
        $cfg = self::config();
        if (empty($cfg['enabled']) || empty($cfg['on_upload'])) {
            return;
        }
        add_filter('upload_mimes', [__CLASS__, 'upload_mimes']);
        add_filter('wp_handle_upload', [__CLASS__, 'on_upload'], 20);
        add_filter('jpeg_quality', [__CLASS__, 'jpeg_quality'], 20);
        add_filter('wp_editor_set_quality', [__CLASS__, 'editor_quality'], 20, 2);
        add_filter('big_image_size_threshold', [__CLASS__, 'big_image_threshold'], 20);
        if (self::target_mime('image/jpeg') !== 'image/jpeg') {
            // Sub-sizes in the target format too (e.g. a JPEG that was kept because it was smaller).
            add_filter('image_editor_output_format', [__CLASS__, 'output_format'], 20);
        } else {
            add_filter('wp_generate_attachment_metadata', [__CLASS__, 'on_metadata'], 20, 2);
        }
    }

    private static function config() {
        if (self::$cfg !== null) {
            return self::$cfg;
        }
        $defaults = [
            'enabled' => false,
            'on_upload' => true,
            // Configs written before 2.0 have no "format": keep their behaviour.
            'format' => 'original',
            'max_width' => 1920,
            'max_height' => 1920,
            'quality' => 80,
            'webp' => true,
            'avif' => false,
            'skip_under_kb' => 200,
        ];
        $path = WPMU_PLUGIN_DIR . '/cecp-media-optimize.json';
        $raw = is_readable($path) ? json_decode((string) file_get_contents($path), true) : null;
        self::$cfg = is_array($raw) ? array_merge($defaults, $raw) : $defaults;
        return self::$cfg;
    }

    private static function quality() {
        $q = (int) (self::config()['quality'] ?? 80);
        return ($q < 40 || $q > 95) ? 80 : $q;
    }

    private static function supports($mime) {
        return function_exists('wp_image_editor_supports') && wp_image_editor_supports(['mime_type' => $mime]);
    }

    /** Output MIME for a source MIME, falling back when the server cannot encode the choice. */
    private static function target_mime($source) {
        $format = (string) (self::config()['format'] ?? 'original');
        if ($format === 'avif' && self::supports('image/avif')) {
            return 'image/avif';
        }
        if (($format === 'avif' || $format === 'webp') && self::supports('image/webp')) {
            return 'image/webp';
        }
        return in_array($source, self::FOREIGN, true) ? 'image/jpeg' : $source;
    }

    public static function output_format($formats) {
        $formats = is_array($formats) ? $formats : [];
        foreach (['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/heic', 'image/heif', 'image/tiff', 'image/bmp'] as $m) {
            $t = self::target_mime($m);
            if ($t !== $m) {
                $formats[$m] = $t;
            }
        }
        return $formats;
    }

    /** HEIC/HEIF (iPhone photos) accepted when the editor (Imagick + libheif) can read them. */
    public static function upload_mimes($mimes) {
        if (self::supports('image/heic')) {
            $mimes['heic'] = 'image/heic';
            $mimes['heif'] = 'image/heif';
        }
        return $mimes;
    }

    public static function jpeg_quality($q) {
        return self::quality();
    }

    public static function editor_quality($q, $mime = '') {
        // AVIF reaches the same visual quality at a lower number.
        return $mime === 'image/avif' ? max(30, self::quality() - 20) : self::quality();
    }

    public static function big_image_threshold($threshold) {
        $cfg = self::config();
        return max(1, (int) ($cfg['max_width'] ?? 1920), (int) ($cfg['max_height'] ?? 1920));
    }

    /** Animated GIF/WebP/PNG: the editors would keep only the first frame. */
    private static function is_animated($path, $mime) {
        $head = (string) @file_get_contents($path, false, null, 0, 256 * 1024);
        if ($mime === 'image/webp') {
            return strpos($head, 'ANIM') !== false;
        }
        if ($mime === 'image/png') {
            return strpos($head, 'acTL') !== false;
        }
        return false;
    }

    /** GD decodes the whole bitmap into PHP memory: skip (rather than crash the upload) if it cannot fit. */
    private static function fits_in_memory($path) {
        if (self::supports_imagick()) {
            return true;
        }
        $size = @getimagesize($path);
        if (!$size) {
            return true;
        }
        $need = $size[0] * $size[1] * 5 + memory_get_usage();
        $limit = wp_convert_hr_to_bytes((string) ini_get('memory_limit'));
        return $limit <= 0 || $need < $limit;
    }

    private static function supports_imagick() {
        return class_exists('Imagick') && in_array('WP_Image_Editor_Imagick', (array) apply_filters('wp_image_editors', ['WP_Image_Editor_Imagick', 'WP_Image_Editor_GD']), true);
    }

    public static function on_upload($upload) {
        if (!empty($upload['error']) || empty($upload['file']) || empty($upload['type'])) {
            return $upload;
        }
        $src = $upload['file'];
        $mime = (string) $upload['type'];
        if (strpos($mime, 'image/') !== 0 || in_array($mime, ['image/svg+xml', 'image/gif'], true)
            || !is_file($src) || self::is_animated($src, $mime)) {
            return $upload;
        }
        if (function_exists('wp_raise_memory_limit')) {
            wp_raise_memory_limit('image');
        }
        if (!self::fits_in_memory($src)) {
            return $upload;
        }
        $target = self::target_mime($mime);
        if ($target === $mime && !in_array($mime, ['image/jpeg', 'image/png', 'image/webp', 'image/avif'], true)) {
            return $upload;
        }
        // BMP: the GD image editor cannot open it, PHP's GD can — decode to a lossless PNG first.
        $work = $src;
        if (in_array($mime, ['image/bmp', 'image/x-ms-bmp'], true) && !self::supports($mime) && function_exists('imagecreatefrombmp')) {
            $bmp = @imagecreatefrombmp($src);
            if ($bmp) {
                $work = dirname($src) . '/' . pathinfo($src, PATHINFO_FILENAME) . '.cecp-src.png';
                $ok = @imagepng($bmp, $work, 1);
                imagedestroy($bmp);
                if (!$ok) {
                    @unlink($work);
                    $work = $src;
                }
            }
        }
        $editor = wp_get_image_editor($work);
        if ($work !== $src) {
            @unlink($work);
        }
        if (is_wp_error($editor)) {
            // e.g. HEIC/TIFF without Imagick: stored as uploaded (media status shows what is supported).
            return $upload;
        }

        $cfg = self::config();
        // Rotate by EXIF so WordPress does not keep a "-rotated" copy next to the original.
        $changed = false;
        if (method_exists($editor, 'maybe_exif_rotate')) {
            $rot = $editor->maybe_exif_rotate();
            $changed = $rot === true;
        }
        $max_w = max(1, (int) ($cfg['max_width'] ?? 1920));
        $max_h = max(1, (int) ($cfg['max_height'] ?? 1920));
        $dims = $editor->get_size();
        if (is_array($dims) && ($dims['width'] > $max_w || $dims['height'] > $max_h)) {
            // resize() never enlarges: small images keep their pixels (no blur, no blocky upscaling).
            if (!is_wp_error($editor->resize($max_w, $max_h, false))) {
                $changed = true;
            }
        }
        // Screenshots, logos, text (PNG sources): a higher quality keeps edges and lettering crisp.
        $quality = self::quality();
        if ($mime === 'image/png') {
            $quality = min(95, $quality + 10);
        }
        if ($target === 'image/avif') {
            $quality = max(30, $quality - 20);
        }
        $editor->set_quality($quality);

        $dir = dirname($src);
        $ext = ['image/webp' => 'webp', 'image/avif' => 'avif', 'image/jpeg' => 'jpg', 'image/png' => 'png'][$target] ?? '';
        if ($ext === '') {
            return $upload;
        }
        $name = pathinfo($src, PATHINFO_FILENAME);
        $dest = $dir . '/' . $name . '.cecp-tmp.' . $ext;
        $saved = $editor->save($dest, $target);
        if (is_wp_error($saved) || empty($saved['path']) || !is_file($saved['path'])) {
            return $upload;
        }
        $dest = $saved['path'];
        clearstatcache();
        $before = (int) filesize($src);
        $after = (int) filesize($dest);

        // An already-web image that got no smaller (and needed no resize/rotation): keep it as is.
        if (!$changed && !in_array($mime, self::FOREIGN, true) && $after >= $before) {
            @unlink($dest);
            self::mark($src);
            if ($target === $mime) {
                self::sidecars($src);
            }
            return $upload;
        }

        if ($target === $mime) {
            // Same format: replace in place, name and URL unchanged.
            if (!@rename($dest, $src)) {
                @unlink($dest);
                return $upload;
            }
            self::mark($src);
            self::sidecars($src);
            return $upload;
        }

        // New format: the upload is replaced by the converted file — the original is NOT kept.
        // Name chosen only after the original is gone (else WordPress sees photo.jpg and makes it
        // photo-1.webp to avoid a clash between image formats).
        @unlink($src);
        $final = $dir . '/' . wp_unique_filename($dir, $name . '.' . $ext);
        if (!@rename($dest, $final)) {
            $final = $dest;
        }
        $dest = $final;
        $upload['file'] = $dest;
        $upload['url'] = trailingslashit(dirname($upload['url'])) . basename($dest);
        $upload['type'] = $target;
        return $upload;
    }

    /** format=original: sub-sizes get the same treatment as before (recompress + sidecars). */
    public static function on_metadata($metadata, $attachment_id) {
        if (empty($metadata['file']) || empty($metadata['sizes']) || !is_array($metadata['sizes'])) {
            return $metadata;
        }
        $upload_dir = wp_get_upload_dir();
        $dir = trailingslashit(dirname(trailingslashit($upload_dir['basedir']) . $metadata['file']));
        foreach ($metadata['sizes'] as $size) {
            if (!empty($size['file']) && is_file($dir . $size['file'])) {
                self::sidecars($dir . $size['file']);
            }
        }
        return $metadata;
    }

    /** Marker read by the `media run` batch, which only handles JPEG/PNG. */
    private static function mark($path) {
        if (!preg_match('/\.(jpe?g|png)$/i', $path)) {
            return;
        }
        @file_put_contents($path . '.cecp-opt', gmdate('c') . " optimized\n");
    }

    /** format=original: photo.jpg -> photo.webp / photo.avif, the names nginx negotiates on Accept. */
    private static function sidecars($path) {
        $cfg = self::config();
        if (!in_array(strtolower(pathinfo($path, PATHINFO_EXTENSION)), ['jpg', 'jpeg', 'png'], true)) {
            return;
        }
        if (!empty($cfg['webp']) && function_exists('imagewebp')) {
            self::sidecar($path, self::quality(), 'webp');
        }
        if (!empty($cfg['avif']) && function_exists('imageavif')) {
            self::sidecar($path, max(30, self::quality() - 20), 'avif');
        }
    }

    private static function sidecar($path, $quality, $format) {
        $out = preg_replace('/\.(jpe?g|png)$/i', '.' . $format, $path);
        if (!$out || $out === $path || (is_file($out) && filemtime($out) >= filemtime($path))) {
            return;
        }
        $data = @file_get_contents($path);
        $img = $data === false ? false : @imagecreatefromstring($data);
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
        // nginx prefers the sidecar: one that is not smaller than the original only costs bandwidth.
        clearstatcache(true, $out);
        if (is_file($out) && filesize($out) >= filesize($path)) {
            @unlink($out);
        }
    }
}

Cecp_Media_Optimize::boot();
