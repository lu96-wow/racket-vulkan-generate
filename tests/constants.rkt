#lang racket/base
;; ============================================================
;; 常量值解析回归：
;;   * `~N` 位取反（`VK_QUEUE_FAMILY_*`、`VK_WHOLE_SIZE`）—— 含 `~1U`/`~2U`
;;   * 字符串扩展名常量（`VK_*_EXTENSION_NAME`）—— 解析为 bytes
;; ============================================================

(require rackunit
         (only-in vulkan/bindings
                  VK_QUEUE_FAMILY_IGNORED VK_QUEUE_FAMILY_EXTERNAL VK_QUEUE_FAMILY_FOREIGN_EXT
                  VK_WHOLE_SIZE
                  VK_KHR_SURFACE_EXTENSION_NAME VK_EXT_DEBUG_UTILS_EXTENSION_NAME
                  VK_SUCCESS VK_TRUE VK_FALSE))

;; ~0U / ~1U / ~2U（32 位全 1 减去 n）
(check-equal? VK_QUEUE_FAMILY_IGNORED     (- (expt 2 32) 1))
(check-equal? VK_QUEUE_FAMILY_EXTERNAL    (- (expt 2 32) 2))
(check-equal? VK_QUEUE_FAMILY_FOREIGN_EXT (- (expt 2 32) 3))
;; ~0ULL（64 位全 1）
(check-equal? VK_WHOLE_SIZE (- (expt 2 64) 1))
;; 普通整数仍然正确
(check-equal? VK_SUCCESS 0)
(check-equal? VK_FALSE 0)
(check-equal? VK_TRUE 1)

;; 字符串扩展名常量（bytes，可直接喂给 _string/utf-8 / vk-cstring）
(check-equal? VK_KHR_SURFACE_EXTENSION_NAME #"VK_KHR_surface")
(check-equal? VK_EXT_DEBUG_UTILS_EXTENSION_NAME #"VK_EXT_debug_utils")

(printf "constants: all checks passed\n")
