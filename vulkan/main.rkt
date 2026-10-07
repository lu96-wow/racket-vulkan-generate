#lang racket/base
;; ============================================================
;; 用户 facade（vulkan）。
;;
;; 组合层与原始绑定的“挑选/重命名”都在这里，靠模块系统而不是命名前缀：
;;   * 糖（vk-create-* 等）与类型/常量/原子：无前缀
;;   * 原始命令：raw: 前缀（来自 commands.rkt，用 prefix-in 导入）
;;
;; (require vulkan)
;;   (vk-create-buffer dev (λ () ...) #f)   ; 糖
;;   (raw:vkCreateBuffer dev info #f out)   ; 裸命令（逃生舱）
;;
;; 只要裸命令： (require vulkan/bindings) 或 (require vulkan/raw)
;; ============================================================

(require "safe.rkt"
         (prefix-in raw: "commands.rkt"))

(provide (all-from-out "safe.rkt")      ; 糖 + base(类型/常量) + memory(原子)
         (all-from-out "commands.rkt")) ; 导入时已带 raw: 前缀，故导出 raw:*
