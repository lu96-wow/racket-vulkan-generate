#lang racket/base
;; ============================================================
;; constants.rkt 的值解析与形式生成。
;; ============================================================

(require racket/list
         racket/string
         "xexpr.rkt"
         "vk-registry.rkt"
         "model.rkt")

(provide parsed-constants constant-forms)

(define (mask-of bits) (- (arithmetic-shift 1 bits) 1))
(define (strip-parens s)
  (define t (string-trim s))
  (if (and (>= (string-length t) 2)
           (char=? (string-ref t 0) #\()
           (char=? (string-ref t (sub1 (string-length t))) #\)))
      (strip-parens (substring t 1 (sub1 (string-length t))))
      t))
(define (parse-c-int s)
  (define t (strip-parens s))
  (cond
    [(regexp-match #px"^0[xX]([0-9a-fA-F]+)$" t) => (λ (m) (string->number (cadr m) 16))]
    [(regexp-match #px"^-?[0-9]+$" t) => (λ (m) (string->number t))]
    ;; ~N = 位取反：宽度由后缀定（ULL/LL/UL=64，U/L/无=32）
    [(regexp-match #px"^~([0-9]+)(ULL|LL|UL|U|L)?$" t)
     => (λ (m)
          (define n (string->number (cadr m)))
          (define suffix (or (caddr m) ""))
          (define bits (if (member suffix '("ULL" "LL" "UL")) 64 32))
          (- (mask-of bits) n))]
    [(regexp-match #px"^([0-9]*\\.?[0-9]+)[fF]$" t) => (λ (m) (string->number (cadr m)))]
    [else #f]))

;; 字符串字面量（XML 里的 &quot;...&quot;）——扩展名常量，用 bytes 表达。
(define (parse-c-string s)
  (define t (string-trim s))
  (cond
    [(regexp-match #px"^\"(.*)\"$" t) => (λ (m) (string->bytes/utf-8 (cadr m)))]
    [else #f]))

(define (enumerant->valexpr e ext-number)
  (define alias (attr e 'alias #f))
  (cond
    [alias (string->symbol alias)]
    [(attr e 'value)
     (define s (attr e 'value))
     (or (parse-c-int s) (parse-c-string s))]
    [(attr e 'bitpos) (arithmetic-shift 1 (string->number (attr e 'bitpos)))]
    [(attr e 'offset)
     (define off (string->number (attr e 'offset)))
     (define en (or (and (attr e 'extnumber) (string->number (attr e 'extnumber))) ext-number))
     (define v (+ 1000000000 (* (- en 1) 1000) off))
     (if (equal? (attr e 'dir #f) "-") (- v) v)]
    [else #f]))

;; --- 解析：常量名 -> 值（整数/浮点/bytes，或 alias 的符号）---
;; 返回按「可复现顺序」排好的 (name . valexpr) 列表：literal 先按名字排序，
;; 依赖其他常量的 alias 再按轮次补齐。生成阶段只做 (define ...) 包装。
(define (parsed-constants reg closure ext-enums [diags #f])
  ;; name -> valexpr（整数/浮点，或 alias 的符号）
  (define constant-map (make-hasheqv))
  (define (put! name valexpr)
    (unless (hash-has-key? constant-map name)
      (hash-set! constant-map name valexpr)))
  (define (put-enum! e en)
    (define nm (attr e 'name))
    (when nm
      (define v (enumerant->valexpr e en))
      (cond [v (put! (string->symbol nm) v)]
            [else (diagnose! diags 'warn 'constant nm "unparsable enum value; dropped")])))

  (for ([blk (registry-enums-blocks reg)])
    (for ([e (find-all-by-tag 'enum blk)]) (put-enum! e #f)))
  (for ([fn closure])
    (define f (feature-by-name reg fn))
    (when f (for ([e (find-all-by-tag 'enum f)]) (put-enum! e #f))))
  ;; 扩展常量（含 extension-relative offset/extnumber）
  (for ([pair ext-enums])
    (define en (string->number (car pair)))
    (define ch (cdr pair))
    (define nm (attr ch 'name))
    (when nm
      (define alias (attr ch 'alias #f))
      (cond [alias (put! (string->symbol nm) (string->symbol alias))]
            [else
             (define v (enumerant->valexpr ch en))
             (cond [v (put! (string->symbol nm) v)]
                   [else (diagnose! diags 'warn 'constant nm "unparsable extension enum value; dropped")])])))
  (for ([nm (hash-keys (registry-types-hash reg))])
    (define ty (hash-ref (registry-types-hash reg) nm))
    (when (eq? (cat-of ty) 'define)
      (define mm (regexp-match #px"#define\\s+\\S+\\s+([0-9]+)\\s*$" (xtext ty)))
      (when mm (put! nm (string->number (cadr mm))))))

  ;; 常量按依赖（alias）排序后输出
  (define emitted (make-hasheqv))
  (define out '())                     ; (name . valexpr)
  (define (literal? v) (not (symbol? v)))
  (define (names) (sort (hash-keys constant-map) (λ (a b) (string<? (symbol->string a) (symbol->string b)))))
  (for ([nm (names)])
    (define v (hash-ref constant-map nm))
    (when (literal? v)
      (hash-set! emitted nm #t)
      (set! out (cons (cons nm v) out))))
  ;; 反复处理 alias，直到不再前进
  (let loop ()
    (define progressed #f)
    (for ([nm (names)])
      (unless (hash-has-key? emitted nm)
        (define v (hash-ref constant-map nm))
        (when (and (symbol? v) (hash-has-key? emitted v))
          (hash-set! emitted nm #t)
          (set! out (cons (cons nm v) out))
          (set! progressed #t))))
    (when progressed (loop)))
  ;; 不静默：未发射的 alias 逐一记录
  (for ([nm (names)] #:unless (hash-has-key? emitted nm))
    (diagnose! diags 'warn 'constant nm "alias target not emitted; constant dropped"))
  (reverse out))

(define (constant-forms pairs)
  (for/list ([p (in-list pairs)]) `(define ,(car p) ,(cdr p))))
