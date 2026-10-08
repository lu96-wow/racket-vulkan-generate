#lang racket/base
;; ============================================================
;; 解析层：`vk.xml` + 目标 feature/扩展 -> `vk-model`（纯数据领域模型）。
;;
;; 只做「事实归一化」，不产出任何 Racket 形式、不写文件：
;;   * feature/extension 依赖闭包                  -> 命令名 / 类型名
;;   * wanted 类型闭包 + by-value 依赖拓扑排序      -> 有序类型表
;;   * 常量值解析（枚举成员 / #define / 扩展常量）  -> (name . valexpr)
;;   * 命令/参数 -> vk-command（运行期 IR）
;;
;; 分类：预定义常量 constants / 枚举 enums / 结构体 structs / 其他类型 other-types /
;; 函数 commands。生成阶段（generate.rkt）再分别转成形式。
;; ============================================================

(require racket/list
         racket/string
         "xexpr.rkt"
         "vk-registry.rkt"
         "extension-select.rkt"
         "ctype.rkt"
         "constants.rkt"
         "facts-build.rkt")

(provide (struct-out vk-model)
         parse-model)

;; registry           : registry（XML 事实）
;; feature/extensions : 目标参数（feature 名 / 扩展选择串）
;; requested-extensions/ext-closure : 扩展名单 / 依赖闭包
;; feat-types         : feature 直接 require 的类型名（ABI 审计用）
;; wanted-cmds        : 纳入的全部命令名（feature + 扩展）
;; wanted-list        : wanted 类型名（排序，过滤到 registry 已知）
;; types              : wanted-list 的 by-value 依赖拓扑序（= types.inc 顺序）
;; constants          : 有序 (name . valexpr)（= constants.inc）
;; enums/structs/other-types : types 按类别切分（供分类生成/审计）
;; commands           : 归一化后的 vk-command 列表（= facts.rkt / commands.inc）
(struct vk-model
  (registry feature extensions closure
   requested-extensions ext-closure feat-types
   wanted-cmds wanted-list types
   constants enums structs other-types
   commands)
  #:transparent)

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

(define (partition-types reg types)
  (define (only cats) (filter (λ (nm) (memq (type-category reg nm) cats)) types))
  (values (only '(enum))
          (only '(struct union))
          (only '(handle bitmask basetype funcpointer alias))))

(define (parse-model #:registry reg
                     #:feature feature
                     #:extensions extensions)
  (define closure (feature-closure reg feature))
  (define requested-extensions (resolve-extensions reg extensions))
  (define ext-closure (extension-closure reg requested-extensions))
  (define-values (feat-cmds feat-types) (collect-requires reg closure))
  (define-values (ext-cmds ext-types ext-enums) (collect-extension-requires reg ext-closure))
  (define wanted-cmds (append feat-cmds ext-cmds))
  (define wanted-types (append feat-types ext-types))

  (define wanted-list (wanted-type-closure reg wanted-types wanted-cmds))
  (define types (topo-sort wanted-list (λ (nm) (type-dependencies reg nm))))

  (define constants (parsed-constants reg closure ext-enums))
  (define commands (api-commands reg wanted-cmds))
  (define-values (enums structs other-types) (partition-types reg types))

  (vk-model reg feature extensions closure
            requested-extensions ext-closure feat-types
            wanted-cmds wanted-list types
            constants enums structs other-types
            commands))
