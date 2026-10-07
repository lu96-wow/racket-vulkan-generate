#lang racket/base
;; ============================================================
;; 命令分类（纯函数）：vk-command 事实 -> (shape . vk-plan)
;;
;; 固定枚举的 shape，按规则表匹配，先到先得。emit 阶段只吃 plan，
;; 不回看 vk.xml，因此本文件可对全量命令做纯函数测试。
;; ============================================================

(require racket/string
         "../api-facts.rkt")

(provide (struct-out vk-plan)
         classify-command
         shape-symbols)

;; 计划：把所有 slot 一次解析完
;;   dispatch         : 命令的首个 instance/device 句柄（vk-param 或 #f）
;;   passthrough      : 作为调用实参透传的参数（不含 dispatch/output/count/input）
;;   output / input   : 单一输出 / 输入 slot（vk-param 或 #f）
;;   count            : 数组 count 参数（vk-param 或 #f）
;;   count-info-field : 仅 allocate，count 藏在 info 结构体里的字段名（symbol 或 #f）
(struct vk-plan (cmd shape level result? dispatch passthrough
                      output count input count-info-field)
  #:transparent)

(define shape-symbols
  '(make-handle make-handles make-handles-info-count
    destroy-handle destroy-handles
    out-single out-array
    in-single in-array
    skip))

(define (starts? nm pfx) (string-prefix? (symbol->string nm) pfx))
(define (ps c) (vk-command-params c))
(define (ptr? p) (vk-param-pointer? p))
(define (out? p) (vk-param-output? p))
(define (cnt? p) (vk-param-count? p))
(define (handle? p) (eq? (vk-param-kind p) 'handle))
(define (struct? p) (memq (vk-param-kind p) '(struct union)))
(define (copyable? p)
  (memq (vk-param-kind p) '(struct union handle enum bitmask basetype scalar)))

(define (dispatch-param c)
  (define d (vk-command-dispatch c))
  (and d (for/first ([p (in-list (ps c))] #:when (string=? (vk-param-base p) d)) p)))

(define (non-dispatch c)
  (define d (dispatch-param c))
  (for/list ([p (in-list (ps c))] #:unless (eq? p d)) p))

;; 注意：句柄参数是按值传递（无 *），所以不能要求 ptr?；
;; create 的输出句柄是指针（且总是最后一个），destroy 的句柄是按值。
(define (first-handle lst)
  (for/first ([p (in-list lst)] #:when (handle? p)) p))
(define (last-handle lst)
  (for/last ([p (in-list lst)] #:when (handle? p)) p))
(define (struct-ptr lst)
  (for/first ([p (in-list lst)] #:when (and (struct? p) (ptr? p))) p))

(define (mk c shape
          #:dispatch [d #f] #:passthrough [args '()] #:output [output #f]
          #:count [count #f] #:input [input #f] #:count-info-field [cf #f])
  (vk-plan c shape (vk-command-level c) (vk-command-result? c)
           d args output count input cf))

(define (classify-command c)
  (define nm (vk-command-name c))
  (define d (dispatch-param c))
  (define nd (non-dispatch c))
  (define outs (for/list ([p (in-list nd)] #:when (and (out? p) (not (cnt? p)))) p))
  (define counts (for/list ([p (in-list nd)] #:when (cnt? p)) p))
  (define ins (for/list ([p (in-list nd)] #:when (and (ptr? p) (not (out? p)) (not (cnt? p)))) p))
  (define host-ins (for/list ([p (in-list ins)] #:when (not (eq? (vk-param-kind p) 'char))) p))
  (define (args-except . xs)
    (for/list ([p (in-list (ps c))] #:unless (or (eq? p d) (memq p xs))) p))
  (define (one lst) (and (= (length lst) 1) (car lst)))
  (cond
    ;; ---- create ----
    [(starts? nm "vkCreate")
     (define output (last-handle nd))
     (define info (struct-ptr nd))
     (define cn (one counts))
     (cond
       [(and output info)
        (if cn
            (mk c 'make-handles #:dispatch d #:passthrough (args-except info output cn)
                #:output output #:count cn #:input info)
            (mk c 'make-handle #:dispatch d #:passthrough (args-except info output)
                #:output output #:input info))]
       [else (mk c 'skip #:dispatch d)])]
    ;; ---- allocate（count 在 info 结构体里）----
    [(starts? nm "vkAllocate")
     (define output (last-handle nd))
     (define info (struct-ptr nd))
     (define cf (vk-command-count-field c))
     (cond
       [(and output info cf)
        (mk c 'make-handles-info-count #:dispatch d #:passthrough (args-except info output)
            #:output output #:input info #:count-info-field cf)]
       [(and output info)
        (mk c 'make-handle #:dispatch d #:passthrough (args-except info output)
            #:output output #:input info)]
       [else (mk c 'skip #:dispatch d)])]
    ;; ---- destroy ----
    [(starts? nm "vkDestroy")
     (mk c 'destroy-handle #:dispatch d #:passthrough (ps c)
         #:output (or (first-handle nd) d))]
    ;; ---- free ----
    [(starts? nm "vkFree")
     (define cn (one counts))
     (define arr (for/first ([p (in-list nd)] #:when (and (ptr? p) (handle? p) (not (cnt? p)))) p))
     (cond
       [(and cn arr)
        (mk c 'destroy-handles #:dispatch d #:passthrough (ps c)
            #:output arr #:count cn)]
       [else
        (mk c 'destroy-handle #:dispatch d #:passthrough (ps c)
            #:output (or (first-handle nd) d))])]
    ;; ---- 输出：单输出 / 数组输出（enumerate）----
    [else
     (cond
       [(and (= (length outs) 1) (null? host-ins) (copyable? (car outs)))
        (define o (car outs))
        (cond
          [(null? counts)
           (mk c 'out-single #:dispatch d #:passthrough (args-except o) #:output o)]
          [(= (length counts) 1)
           (mk c 'out-array #:dispatch d #:passthrough (args-except o (car counts))
               #:output o #:count (car counts))]
          [else (mk c 'skip #:dispatch d)])]
       [(null? outs)
        (cond
          [(= (length host-ins) 1)
           (define i (car host-ins))
           (cond
             [(and (struct? i) (vk-param-flat? i) (null? counts))
              (mk c 'in-single #:dispatch d #:passthrough (args-except i) #:input i)]
             [(and (= (length counts) 1) (copyable? i) (vk-param-flat? i))
              (mk c 'in-array #:dispatch d #:passthrough (args-except i (car counts))
                  #:input i #:count (car counts))]
             [else (mk c 'skip #:dispatch d)])]
          [else (mk c 'skip #:dispatch d)])]
       [else (mk c 'skip #:dispatch d)])]))
