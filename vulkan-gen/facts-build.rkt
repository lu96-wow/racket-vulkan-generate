#lang racket/base
;; ============================================================
;; 事实构建：注册表 + wanted 命令 -> vk-command / vk-param 列表。
;;
;; 这是生成器的「解析层」：把 XML 归一化成运行期 IR（vulkan/api-facts）。
;; 不含任何 emit/策略。
;; ============================================================

(require racket/list
         racket/string
         vulkan/api-facts
         "xexpr.rkt"
         "vk-registry.rkt"
         "ctype.rkt"
         "model.rkt")

(provide skip-commands
         params-of pointer-param? command-level command-result?
         command-type-names dispatch-param?
         api-command api-commands)

(define skip-commands '("vkGetInstanceProcAddr" "vkGetDeviceProcAddr"))

;; 分派层级由 registry 事实推导：dispatchable handle 的 parent 链决定 instance/device。
(define (dispatchable-handle? reg base)
  (define ty (hash-ref (registry-types-hash reg) (string->symbol base) #f))
  (and ty (eq? (cat-of ty) 'handle)
       (regexp-match? #px"VK_DEFINE_HANDLE" (xtext ty))))

(define (handle-level reg base)
  (cond
    [(equal? base "VkInstance") 'instance]
    [(equal? base "VkPhysicalDevice") 'instance]
    [(equal? base "VkDevice") 'device]
    [else
     (define ty (hash-ref (registry-types-hash reg) (string->symbol base) #f))
     (define p (and ty (attr ty 'parent #f)))
     (cond [(or (not p) (equal? p base)) 'device]
           [else (handle-level reg p)])]))

;; 命令分派层级：首参是 dispatchable handle 就按 parent 链定级，否则 global；
;; 首参是**非** dispatchable handle 才可疑（不静默，记 warning）。
(define (command-level reg c [diags #f])
  (define params (params-of c))
  (define first (and (pair? params) (member-base-name (car params))))
  (cond
    [(not first) 'global]
    [(dispatchable-handle? reg first) (handle-level reg first)]
    [(eq? (category-of reg (string->symbol first)) 'handle)
     (diagnose! diags 'warn 'command (command-name c)
                (format "first param ~a is a non-dispatchable handle; level inferred global" first))
     'global]
    [else 'global]))

;; 命令是否返回 VkResult（alias 命令按目标判定）
(define (command-result? reg c)
  (define eff (resolve-command reg c))
  (define proto (find-first-by-tag 'proto eff))
  (and proto (equal? (base-c-type-name (member-type-text proto)) "VkResult")))

;; wanted 类型闭包：命令用到的全部类型名
(define (command-type-names reg c)
  (define eff (resolve-command reg c))
  (define acc (for/list ([p (params-of eff)]) (member-base-name p)))
  (define proto (find-first-by-tag 'proto eff))
  (if proto (cons (member-base-name proto) acc) acc))

;; ------------------------------------------------------------------
(define (dispatch-param? reg p)
  (dispatchable-handle? reg (member-base-name p)))
(define (count-param? p)
  (and (equal? (member-base-name p) "uint32_t")
       (regexp-match? #px"Count$" (member-name p))))
(define (param-const? p)
  (regexp-match? #px"\\bconst\\b" (member-signature p)))

(define (param-kind reg base)
  (case (category-of reg (string->symbol base))
    [(struct) 'struct] [(union) 'union] [(handle) 'handle]
    [(enum) 'enum] [(bitmask) 'bitmask] [(funcpointer) 'funcpointer]
    [(basetype) 'basetype]
    [else (cond [(member base '("void")) 'void]
                [(member base '("char" "signed char" "unsigned char")) 'char]
                [(hash-has-key? base-ctype base) 'scalar]
                [(hash-has-key? platform-ctype base) 'platform]
                [else 'unknown])]))

(define (struct/union-type-name? reg nm)
  (memq (category-of reg (string->symbol nm)) '(struct union)))

(define (dispatch-base-of reg c)
  (define params (params-of (resolve-command reg c)))
  (and (pair? params)
       (let ([b (member-base-name (car params))])
         (and (dispatchable-handle? reg b) b))))

;; vkAllocate* 的 count 字段名（在 info 结构体里，例如 commandBufferCount）
(define (allocate-count-field reg c)
  (define nm (command-name c))
  (and (regexp-match? #px"^vkAllocate" nm)
       (let* ([eff (resolve-command reg c)]
              [params (params-of eff)]
              [info (and (pair? params)
                         (findf (λ (p) (and (pointer-param? p)
                                            (struct/union-type-name? reg (member-base-name p))))
                                params))])
         (and info
              (let ([m (find-count-field reg (member-base-name info))])
                (and m (string->symbol (member-name m))))))))

(define (ctype-has-pointer? ct)
  (cond
    [(eq? ct '_pointer) #t]
    [(and (pair? ct) (eq? (car ct) '_array)) (ctype-has-pointer? (cadr ct))]
    [(and (pair? ct) (eq? (car ct) '_list-struct)) (ormap ctype-has-pointer? (cdr ct))]
    [else #f]))

;; struct/union 是否“可整体浅拷贝”（无指针成员，递归）。
;; 以生成的 ctype 为准（能捕获 funcpointer 成员 / 指针数组这类签名单上看不出的指针），
;; 不再用签名里的 `*` 正则。缓存由调用方持有（api-commands 内建一个），无模块级全局。
(define (flat-struct? reg cache base)
  (define key (list base (eq-hash-code (registry-types-hash reg))))
  (hash-ref cache key
            (λ ()
              (define ty (hash-ref (registry-types-hash reg) (string->symbol base) #f))
              (define res
                (and ty
                     (for/and ([m (members-of ty)])
                       (cond [(bitfield-member? m) #t]
                             [(ctype-has-pointer? (member-ctype-expr reg m)) #f]
                             [else
                              (define b (member-base-name m))
                              (or (not (hash-has-key? (registry-types-hash reg) (string->symbol b)))
                                  (not (struct/union-type-name? reg b))
                                  (flat-struct? reg cache b))]))))
              (hash-set! cache key res)
              res)))

(define (api-param reg cache p [diags #f])
  (define base (member-base-name p))
  (define ptr? (pointer-param? p))
  (define const? (param-const? p))
  (define kind (param-kind reg base))
  (define flat? (if (memq kind '(struct union)) (flat-struct? reg cache base) #t))
  (when (eq? kind 'unknown)
    (diagnose! diags 'warn 'command (member-name p)
               (format "param base type not classified: ~a" base)))
  (vk-param (string->symbol (member-name p)) base (ctype-of-type-name reg base diags)
            ptr? const? (count-param? p) kind
            (and ptr? (not const?)) flat?))

(define (api-command reg cache c [diags #f])
  (define eff (resolve-command reg c))
  (vk-command (string->symbol (command-name c))
              (command-level reg eff diags)
              (command-result? reg c)
              (dispatch-base-of reg c)
              (map (λ (p) (api-param reg cache p diags)) (params-of eff))
              (allocate-count-field reg c)))

(define (api-commands reg wanted-cmds [diags #f])
  (define cache (make-hash))
  (filter values
          (for/list ([nm wanted-cmds]
                     #:when (and nm (not (member nm skip-commands))))
            (define c (hash-ref (registry-commands-hash reg) (string->symbol nm) #f))
            (cond
              [c (api-command reg cache c diags)]
              [else (diagnose! diags 'warn 'command nm "command not found in registry; skipped")
                    #f]))))
