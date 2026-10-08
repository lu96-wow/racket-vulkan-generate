#lang racket/base
;; ============================================================
;; types.inc 的形式生成：把一个拓扑排序后的类型名列表变成 (define ...)。
;; 只依赖注册表事实 + ctype 映射。
;; ============================================================

(require racket/list
         "xexpr.rkt"
         "vk-registry.rkt"
         "ctype.rkt")

(provide type-forms type-forms-of)

(define (handle->form nm)
  `(define ,(string->symbol (format "_~a" nm))
     (_cpointer/null (quote ,(string->symbol (format "~a_T" nm))))))
(define (basetype->form nm)
  `(define ,(string->symbol (format "_~a" nm))
     ,(hash-ref basetype-map (symbol->string nm) '_pointer)))
(define (bitmask->form reg nm ty)
  (define a (attr ty 'alias #f))
  (if a `(define ,(string->symbol (format "_~a" nm)) ,(string->symbol (format "_~a" a)))
      `(define ,(string->symbol (format "_~a" nm)) ,(if (bitmask-64? reg ty) '_uint64 '_uint32))))
(define (enum->form nm ty)
  (define a (attr ty 'alias #f))
  (if a `(define ,(string->symbol (format "_~a" nm)) ,(string->symbol (format "_~a" a)))
      `(define ,(string->symbol (format "_~a" nm)) _int32)))
(define (funcpointer->form reg nm ty)
  (define proto (find-first-by-tag 'proto ty))
  (define ret (if proto (ctype-of-type-name reg (member-base-name proto)) '_void))
  (define args (map (λ (p) (param-ctype reg p)) (params-of ty)))
  `(define ,(string->symbol (format "_~a" nm))
     (_cprocedure (list ,@args) ,ret)))
(define (struct->form reg nm ty)
  (define layout (struct-layout reg ty))
  (define fields
    (for/list ([f layout])
      (cond [(vk-cfield? f) (list (vk-cfield-name f) (vk-cfield-ctype f))]
            [else (list (vk-bitgroup-storage f) (vk-bitgroup-base-ctype f))])))
  (define fields* (if (null? fields) (list (list '_dummy '_uint8)) fields))
  (define accessors (append-map (λ (f) (if (vk-bitgroup? f) (bitgroup-accessors nm f) '())) layout))
  (cons
   `(define-cstruct ,(string->symbol (format "_~a" nm)) ,fields*
      #:malloc-mode 'zeroed-atomic-interior)
   accessors))

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
(define (union->form reg nm ty)
  (define members (filter member-name (members-of ty)))
  (define ctypes
    (for/list ([m members])
      (define base (member-base-name m))
      (cond
        [(pointer-member? m) '_pointer]
        [(array-member? m)
         (define dims (array-dims m))
         (cond
           [(null? dims) (ctype-of-type-name reg base)]
           [(andmap integer? dims)
            (if (= 1 (length dims))
                `(_list-struct ,@(build-list (car dims) (λ _ (ctype-of-type-name reg base))))
                `(_array ,(ctype-of-type-name reg base) ,@dims))]
           [else `(_array ,(ctype-of-type-name reg base) ,@dims)])]
        [else (ctype-of-type-name reg base)])))
  (define ctypes* (if (null? ctypes) (list '_uint8) ctypes))
  `(define ,(string->symbol (format "_~a" nm)) (_union ,@ctypes*)))
(define (alias->form nm target)
  `(define ,(string->symbol (format "_~a" nm)) ,(string->symbol (format "_~a" target))))

(define (type-form reg nm)
  (define ty (hash-ref (registry-types-hash reg) nm))
  ;; 带 alias 的类型统一生成 ctype 别名，避免 struct alias 被当成空结构体
  (if (attr ty 'alias #f)
      (list (alias->form nm (attr ty 'alias)))
      (case (cat-of ty)
        [(handle) (list (handle->form nm))]
        [(basetype) (list (basetype->form nm))]
        [(bitmask) (list (bitmask->form reg nm ty))]
        [(enum) (list (enum->form nm ty))]
        [(struct) (struct->form reg nm ty)]
        [(union) (list (union->form reg nm ty))]
        [(funcpointer) (list (funcpointer->form reg nm ty))]
        [else '()])))

(define (type-forms reg sorted-types)
  (append* (for/list ([nm (in-list sorted-types)]) (type-form reg nm))))

;; 只取指定类别的类型形式（生成层按 枚举/结构体 等分类时用）。
;; 注意 types.inc 必须保持依赖顺序，所以整表仍走 type-forms。
(define (type-forms-of reg sorted-types cats)
  (append* (for/list ([nm (in-list sorted-types)]
                      #:when (memq (type-category reg nm) cats))
             (type-form reg nm))))
