#lang racket/base
;; ============================================================
;; 扩展选择：把命令行第 4 参数解析成扩展名列表。
;;
;;   ""             -> 不纳入任何扩展
;;   "common"       -> 常用扩展集（与测试/README 对齐）
;;   "all"          -> 所有 includable（非 provisional、非 disabled、api=vulkan）
;;   "A,B,C"        -> 显式逗号列表
;;
;; 依赖闭包与 provisional/disabled 过滤仍由 vk-registry.rkt 负责。
;; ============================================================

(require racket/list
         racket/string
         "xexpr.rkt"
         "vk-registry.rkt")

(provide common-extensions resolve-extensions)

(define common-extensions
  '("VK_KHR_surface" "VK_KHR_swapchain" "VK_KHR_xcb_surface" "VK_KHR_xlib_surface"
    "VK_KHR_wayland_surface" "VK_EXT_debug_utils"
    "VK_KHR_get_physical_device_properties2" "VK_KHR_get_surface_capabilities2"
    "VK_KHR_display" "VK_EXT_headless_surface"))

(define (includable-extension-names reg)
  (for/list ([e (in-list (registry-extensions reg))]
             #:when (and (extension-includable? e) (attr e 'name)))
    (attr e 'name)))

(define (resolve-extensions reg arg)
  (define a (string-trim arg))
  (cond
    [(string=? a "") '()]
    [(string=? a "common") common-extensions]
    [(string=? a "all") (includable-extension-names reg)]
    [else (filter (λ (s) (not (string=? s ""))) (string-split a ","))]))
