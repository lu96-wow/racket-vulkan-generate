#lang racket/base
;; ============================================================
;; constants.inc 的值解析与排序输出。
;; ============================================================

(require racket/list
         racket/string
         "xexpr.rkt"
         "registry.rkt")

(provide ordered-constants)

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
    [(regexp-match #px"^~0(ULL|LL|UL|U|L)?(-([0-9]+))?$" t)
     => (λ (m)
          (define suffix (or (cadr m) ""))
          (define bits (if (member suffix '("ULL" "LL" "UL")) 64 32))
          (define base (mask-of bits))
          (define sub (if (list-ref m 3) (string->number (list-ref m 3)) 0))
          (- base sub))]
    [(regexp-match #px"^([0-9]*\\.?[0-9]+)[fF]$" t) => (λ (m) (string->number (cadr m)))]
    [else #f]))

(define (enumerant->valexpr e ext-number)
  (define alias (attr e 'alias #f))
  (cond
    [alias (string->symbol alias)]
    [(attr e 'value) (parse-c-int (attr e 'value))]
    [(attr e 'bitpos) (arithmetic-shift 1 (string->number (attr e 'bitpos)))]
    [(attr e 'offset)
     (define off (string->number (attr e 'offset)))
     (define en (or (and (attr e 'extnumber) (string->number (attr e 'extnumber))) ext-number))
     (define v (+ 1000000000 (* (- en 1) 1000) off))
     (if (equal? (attr e 'dir #f) "-") (- v) v)]
    [else #f]))

(define (ordered-constants reg closure ext-enums)
  ;; name -> valexpr（整数/浮点，或 alias 的符号）
  (define constant-map (make-hasheqv))
  (define (put! name valexpr)
    (unless (hash-has-key? constant-map name)
      (hash-set! constant-map name valexpr)))

  (for ([blk (registry-enums-blocks reg)])
    (for ([e (find-all-by-tag 'enum blk)])
      (define nm (attr e 'name))
      (when nm
        (define v (enumerant->valexpr e #f))
        (when v (put! (string->symbol nm) v)))))
  (for ([fn closure])
    (define f (feature-by-name reg fn))
    (when f
      (for ([e (find-all-by-tag 'enum f)])
        (define nm (attr e 'name))
        (when nm (define v (enumerant->valexpr e #f)) (when v (put! (string->symbol nm) v))))))
  ;; 扩展常量（含 extension-relative offset/extnumber）
  (for ([pair ext-enums])
    (define en (string->number (car pair)))
    (define ch (cdr pair))
    (define nm (attr ch 'name))
    (when nm
      (define alias (attr ch 'alias #f))
      (cond [alias (put! (string->symbol nm) (string->symbol alias))]
            [else (define v (enumerant->valexpr ch en)) (when v (put! (string->symbol nm) v))])))
  (for ([nm (hash-keys (registry-types-hash reg))])
    (define ty (hash-ref (registry-types-hash reg) nm))
    (when (eq? (cat-of ty) 'define)
      (define mm (regexp-match #px"#define\\s+\\S+\\s+([0-9]+)\\s*$" (xtext ty)))
      (when mm (put! nm (string->number (cadr mm))))))

  ;; 常量按依赖（alias）排序后输出
  (define emitted (make-hasheqv))
  (define out '())
  (define (literal? v) (not (symbol? v)))
  (define (names) (sort (hash-keys constant-map) (λ (a b) (string<? (symbol->string a) (symbol->string b)))))
  (for ([nm (names)])
    (define v (hash-ref constant-map nm))
    (when (literal? v)
      (hash-set! emitted nm #t)
      (set! out (cons `(define ,nm ,v) out))))
  ;; 反复处理 alias，直到不再前进
  (let loop ()
    (define progressed #f)
    (for ([nm (names)])
      (unless (hash-has-key? emitted nm)
        (define v (hash-ref constant-map nm))
        (when (and (symbol? v) (hash-has-key? emitted v))
          (hash-set! emitted nm #t)
          (set! out (cons `(define ,nm ,v) out))
          (set! progressed #t))))
    (when progressed (loop)))
  (reverse out))
