#lang racket/base
;; ============================================================
;; 兼容入口：bindings（基础绑定）+ memory（所有权原语）。
;;
;; 新代码建议按职责分别 require：
;;   (require vulkan/bindings)  ; 只要原始 FFI 绑定（命令返回 VkResult）
;;   (require vulkan/memory)    ; 只要内存/所有权原语
;;   (require vulkan/safe)      ; 原始 + 所有权 + 错误抛出 + create/destroy 包装
;;
;; 注意：本入口不定义 check-vk-result（错误策略属于 vulkan/safe）。
;; ============================================================

(require "bindings.rkt"
         "memory.rkt")

(provide (all-from-out "bindings.rkt")
         (all-from-out "memory.rkt"))
