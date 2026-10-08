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
         "ctype.rkt")

(provide skip-commands
         params-of pointer-param? command-level command-result?
         command-type-names dispatch-param?
         api-command api-commands)

(define skip-commands '("vkGetInstanceProcAddr" "vkGetDeviceProcAddr"))

(define (command-level reg c)
  (define params (params-of c))
  (define first (and (pair? params) (member-base-name (car params))))
  (case (and first (string->symbol first))
    [(VkInstance VkPhysicalDevice) 'instance]
    [(VkDevice VkQueue VkCommandBuffer VkExternalComputeQueueNV) 'device]
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
(define (dispatch-param? p)
  (and (member (member-base-name p)
               '("VkInstance" "VkDevice" "VkPhysicalDevice" "VkQueue" "VkCommandBuffer"
                 "VkExternalComputeQueueNV"))
       #t))
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
  (and (pair? params) (dispatch-param? (car params)) (member-base-name (car params))))

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

;; struct/union 是否不含指针成员（递归）。缓存由调用方持有（api-commands
;; 内建一个），不再有模块级全局；键含 registry（types-hash）的 eq-hash-code。
(define (flat-struct? reg cache base)
  (define key (list base (eq-hash-code (registry-types-hash reg))))
  (hash-ref cache key
            (λ ()
              (define ty (hash-ref (registry-types-hash reg) (string->symbol base) #f))
              (define res
                (and ty
                     (for/and ([m (members-of ty)])
                       (cond [(pointer-member? m) #f]
                             [(bitfield-member? m) #t]
                             [else
                              (define b (member-base-name m))
                              (or (not (hash-has-key? (registry-types-hash reg) (string->symbol b)))
                                  (not (struct/union-type-name? reg b))
                                  (flat-struct? reg cache b))]))))
              (hash-set! cache key res)
              res)))

(define (api-param reg cache p)
  (define base (member-base-name p))
  (define ptr? (pointer-param? p))
  (define const? (param-const? p))
  (define kind (param-kind reg base))
  (define flat? (if (memq kind '(struct union)) (flat-struct? reg cache base) #t))
  (vk-param (string->symbol (member-name p)) base (ctype-of-type-name reg base)
            ptr? const? (count-param? p) kind
            (and ptr? (not const?)) flat?))

(define (api-command reg cache c)
  (define eff (resolve-command reg c))
  (vk-command (string->symbol (command-name c))
              (command-level reg eff)
              (command-result? reg c)
              (dispatch-base-of reg c)
              (map (λ (p) (api-param reg cache p)) (params-of eff))
              (allocate-count-field reg c)))

(define (api-commands reg wanted-cmds)
  (define cache (make-hash))
  (filter values
          (for/list ([nm wanted-cmds]
                     #:when (and nm (not (member nm skip-commands))))
            (define c (hash-ref (registry-commands-hash reg) (string->symbol nm) #f))
            (and c (api-command reg cache c)))))
