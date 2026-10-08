#lang racket/base
;; ============================================================
;; generated/pnext.rkt：sType 值与 pNext setter 表。
;;
;; 只消费 `vk-type`（struct 的 sType 已在解析期算好），不再回看 registry。
;;   vk-struct-sType   : struct 名 -> sType 常量值
;;   vk-pNext-setters  : sType 值   -> set-VkX-pNext! 过程
;; ============================================================

(require racket/list
         "model.rkt")

(provide pnext-forms)

(define (pnext-forms types)
  (define pairs
    (for/list ([t (in-list types)] #:when (vk-type-sType t))
      (cons (vk-type-name t) (vk-type-sType t))))
  (list
   `(define vk-struct-sType
      (hash ,@(append* (for/list ([p (in-list pairs)]) (list `',(car p) (cdr p))))))
   `(define vk-pNext-setters
      (hash ,@(append* (for/list ([p (in-list pairs)])
                         (list (cdr p)
                               (string->symbol (format "set-~a-pNext!" (car p))))))))))
