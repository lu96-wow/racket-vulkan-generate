#lang racket/base
;; ============================================================
;; 注册表加载 + feature/extension 依赖闭包。
;;
;; 只认 XML 事实（types/commands/enums/features/extensions），不认 C 类型
;; 映射或生成规则——那些在 ctype.rkt / facts-build.rkt / emit-*.rkt。
;; ============================================================

(require racket/list
         racket/string
         xml
         "xexpr.rkt")

(provide (struct-out registry)
         load-registry
         resolve-command command-name
         feature-by-name feature-closure collect-requires
         extension-closure collect-extension-requires extension-includable?)

;; types/types-hash：全部 type 元素（含 alias），types-hash 按 name 索引。
;; commands-hash：按 name 索引的 command 元素（含 alias 命令）。
(struct registry (types types-hash enums-blocks commands-hash features extensions)
  #:transparent)

(define (load-registry path)
  (define root (xml->xexpr (document-element (read-xml (open-input-file path)))))
  (define types (find-all-by-tag 'type (find-first-by-tag 'types root)))
  (define types-hash (make-hasheqv))
  (for ([ty types])
    (define cat (cat-of ty))
    (define nm (type-name ty))
    (when (and nm (not (eq? cat 'include)) (api-ok? ty))
      (hash-set! types-hash (string->symbol nm) ty)))
  (define commands-list (find-all-by-tag 'command (find-first-by-tag 'commands root)))
  (define commands-hash (make-hasheqv))
  (for ([c commands-list])
    (define n (command-name c))
    (when n (hash-set! commands-hash (string->symbol n) c)))
  (registry types types-hash
            (find-all-by-tag 'enums root)
            commands-hash
            (find-all-by-tag 'feature root)
            (find-all-by-tag 'extension (find-first-by-tag 'extensions root))))

(define (command-name c)
  (or (let ([p (find-first-by-tag 'proto c)])
        (and p (let ([n (find-first-by-tag 'name p)]) (and n (xtext n)))))
      ;; alias 命令没有 <proto>，只有 name 属性
      (attr c 'name)))

;; alias 命令（只有 alias="目标"，无 <proto>/<param>）解析到目标命令元素；
;; 生成时沿用目标的签名，但保留 alias 自己的名字。
(define (resolve-command reg c)
  (define a (attr c 'alias #f))
  (if a (or (hash-ref (registry-commands-hash reg) (string->symbol a) #f) c) c))

;; ------------------------------------------------------------------
;; feature 依赖闭包
(define (split-depends s)
  (if (or (not s) (string=? s "")) '() (string-split s "+")))
(define (feature-by-name reg n)
  (findf (λ (f) (equal? (attr f 'name) n)) (registry-features reg)))
(define (feature-closure reg name)
  (let loop ([todo (list name)] [seen '()])
    (cond [(null? todo) (reverse seen)]
          [(member (car todo) seen) (loop (cdr todo) seen)]
          [else
           (define f (feature-by-name reg (car todo)))
           (loop (append (split-depends (and f (attr f 'depends))) (cdr todo))
                 (cons (car todo) seen))])))
(define (collect-requires reg feature-names)
  (define cmds '()) (define tys '())
  (for ([fn feature-names])
    (define f (feature-by-name reg fn))
    (when f
      (for ([req (find-all-by-tag 'require f)])
        (for ([ch (xcontent req)])
          (when (xelem? ch)
            (case (xtag ch)
              [(command) (set! cmds (cons (attr ch 'name) cmds))]
              [(type)    (set! tys  (cons (attr ch 'name) tys))]))))))
  (values (reverse cmds) (reverse tys)))

;; ------------------------------------------------------------------
;; extension 依赖闭包（跳过 provisional / supported=disabled）
(define (extension-by-name reg n)
  (findf (λ (e) (equal? (attr e 'name) n)) (registry-extensions reg)))
(define (extension-includable? e)
  (and (not (equal? (attr e 'provisional #f) "true"))
       (not (equal? (attr e 'supported #f) "disabled"))
       (api-ok? e)))
(define (extension-closure reg names)
  (let loop ([todo names] [seen '()])
    (cond [(null? todo) (reverse seen)]
          [(member (car todo) seen) (loop (cdr todo) seen)]
          [(or (not (extension-by-name reg (car todo)))
               (not (extension-includable? (extension-by-name reg (car todo)))))
           (loop (cdr todo) seen)]
          [else
           (define e (extension-by-name reg (car todo)))
           (loop (append (split-depends (attr e 'depends #f)) (cdr todo))
                 (cons (car todo) seen))])))
(define (collect-extension-requires reg names)
  (define cmds '()) (define tys '()) (define ens '())
  (for ([en names])
    (define e (extension-by-name reg en))
    (when e
      (for ([req (find-all-by-tag 'require e)])
        (for ([ch (xcontent req)])
          (when (xelem? ch)
            (case (xtag ch)
              [(command) (set! cmds (cons (attr ch 'name) cmds))]
              [(type)    (set! tys  (cons (attr ch 'name) tys))]
              [(enum)    (set! ens  (cons (cons (attr e 'number) ch) ens))]))))))
  (values (reverse cmds) (reverse tys) (reverse ens)))
