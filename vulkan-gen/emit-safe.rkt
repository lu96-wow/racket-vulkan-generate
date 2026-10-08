#lang racket/base
;; ============================================================
;; safe.rkt 的逐形状 emitter：只吃 vk-plan，返回 (define ...) 形式列表。
;;
;; 每个 shape 一个函数，互不引用；共享小工具（ctype/checked-call）独立。
;; 组合由 emit-safe-forms 完成。
;; ============================================================

(require racket/list
         vulkan/api-facts
         "classify.rkt")

(provide emit-safe-forms)

(define (pname p) (vk-param-name p))
(define (raw-name nm) (string->symbol (format "raw:~a" nm)))
(define (cmd-name plan) (vk-command-name (vk-plan-cmd plan)))

;; 原始调用表达式（VkResult 命令包 check-vk-result）
(define (call-expr plan args)
  (define nm (cmd-name plan))
  (define call `(,(raw-name nm) ,@args))
  (if (vk-plan-result? plan)
      `(check-vk-result ,call (quote ,nm))
      call))

;; 按原始参数顺序，把 slot 替换成给定表达式（默认：info/o/n；可覆盖）
(define (char-in? p)
  (and (eq? (vk-param-kind p) 'char) (vk-param-pointer? p) (not (vk-param-output? p))))
(define (call-args** plan #:dispatch [d-expr #f] #:in [in-expr 'info]
                     #:out [out-expr 'o] #:count [count-expr 'n])
  (define d (vk-plan-dispatch plan))
  (define in (vk-plan-input plan))
  (define out (vk-plan-output plan))
  (define cnt (vk-plan-count plan))
  (for/list ([p (in-list (vk-command-params (vk-plan-cmd plan)))])
    (cond [(and d (eq? p d)) (or d-expr (pname d))]
          [(and in (eq? p in)) (or in-expr 'info)]
          [(and out (eq? p out)) (or out-expr #f)]
          [(and cnt (eq? p cnt)) (or count-expr 'n)]
          [(char-in? p) `(vk-cstring ,(pname p))]
          [else (pname p)])))
(define (call-args plan) (call-args** plan))

(define (builder-args plan)
  (define d (vk-plan-dispatch plan))
  (if d
      (list* (pname d) 'make-info (map pname (vk-plan-passthrough plan)))
      (list* 'make-info (map pname (vk-plan-passthrough plan)))))

(define (all-args plan) (map pname (vk-command-params (vk-plan-cmd plan))))

;; 糖的形参：dispatch + 透传参数（输出/输入/计数 slot 不进形参）
(define (wrapper-args plan)
  (define d (vk-plan-dispatch plan))
  (append (if d (list (pname d)) '()) (map pname (vk-plan-passthrough plan))))

;; ---------------- create / allocate ----------------

(define (emit-make-handles plan)
  (define wname (cmd-name plan))
  (define info-ctype (vk-param-ctype (vk-plan-input plan)))
  (define out-ctype (vk-param-ctype (vk-plan-output plan)))
  `(define (,wname ,@(builder-args plan))
     (define a (make-vk-arena))
     (define-values (r out n)
       (parameterize ([current-vk-arena a])
         (define infos (make-info))
         (define n (vector-length infos))
         (define info (vk-struct-array ,info-ctype (vector->list infos)))
         (define o (vk-malloc ,out-ctype n))
         (values ,(call-expr plan (call-args plan)) o n)))
     (define hs (vk-read-handles out ,out-ctype n))
     (for ([h hs]) (vk-handle-arena-set! h a))
     ,(if (vk-plan-result? plan) '(values r hs) 'hs)))

(define (emit-make-handles-info-count plan)
  (define wname (cmd-name plan))
  (define info-base (vk-param-base (vk-plan-input plan)))
  (define out-ctype (vk-param-ctype (vk-plan-output plan)))
  (define accessor (string->symbol (format "~a-~a" info-base (vk-plan-count-info-field plan))))
  `(define (,wname ,@(builder-args plan))
     (define a (make-vk-arena))
     (define-values (r out n)
       (parameterize ([current-vk-arena a])
         (define info (make-info))
         (define n (,accessor info))
         (define o (vk-malloc ,out-ctype n))
         (values ,(call-expr plan (call-args plan)) o n)))
     (define hs (vk-read-handles out ,out-ctype n))
     (for ([h hs]) (vk-handle-arena-set! h a))
     ,(if (vk-plan-result? plan) '(values r hs) 'hs)))

(define (emit-make-handle plan)
  (define wname (cmd-name plan))
  (define out-ctype (vk-param-ctype (vk-plan-output plan)))
  `(define (,wname ,@(builder-args plan))
     (define a (make-vk-arena))
     (define-values (r out)
       (parameterize ([current-vk-arena a])
         (define info (make-info))
         (define o (vk-malloc ,out-ctype))
         (values ,(call-expr plan (call-args plan)) o)))
     (define h (ptr-ref out ,out-ctype))
     (vk-handle-arena-set! h a)
     ,(if (vk-plan-result? plan) '(values r h) 'h)))

;; ---------------- destroy / free ----------------

(define (emit-destroy-handle plan)
  (define wname (cmd-name plan))
  (define h (pname (vk-plan-output plan)))
  `(define (,wname ,@(all-args plan))
     (vk-handle-arena-remove! ,h)
     ,(call-expr plan (all-args plan))))

(define (emit-destroy-handles plan)
  (define wname (cmd-name plan))
  (define cnt (pname (vk-plan-count plan)))
  (define arr (pname (vk-plan-output plan)))
  (define elem-ctype (vk-param-ctype (vk-plan-output plan)))
  `(define (,wname ,@(all-args plan))
     (for ([i (in-range ,cnt)])
       (vk-handle-arena-remove! (ptr-ref ,arr ,elem-ctype i)))
     ,(call-expr plan (all-args plan))))

;; ---------------- output ----------------

(define (emit-out-single plan)
  (define wname (cmd-name plan))
  (define out-ctype (vk-param-ctype (vk-plan-output plan)))
  `(define (,wname ,@(wrapper-args plan))
     (define a (make-vk-arena))
     (define-values (r v)
       (parameterize ([current-vk-arena a])
         (define o (vk-malloc ,out-ctype))
         (values ,(call-expr plan (call-args plan)) (ptr-ref o ,out-ctype))))
     ,(if (vk-plan-result? plan) '(values r v) 'v)))

;; 数组输出（enumerate）：委托给 safe 层的枚举辅助（两遍 + 重试）。
;; VkResult / void 两种命令分别生成对应的收值形式（不再伪造 #f 结果）。
(define (emit-out-array plan)
  (define wname (cmd-name plan))
  (define nm (cmd-name plan))
  (define out-ctype (vk-param-ctype (vk-plan-output plan)))
  (define callback
    `(λ (cnt out) ,(call-expr plan (call-args** plan #:out 'out #:count 'cnt))))
  (if (vk-plan-result? plan)
      `(define (,wname ,@(wrapper-args plan))
         (define a (make-vk-arena))
         (define-values (r v)
           (parameterize ([current-vk-arena a])
             (vk-enumerate-result ',nm ,out-ctype ,callback)))
         (values r v))
      `(define (,wname ,@(wrapper-args plan))
         (define a (make-vk-arena))
         (define v
           (parameterize ([current-vk-arena a])
             (vk-enumerate-void ',nm ,out-ctype ,callback)))
         v)))

;; ---------------- input ----------------

;; 单 struct 输入：整体拷贝进 arena 后调用（要求 flat，无嵌套指针）
(define (emit-in-single plan)
  (define wname (cmd-name plan))
  (define in-ctype (vk-param-ctype (vk-plan-input plan)))
  `(define (,wname ,@(wrapper-args plan) v)
     (define a (make-vk-arena))
     (parameterize ([current-vk-arena a])
       (define info (vk-struct-array ,in-ctype (list v)))
       ,(call-expr plan (call-args** plan #:in 'info)))))

;; 数组输入：接受 vector，count = 长度（要求 flat）
(define (emit-in-array plan)
  (define wname (cmd-name plan))
  (define in-ctype (vk-param-ctype (vk-plan-input plan)))
  `(define (,wname ,@(wrapper-args plan) v)
     (define a (make-vk-arena))
     (parameterize ([current-vk-arena a])
       (define info (vk-struct-array ,in-ctype (vector->list v)))
       ,(call-expr plan (call-args** plan #:in 'info #:count '(vector-length v))))))

;; ---------------- 组合 ----------------

(define emitters
  (hash 'make-handle emit-make-handle
        'make-handles emit-make-handles
        'make-handles-info-count emit-make-handles-info-count
        'destroy-handle emit-destroy-handle
        'destroy-handles emit-destroy-handles
        'out-single emit-out-single
        'out-array emit-out-array
        'in-single emit-in-single
        'in-array emit-in-array))

;; 分组只到“类别”，组内保持命令原序，复现旧产物顺序
(define (shape-category s)
  (cond [(memq s '(make-handle make-handles make-handles-info-count)) 'create]
        [(memq s '(destroy-handle destroy-handles)) 'destroy]
        [(memq s '(out-single out-array)) 'out]
        [(memq s '(in-single in-array)) 'in]
        [else 'skip]))
(define category-order '(create destroy out in skip))

(define (emit-safe-forms commands)
  (define plans (map classify-command commands))
  (define (rank p)
    (for/first ([c (in-list category-order)] [i (in-naturals)]
                #:when (eq? c (shape-category (vk-plan-shape p))))
      i))
  (define ordered (sort plans (λ (a b) (< (rank a) (rank b)))))
  (for/list ([p (in-list ordered)])
    (define emit (hash-ref emitters (vk-plan-shape p) #f))
    (and emit (emit p))))
