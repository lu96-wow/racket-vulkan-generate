#lang racket/base
;; ============================================================
;; 解析层：`vk.xml` + 目标 feature/扩展 -> `vk-model` + 诊断。
;;
;; 目标：产出**自足、归一、可审计**的事实模型，不含 Racket 形式/策略。
;; 分类：预定义常量 / 枚举 / 结构体 / 其他类型 / 函数；降级与丢弃一律记诊断。
;; 生成层只看 vk-model，不再回看 registry。
;; ============================================================

(require racket/list
         racket/string
         "xexpr.rkt"
         "vk-registry.rkt"
         "extension-select.rkt"
         "ctype.rkt"
         (except-in "facts-build.rkt" params-of pointer-param?)
         "constants.rkt"
         "model.rkt")

(provide parse-model)

(define (sym<? a b) (string<? (symbol->string a) (symbol->string b)))

(define (topo-sort nodes deps-fn)
  (define node-set (make-hasheqv))
  (for ([n nodes]) (hash-set! node-set n #t))
  (define indeg (make-hasheqv))
  (define adj (make-hasheqv))
  (for ([n nodes]) (hash-set! indeg n 0) (hash-set! adj n '()))
  (for ([n nodes])
    (for ([d (deps-fn n)])
      (when (and (hash-ref node-set d #f) (not (eq? d n)))
        (hash-set! indeg n (add1 (hash-ref indeg n 0)))
        (hash-set! adj d (cons n (hash-ref adj d '()))))))
  (let loop ([q (filter (λ (n) (zero? (hash-ref indeg n))) nodes)] [out '()])
    (cond [(null? q) (append (reverse out) (filter (λ (n) (not (member n out))) nodes))]
          [else
           (define n (car q))
           (define newq (cdr q))
           (define nq (for/fold ([qq newq]) ([m (hash-ref adj n)])
                        (hash-set! indeg m (sub1 (hash-ref indeg m)))
                        (if (zero? (hash-ref indeg m)) (append qq (list m)) qq)))
           (loop nq (cons n out))])))

;; wanted 类型闭包：wanted-types ∪ 命令引用类型，再反复吸收 by-value 依赖。
(define (wanted-type-closure reg wanted-types wanted-cmds)
  (define (known? t) (hash-has-key? (registry-types-hash reg) (string->symbol t)))
  (define wanted (make-hasheqv))
  (for ([t wanted-types]) (when t (hash-set! wanted (string->symbol t) #t)))
  (for ([c wanted-cmds])
    (define cmd (hash-ref (registry-commands-hash reg) (string->symbol c) #f))
    (when cmd
      (for ([t (command-type-names reg cmd)])
        (when (known? t) (hash-set! wanted (string->symbol t) #t)))))
  (let loop ()
    (define before (hash-count wanted))
    (for ([nm (hash-keys wanted)])
      (for ([dep (type-dependencies reg nm)])
        (when (hash-has-key? (registry-types-hash reg) dep) (hash-set! wanted dep #t))))
    (when (> (hash-count wanted) before) (loop)))
  (sort (filter (λ (n) (hash-has-key? (registry-types-hash reg) n)) (hash-keys wanted)) sym<?))

;; ---------------- 类型事实 ----------------

;; struct 可扩展（有 pNext+sType）时的 sType 常量名
(define (pnext-sType ty)
  (and (eq? (cat-of ty) 'struct)
       (for/or ([m (members-of ty)]) (equal? (member-name m) "pNext"))
       (for/first ([m (members-of ty)] #:when (equal? (member-name m) "sType"))
         (define v (attr m 'values #f))
         (and v (string->symbol v)))))

;; 前提交叉检查：有 pNext 的 struct 必须有 sType，且 sType 的 values 必须以
;; VK_STRUCTURE_TYPE_ 开头（否则 pnext 表要么缺项、要么值错）。
(define (audit-pnext! reg types diags)
  (for ([t (in-list types)]
        #:when (and (eq? (vk-type-category t) 'struct) (not (vk-type-alias t))))
    (define ty (hash-ref (registry-types-hash reg) (vk-type-name t) #f))
    (define members (members-of ty))
    (when (for/or ([m members]) (equal? (member-name m) "pNext"))
      (define st (for/first ([m members] #:when (equal? (member-name m) "sType")) m))
      (cond
        [(not st) (diagnose! diags 'warn 'type (vk-type-name t) "has pNext but no sType member")]
        [else
         (define v (attr st 'values #f))
         ;; 无 values 的 sType 常见于基类（VkBaseIn/OutStructure），不是错误；
         ;; 只查“有 values 但前缀不对”。
         (when (and v (not (regexp-match? #px"^VK_STRUCTURE_TYPE_" v)))
           (diagnose! diags 'warn 'type (vk-type-name t)
                      (format "sType values ~a does not start with VK_STRUCTURE_TYPE_" v)))]))))

(define (union-member-ctypes reg ty diags)
  (define members (filter member-name (members-of ty)))
  (define cts
    (for/list ([m members])
      (define base (member-base-name m))
      (cond
        [(pointer-member? m) '_pointer]
        [(array-member? m)
         (define dims (array-dims m))
         (cond
           [(null? dims) (ctype-of-type-name reg base diags)]
           [(andmap integer? dims)
            (if (= 1 (length dims))
                `(_list-struct ,@(build-list (car dims) (λ _ (ctype-of-type-name reg base diags))))
                `(_array ,(ctype-of-type-name reg base diags) ,@dims))]
           [else `(_array ,(ctype-of-type-name reg base diags) ,@dims)])]
        [else (ctype-of-type-name reg base diags)])))
  (if (null? cts) (list '_uint8) cts))

(define (parse-type reg nm diags)
  (define ty (hash-ref (registry-types-hash reg) nm))
  (define raw (cat-of ty))
  (define alias (attr ty 'alias #f))
  (define (d! reason) (diagnose! diags 'warn 'type nm reason))
  (cond
    ;; alias：只记目标，不展开成员
    [alias (vk-type nm raw (string->symbol alias) #f #f #f #f #f #f)]
    [(eq? raw 'handle) (vk-type nm 'handle #f
                                 `(_cpointer/null (quote ,(string->symbol (format "~a_T" nm))))
                                 #f #f #f #f #f)]
    [(eq? raw 'basetype)
     (define b (or (hash-ref basetype-map (symbol->string nm) #f)
                   (hash-ref platform-ctype (symbol->string nm) #f)))
     (unless b (d! "basetype not in basetype-map/platform-ctype; using _pointer"))
     (vk-type nm 'basetype #f (or b '_pointer) #f #f #f #f #f)]
    [(eq? raw 'bitmask)
     ;; 宽度有两个来源（类型文本 VkFlags64 / bitvalues bitwidth），矛盾即可疑
     (define text64? (and (regexp-match? #px"VkFlags64" (xtext ty)) #t))
     (define bv (attr ty 'bitvalues #f))
     (define bv64?
       (and bv (let ([blk (findf (λ (b) (equal? (attr b 'name) bv))
                                  (registry-enums-blocks reg))])
                 (and blk (equal? (attr blk 'bitwidth) "64")))))
     (when (and bv (not (eq? text64? (and bv64? #t))))
       (d! (format "bitmask width sources disagree: VkFlags64=~a, bitvalues ~a bitwidth=~a"
                   text64? bv (if bv64? 64 32))))
     (vk-type nm 'bitmask #f (if (bitmask-64? reg ty) '_uint64 '_uint32) #f #f #f #f #f)]
    [(eq? raw 'enum) (vk-type nm 'enum #f '_int32 #f #f #f #f #f)]
    [(eq? raw 'struct) (vk-type nm 'struct #f #f (struct-layout reg ty diags) #f #f #f (pnext-sType ty))]
    [(eq? raw 'union) (vk-type nm 'union #f #f #f (union-member-ctypes reg ty diags) #f #f #f)]
    [(eq? raw 'funcpointer)
     (define proto (find-first-by-tag 'proto ty))
     (define ret (if proto (ctype-of-type-name reg (member-base-name proto) diags) '_void))
     (define args (map (λ (p) (param-ctype reg p diags)) (params-of ty)))
     (vk-type nm 'funcpointer #f #f #f #f ret args #f)]
    [else (diagnose! diags 'info 'type nm (format "not a bindable type category (~a); skipped" raw)) #f]))

;; ---------------- 命令绑定事实 ----------------

(define (function-fun reg eff diags)
  (define proto (find-first-by-tag 'proto eff))
  (define ret-base (base-c-type-name (member-type-text proto)))
  (define params (params-of eff))
  (define types (map (λ (p) (param-ctype reg p diags)) params))
  (if (equal? ret-base "VkResult")
      `(_fun ,@types -> _VkResult)
      `(_fun ,@types -> ,(ctype-of-type-name reg ret-base diags))))

(define (parse-functions reg wanted-cmds diags)
  (filter values
          (for/list ([nm (in-list wanted-cmds)]
                     #:when (and nm (not (member nm skip-commands))))
            (define c (hash-ref (registry-commands-hash reg) (string->symbol nm) #f))
            (cond
              [c (define eff (resolve-command reg c))
                 (vk-func (string->symbol (command-name c))
                          (command-level reg eff diags)
                          (length (params-of eff))
                          (function-fun reg eff diags))]
              [else #f]))))

;; ---------------- 模型 ----------------

(define (parse-model #:registry reg #:feature feature #:extensions extensions)
  (define diags (make-diagnostics))
  (define closure (feature-closure reg feature))
  (define requested-extensions (resolve-extensions reg extensions))
  (define ext-closure (extension-closure reg requested-extensions))
  (define-values (feat-cmds feat-types) (collect-requires reg closure))
  (define-values (ext-cmds ext-types ext-enums) (collect-extension-requires reg ext-closure))
  (define wanted-cmds (append feat-cmds ext-cmds))
  (define wanted-types (append feat-types ext-types))

  (define wanted-list (wanted-type-closure reg wanted-types wanted-cmds))
  (define type-names (topo-sort wanted-list (λ (nm) (type-dependencies reg nm))))
  (define types (filter values (map (λ (nm) (parse-type reg nm diags)) type-names)))
  (audit-pnext! reg types diags)

  ;; 交叉检查：两个 struct 不得映射到同一个 sType（同值意味着可链接语义冲突）
  (let ([seen (make-hash)])
    (for ([t (in-list types)] #:when (vk-type-sType t))
      (define st (vk-type-sType t))
      (when (hash-has-key? seen st)
        (diagnose! diags 'warn 'type (vk-type-name t)
                   (format "sType ~a also used by ~a" st (hash-ref seen st))))
      (hash-set! seen st (vk-type-name t))))

  (define (effective t) (if (vk-type-alias t) 'alias (vk-type-category t)))
  (define (category-in? t cats) (memq (effective t) cats))
  (define enums (filter (λ (t) (category-in? t '(enum))) types))
  (define structs (filter (λ (t) (category-in? t '(struct union))) types))
  (define other-types
    (filter (λ (t) (category-in? t '(handle bitmask basetype funcpointer alias))) types))

  (define constants (parsed-constants reg closure ext-enums diags))
  (define commands (api-commands reg wanted-cmds diags))
  (define functions (parse-functions reg wanted-cmds diags))

  (values
   (vk-model (registry-version reg)
             feature extensions closure
             requested-extensions ext-closure feat-types
             wanted-cmds wanted-list
             constants types functions commands
             enums structs other-types)
   (diagnostics-list diags)))
