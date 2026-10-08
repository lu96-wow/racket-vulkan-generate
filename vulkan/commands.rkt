#lang racket/base
;; ============================================================
;; 原始命令（vulkan/commands）：re-export 生成的 commands 模块。
;;
;; 签名与分派都在 vulkan/generated/commands.rkt（真模块）：它 require
;; vulkan/base 拿 `define-vk` 与全部 ctype。本模块只做 re-provide。
;; ============================================================

(require "generated/commands.rkt")

(provide (all-from-out "generated/commands.rkt"))
