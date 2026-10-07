#lang racket/base
;; ============================================================
;; 已弃用别名：请改用 vulkan/manual。
;;
;; 原名的 “unsafe” 不反映功能：本入口并不比 bindings 更 unsafe，
;; 它只是 = 裸绑定（bindings）+ 内存原语（memory）。
;; ============================================================

(require "manual.rkt")

(provide (all-from-out "manual.rkt"))
