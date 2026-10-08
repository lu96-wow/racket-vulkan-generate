#lang racket/base
;; ============================================================
;; types.rkt 的形式生成：`vk-type` 记录 -> (define ...)。
;;
;; 解析期已把类别与生成所需 slot（ctype / layout / union-ctypes / func-*）
;; 算好，本模块不再接触 registry 或 ctype 映射。
;; ============================================================

(require racket/list
         "model.rkt")

(provide type-forms type-form)

(define (sym nm) (string->symbol (format "_~a" nm)))

;; 位域访问器：掩码 + 移位；setter 读改写。reserved 只占位，不生成访问器。
(define (bitgroup-accessors nm g)
  (define storage (vk-bitgroup-storage g))
  (define reader (string->symbol (format "~a-~a" nm storage)))
  (define writer (string->symbol (format "set-~a-~a!" nm storage)))
  (append*
   (for/list ([b (in-list (vk-bitgroup-bits g))]
              #:when (not (equal? (car b) "reserved")))
     (define mname (car b))
     (define off (cadr b))
     (define width (caddr b))
     (define mask (sub1 (arithmetic-shift 1 width)))
     (define get-name (string->symbol (format "~a-~a" nm mname)))
     (define set-name (string->symbol (format "set-~a-~a!" nm mname)))
     (list
      `(define (,get-name p)
         (bitwise-and (arithmetic-shift (,reader p) ,(- off)) ,mask))
      `(define (,set-name p v)
         (define u (,reader p))
         (,writer p (bitwise-ior
                     (bitwise-and u (bitwise-not (arithmetic-shift ,mask ,off)))
                     (arithmetic-shift (bitwise-and v ,mask) ,off))))))))

(define (struct-form t)
  (define nm (vk-type-name t))
  (define layout (vk-type-layout t))
  (define fields
    (for/list ([f layout])
      (cond [(vk-cfield? f) (list (vk-cfield-name f) (vk-cfield-ctype f))]
            [else (list (vk-bitgroup-storage f) (vk-bitgroup-base-ctype f))])))
  (define fields* (if (null? fields) (list (list '_dummy '_uint8)) fields))
  (define accessors (append-map (λ (f) (if (vk-bitgroup? f) (bitgroup-accessors nm f) '())) layout))
  (cons
   `(define-cstruct ,(sym nm) ,fields*
      #:malloc-mode 'zeroed-atomic-interior)
   accessors))

(define (type-form t)
  (cond
    [(vk-type-alias t) (list `(define ,(sym (vk-type-name t)) ,(sym (vk-type-alias t))))]
    [else
     (case (vk-type-category t)
       [(handle basetype bitmask enum)
        (list `(define ,(sym (vk-type-name t)) ,(vk-type-ctype t)))]
       [(struct) (struct-form t)]
       [(union) (list `(define ,(sym (vk-type-name t)) (_union ,@(vk-type-union-ctypes t))))]
       [(funcpointer)
        (list `(define ,(sym (vk-type-name t))
                 (_cprocedure (list ,@(vk-type-func-args t)) ,(vk-type-func-ret t))))]
       [else '()])]))

(define (type-forms types)
  (append* (for/list ([t (in-list types)]) (type-form t))))
