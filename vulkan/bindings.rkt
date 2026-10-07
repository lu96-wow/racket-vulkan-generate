#lang racket/base
;; ============================================================
;; 原始绑定（raw）：base（类型/常量/分派）+ commands（原始命令）。
;; 命令直接返回 VkResult；不含内存所有权、不含错误抛出。
;;
;;   (require vulkan/bindings)  ; 类型/常量/原始命令/分派
;;   (require vulkan/raw)       ; 同上（语义别名）
;;   (require vulkan/safe)      ; 组合层糖（不 re-export 原始命令）
;;   (require vulkan)           ; facade：糖 + 类型/常量/原子 + raw: 前缀裸命令
;; ============================================================

(require "base.rkt"
         "commands.rkt")

(provide (all-from-out "base.rkt")
         (all-from-out "commands.rkt"))
