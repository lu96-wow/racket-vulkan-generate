#lang racket/base
;; ============================================================
;; 命名契约（方案 A）防回归：靠模块隔离，而非命名前缀
;;
;;   * vulkan（facade）：糖用 Vulkan 原生名，裸命令 raw: 前缀
;;   * vulkan/safe     ：糖（原生名），不导出裸命令
;;   * vulkan/bindings ：裸命令（原生名）
;;   * vulkan/raw      ：= bindings
;; ============================================================

(require rackunit
         ffi/unsafe
         vulkan
         (prefix-in s: vulkan/safe)
         (prefix-in b: vulkan/bindings)
         (prefix-in r: vulkan/raw))

;; facade：糖无前缀，裸命令 raw:
(check-true (procedure? vkCreateBuffer))
(check-true (procedure? raw:vkCreateBuffer))

;; 糖与裸命令是不同过程（同名不同模块）
(check-false (eq? vkCreateBuffer raw:vkCreateBuffer)
             "safe sugar and raw command are distinct bindings")

;; facade 的 raw: 与 bindings/raw 的裸命令是同一绑定
(check-true (eq? raw:vkCreateBuffer b:vkCreateBuffer))
(check-true (eq? raw:vkCreateBuffer r:vkCreateBuffer))

;; safe 的糖与 bindings 的裸命令不同
(check-false (eq? s:vkCreateBuffer b:vkCreateBuffer))

;; 类型/常量/原子在 facade 里无前缀
(check-true (ctype? _VkBuffer))
(check-true (procedure? vk-malloc))

(printf "module-surface: all checks passed\n")
