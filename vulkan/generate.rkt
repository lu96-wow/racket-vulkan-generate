#lang racket/base
;; ============================================================
;; CLI 入口：vk.xml -> Racket FFI bindings。
;;
;;   racket vulkan/generate.rkt [vk.xml] [out-dir] [feature] [ext1,ext2,...]
;;
;; 省略参数时用 generator/main.rkt 的默认配方（= 仓库提交的绑定）：
;;   registry/vk-1.4.363.xml  generated  VK_VERSION_1_4  common
;; 故 no-arg 即可复现 generated/。
;;   - feature 显式给 "" 无意义；extensions 显式给 "" = 只要 core（不加扩展）。
;;
;; 生成逻辑在 vulkan/generator/main.rkt（可当库调用）；本文件只解析 argv。
;; ============================================================

(require "generator/main.rkt")

(define args (current-command-line-arguments))
;; 未给的位置参数返回 #f，由 generate! 解析为默认（区分“没给”与“显式给空”）。
(define (arg i) (if (> (vector-length args) i) (vector-ref args i) #f))

(generate! #:in-xml     (arg 0)
           #:out-dir    (arg 1)
           #:feature    (arg 2)
           #:extensions (arg 3))
