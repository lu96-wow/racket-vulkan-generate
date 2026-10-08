#lang racket/base
;; ============================================================
;; generated/pnext.inc：sType 值与 pNext setter 表。
;;
;; 每个可扩展 struct 都有 `sType`（首个成员，值来自 registry 的
;; `values="VK_STRUCTURE_TYPE_..."`）和 `pNext`。这里生成两张表：
;;   vk-struct-sType   : struct 名 -> sType 常量值
;;   vk-pNext-setters  : sType 值   -> set-VkX-pNext! 过程
;; 供运行时 vk-struct / vk-chain! 使用。
;; ============================================================

(require racket/list
         racket/string
         "xexpr.rkt"
         "vk-registry.rkt"
         "ctype.rkt")

(provide pnext-forms)

(define (sType-value ty)
  (for/first ([m (members-of ty)] #:when (equal? (member-name m) "sType"))
    (attr m 'values #f)))
(define (has-pNext? ty)
  (for/or ([m (members-of ty)]) (equal? (member-name m) "pNext")))

;; struct -> sType 常量名（string），不满足则 #f
(define (pnext-info reg nm)
  (define ty (hash-ref (registry-types-hash reg) nm #f))
  (and ty (eq? (cat-of ty) 'struct)
       (has-pNext? ty)
       (sType-value ty)))

(define (pnext-forms reg sorted-types)
  (define pairs
    (for/list ([nm (in-list sorted-types)] #:when (pnext-info reg nm))
      (cons nm (string->symbol (pnext-info reg nm)))))
  (list
   `(define vk-struct-sType
      (hash ,@(append* (for/list ([p (in-list pairs)]) (list `',(car p) (cdr p))))))
   `(define vk-pNext-setters
      (hash ,@(append* (for/list ([p (in-list pairs)])
                         (list (cdr p)
                               (string->symbol (format "set-~a-pNext!" (car p))))))))))
