#lang racket/base
;; ============================================================
;; safe 糖运行期小工具（从 vulkan/safe 移出，独立成模块）。
;;
;; 生成物 `vulkan/generated/safe.rkt` 会 require 本模块；`vulkan/safe` 再
;; re-export，公开 API 不变。
;;
;;   * vk-read-handles：从输出缓冲读回 n 个句柄
;;   * vk-cstring     ：string/#f -> arena 里的 NUL 结尾字节
;; ============================================================

(require ffi/unsafe
         "memory.rkt")

(provide vk-read-handles
         vk-cstring)

;; 从输出缓冲读回 n 个句柄（create/allocate 糖消费输出用）。
(define (vk-read-handles out t n)
  (for/vector ([i (in-range n)]) (ptr-ref out t i)))

;; char* 输入：接受 string 或 #f，转成 arena 里的 NUL 结尾字节
(define (vk-cstring s) (and s (stable-bytes (string->bytes/utf-8 s))))
