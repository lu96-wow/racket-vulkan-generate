#lang racket/base
;; ============================================================
;; 手动模式入口（vulkan/manual）：bindings（原始 FFI）+ memory（所有权原语）。
;;
;; 用途：自己管理生命周期的用户，拿到「裸命令 + arena 原语」，不引入 safe 的
;; 错误抛出/包装策略。与自动模式 vulkan/safe 对称。
;;
;;   (require vulkan/manual)   ; 裸绑定 + 内存原语
;;   (require vulkan/bindings) ; 只要原始 FFI
;;   (require vulkan/memory)   ; 只要内存/所有权原语
;;   (require vulkan/safe)     ; 自动模式（裸命令 + 所有权 + 错误策略 + 包装）
;;
;; 注意：本入口不定义 check-vk-result（错误策略属于 vulkan/safe）。
;; ============================================================

(require "bindings.rkt"
         "memory.rkt")

(provide (all-from-out "bindings.rkt")
         (all-from-out "memory.rkt"))
