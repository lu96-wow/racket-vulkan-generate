#lang racket/base
;; ============================================================
;; pNext / sType 辅助（组合层糖）。
;;
;;   * `(vk-struct make-VkBufferCreateInfo flags size usage sharingMode)`
;;     自动填 `sType`（由 struct 名查 `vk-struct-sType`）、`pNext` 先置 `#f`，
;;     并用 `vk-new` 登记到当前 arena。
;;   * `(vk-chain! a b c)` 把 a→b→c 串成 pNext 链；每个节点按自身 `sType`
;;     查 `vk-pNext-setters` 得到 setter，并把节点登记到当前 arena（B3）。
;;
;; 这两个辅助只覆盖“干净形状”：struct 首成员是 `sType`、次成员是 `pNext`，
;; 其余参数按生成构造器顺序给出。裸结构体能力始终保留。
;; ============================================================

(require (for-syntax racket/base)
         (for-syntax racket/string)
         ffi/unsafe
         "base.rkt"
         "memory.rkt")

(provide vk-chain!
         vk-struct)

;; 串链：a -> b -> c；返回链头 a。
(define (vk-chain! parent . rest)
  (vk-arena-keep-current! parent)
  (define (set-pnext! p c)
    (define sType (ptr-ref p _int32))            ; sType 恒为首个 int32 成员
    (define setter
      (hash-ref vk-pNext-setters sType
                (λ () (error 'vk-chain! "no pNext setter for sType ~a" sType))))
    (setter p c)
    (vk-arena-keep-current! c))
  (let loop ([p parent] [cs rest])
    (cond
      [(null? cs) parent]
      [else (set-pnext! p (car cs)) (loop (car cs) (cdr cs))])))

;; 从构造器标识符推导 struct 名（make-VkX -> VkX），自动填 sType。
(begin-for-syntax
  (define (ctor->struct-name sym)
    (define s (symbol->string sym))
    (string->symbol (if (string-prefix? s "make-") (substring s 5) s))))

(define-syntax (vk-struct stx)
  (syntax-case stx ()
    [(_ ctor arg ...)
     (identifier? #'ctor)
     (let* ([name (ctor->struct-name (syntax-e #'ctor))]
            [stype `(hash-ref vk-struct-sType ',name
                              (λ () (error 'vk-struct "no sType for ~a" ',name)))])
       #`(vk-new ctor #,stype #f arg ...))]))
