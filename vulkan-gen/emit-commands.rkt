#lang racket/base
;; commands.rkt 的形式生成：`vk-func` 记录 -> (define-vk ...)。
;;
;; 命令的签名/分派/arity 已在解析期归一成 vk-func，本模块不再接触 registry。
;; 运行期事实数据（generated/facts.rkt）在 emit-api.rkt。
;; ============================================================

(require "model.rkt")

(provide command-forms)

(define (function-form f)
  `(define-vk ,(vk-func-name f) ,(vk-func-level f) ,(vk-func-arity f) ,(vk-func-fun f)))

(define (command-forms funcs)
  (map function-form funcs))
